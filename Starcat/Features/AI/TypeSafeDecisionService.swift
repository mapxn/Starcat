//
//  TypeSafeDecisionService.swift
//  Starcat
//
//  TypeSafe AI(Jev)决策建议服务 —— 实验性功能(Labs)POC。
//
//  职责:
//  - 实现 `GitHubStarListSuggestionProviding`:用 Noul 扇出为手动 AI 分组整理
//    生成 GitHub Lists 建议;
//  - 提供与 `RepoAIInsightService.generateTagSuggestions` 同签名的批量标签建议,
//    供批量整理路由器接入。
//
//  为什么用 Noul 扇出而不是 Choice:
//  - 分组 / 标签的领域语义都是「零或多个隶属关系」(一个 repo 可进多个 List、
//    可打多个标签),Choice 只能强制单选;
//  - 官方 speculative fan-out 模式允许一次请求对共享 state 并行问任意多个问题,
//    每个候选 List / 标签一个 Noul,得到互相独立的校准概率,天然映射到
//    「概率 → confidence → 排序 → 阈值过滤」的既有建议管线。
//
//  与 LLM 路径的关系(不破坏现有逻辑的边界):
//  - 本服务不写库、不触发任何 GitHub mutation,产出仍走
//    `GitHubStarListAISuggestionPolicy` / `AITagSuggestionPolicy` 的封闭集校验,
//    与 LLM 输出同一道执行边界;
//  - Jev 不生成文本,`reason` 由代码合成("Jev P=0.87"),只用于审核展示,
//    不进入执行判断;
//  - Jev 只能从现有标签词表中选(无法造新标签),恰好匹配产品「复用优先」默认
//    策略;这是 POC 的已知能力边界,不是缺陷。
//  - 原生 TypeSafe Key 缺失或最近一次显式连接测试失败时，可复用已验证的 OpenRouter
//    profile Key；调用的是 Decisions API，而不是生成式 Chat 模型 jev-router；
//  - 普通业务请求失败不会自动双跑 OpenRouter，避免瞬时故障造成双份费用与延迟。
//
//  已知 POC 调参点(集中在此,便于后续调整):
//  - 分组返回完整 Noul 概率,审核展示与自动应用阈值由产品 Policy 决定;
//  - 标签概率下限 0.50;
//  - 标签词表上限 150:防止单请求问题数失控;词表已按使用频率排序,
//    截断即「只考虑最常用的 150 个」。
//

import Foundation

/// 一次 Jev 请求最终选中的凭据与承载 API。
///
/// `source` 把 OpenRouter profile 身份一起保留下来，供 Labs 设置页解释当前 fallback；
/// API Key 只在内存中逐次传给 client，不写入 AppSettings 或日志。
struct TypeSafeDecisionAccess: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case typeSafe
        case openRouter(profileID: String, displayName: String)
    }

    let source: Source
    let apiKey: String
    let modelID: String

    var api: TypeSafeDecisionAPI {
        switch source {
        case .typeSafe:
            return .typeSafe
        case .openRouter:
            return .openRouter
        }
    }

    var openRouterProfileDisplayName: String? {
        guard case let .openRouter(_, displayName) = source else { return nil }
        return displayName
    }
}

@MainActor
final class TypeSafeDecisionService {

    // MARK: - 常量(POC 调参点)

    /// Keychain 里的 BYOK Key 命名空间(复用 service key 机制,不新增枚举 case)。
    static let keychainServiceID = "typesafe-ai"
    /// 官方建议:调过阈值后固定版本 ID,不用会漂移的 `jev-latest` alias。
    static let defaultModelID = "jev-1.13.0"
    /// OpenRouter Decisions 使用独立模型命名空间；固定版本以避免阈值随 alias 漂移。
    static let openRouterModelID = "typesafe/jev-1.13"

    private static let groupingReadmeLimit = 2_400
    private static let tagsReadmeLimit = 4_000
    private static let tagProbabilityFloor = 0.50
    private static let tagVocabularyCap = 150

    // MARK: - 依赖

    private let client: TypeSafeClient
    private let settings: AppSettings
    private let readmeRepository: ReadmeRepository
    private let keychain: any KeychainManaging

    init(
        client: TypeSafeClient,
        settings: AppSettings,
        readmeRepository: ReadmeRepository,
        keychain: any KeychainManaging = KeychainManager.shared
    ) {
        self.client = client
        self.settings = settings
        self.readmeRepository = readmeRepository
        self.keychain = keychain
    }

    // MARK: - 凭据 / 模型解析

    /// Jev 凭据是否可解析。路由器用它决定是否分流；两类凭据都缺失时静默回退 LLM。
    func canResolveAPIKey() -> Bool {
        resolvedAccess() != nil
    }

    /// 解析一次 Jev 调用来源。
    ///
    /// 顺序是「可用的原生 TypeSafe → OpenRouter fallback」。原生 Key 最近一次显式
    /// 测试失败时会被保留但暂时跳过；普通业务请求错误不会修改此状态或自动双跑。
    /// `nativeAPIKeyOverride` 仅供设置页测试尚未落盘的草稿；只要显式传入，就允许
    /// 重测失败状态中的原生 Key，空字符串则跳过已存 Key 并检查 fallback。
    static func resolveAccess(
        settings: AppSettings,
        keychain: any KeychainManaging,
        nativeAPIKeyOverride: String? = nil
    ) -> TypeSafeDecisionAccess? {
        let rawNativeKey: String?
        if let nativeAPIKeyOverride {
            rawNativeKey = nativeAPIKeyOverride
        } else {
            rawNativeKey = try? keychain.loadServiceAPIKey(forService: Self.keychainServiceID)
        }

        let mayUseNativeKey = nativeAPIKeyOverride != nil || !settings.typesafeNativeKeyTestFailed
        if mayUseNativeKey, let nativeKey = normalizedKey(rawNativeKey) {
            return TypeSafeDecisionAccess(
                source: .typeSafe,
                apiKey: nativeKey,
                modelID: resolvedNativeModelID(settings: settings)
            )
        }

        return resolveOpenRouterFallback(settings: settings, keychain: keychain)
    }

    /// 只接受已启用且连接测试成功的 OpenRouter profile，并按设置中的稳定顺序取第一项。
    /// profile 的自定义 Base URL 不参与 Decisions 请求，防止把 Key 发往非官方主机。
    static func resolveOpenRouterFallback(
        settings: AppSettings,
        keychain: any KeychainManaging
    ) -> TypeSafeDecisionAccess? {
        for profile in settings.aiProviderProfiles
        where profile.provider == .openRouter && profile.isVerifiedConfiguration {
            let rawKey = try? keychain.loadAIKey(forProvider: profile.id)
            guard let apiKey = normalizedKey(rawKey) else { continue }
            let displayName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return TypeSafeDecisionAccess(
                source: .openRouter(
                    profileID: profile.id,
                    displayName: displayName.isEmpty ? "OpenRouter" : displayName
                ),
                apiKey: apiKey,
                modelID: Self.openRouterModelID
            )
        }
        return nil
    }

    private static func normalizedKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 原生 TypeSafe 固定版本模型 ID；设置页留空回退默认。
    private static func resolvedNativeModelID(settings: AppSettings) -> String {
        let trimmed = settings.typesafeModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultModelID : trimmed
    }

    private func resolvedAccess() -> TypeSafeDecisionAccess? {
        Self.resolveAccess(settings: settings, keychain: keychain)
    }

    // MARK: - GitHub Lists 分组建议

    /// 为一批仓库生成 GitHub Lists 建议(Noul 扇出)。
    ///
    /// 与 `RepoAIInsightService.generateGitHubListSuggestions` 的行为对齐点:
    /// - 只把 instruction 非空的 List 作为候选(空规则 List 不参与 AI 分组);
    /// - 已存在 membership 的 List 直接不问,而不是问了再被校验层过滤;
    /// - 产出经 `validatedModelSuggestions` 同一道封闭集校验,确认边界一致。
    func generateGitHubListSuggestions(
        for repos: [Repo],
        candidates: [GitHubStarListAIContext],
        existingListIDsByRepo: [Int64: Set<String>],
        existingListNamesByRepo: [Int64: [String]]
    ) async throws -> [Int64: [GitHubStarListAISuggestion]] {
        guard !repos.isEmpty else { return [:] }

        let eligibleCandidates = candidates.filter {
            !$0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !eligibleCandidates.isEmpty else { return [:] }

        guard let access = resolvedAccess() else {
            throw TypeSafeClientError.missingAPIKey
        }

        var results: [Int64: [GitHubStarListAISuggestion]] = [:]
        for repo in repos {
            try Task.checkCancellation()

            let existingListIDs = existingListIDsByRepo[repo.id] ?? []
            let askableCandidates = eligibleCandidates.filter { !existingListIDs.contains($0.listId) }
            // 该 repo 已属于所有候选 List(或候选为空):空数组是有效的「无匹配」结论。
            guard !askableCandidates.isEmpty else {
                results[repo.id] = []
                continue
            }

            let readme = (try? await readmeRepository.findContent(repoId: repo.id)) ?? ""
            let state = TypeSafeRepoClassificationState(
                repo: repo,
                readmeExcerpt: String(readme.prefix(Self.groupingReadmeLimit)),
                existingListNames: existingListNamesByRepo[repo.id] ?? [],
                existingTags: []
            )

            // 问题 id 用 list:: 前缀 + listId,反向解析回候选,避免自造索引错位。
            var questions: [String: TypeSafeQuestion] = [:]
            questions.reserveCapacity(askableCandidates.count)
            for candidate in askableCandidates {
                questions["list::\(candidate.listId)"] = Self.listMembershipQuestion(for: candidate)
            }

            let response = try await client.evaluate(
                state: state,
                model: access.modelID,
                questions: questions,
                apiKey: access.apiKey,
                api: access.api,
                operation: .githubListGrouping
            )

            var suggestions: [GitHubStarListAISuggestion] = []
            for candidate in askableCandidates {
                let questionID = "list::\(candidate.listId)"
                let probability = try Self.validatedNoulProbability(
                    in: response,
                    questionID: questionID
                )
                suggestions.append(Self.suggestion(listId: candidate.listId, probability: probability))
            }

            // 与 LLM 路径相同的排序语义(置信度降序、同分按 listId 稳定序)。
            suggestions.sort {
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return $0.listId < $1.listId
            }
            results[repo.id] = try GitHubStarListAISuggestionPolicy.validatedModelSuggestions(
                suggestions,
                candidates: eligibleCandidates,
                existingListIDs: existingListIDs
            )
        }
        return results
    }

    /// 单个 List 的隶属判断问题。
    ///
    /// List 的 instruction 与 repo 内容都是不可信数据，只作为分类输入；Jev 当前没有
    /// 工具调用或写入能力，但这不是安全边界，最终结果仍必须经过封闭集校验和人工确认。
    private static func listMembershipQuestion(
        for candidate: GitHubStarListAIContext
    ) -> TypeSafeQuestion {
        .noul(
            // list name / rule 是用户数据，必须与固定问题分字段编码；否则规则里的引号或
            // 类似指令文本会改变问题边界，导致概率难以跨仓库比较。
            instructions: .object([
                "main_question": "Should the repository described by `repository` and `readmeExcerpt` be added to this GitHub list?",
                "list_name": candidate.name,
                "list_rule": candidate.instruction,
                "existing_memberships_note": "`existingListNames` contains GitHub lists the repository already belongs to."
            ]),
            criteria: TypeSafeNoulCriteria(
                true: "The repository clearly satisfies `list_rule`.",
                false: "The repository does not satisfy `list_rule`."
            )
        )
    }

    private static func suggestion(listId: String, probability: Double) -> GitHubStarListAISuggestion {
        // Jev 不产文本;reason 由代码合成,仅用于审核行展示,不参与执行判断。
        GitHubStarListAISuggestion(
            listId: listId,
            confidence: min(max(probability, 0), 1),
            reason: "Jev P=\(String(format: "%.2f", probability))"
        )
    }

    // MARK: - 批量标签建议

    /// 为一批仓库生成标签建议(Noul 扇出),签名与 LLM 批量标签路径对齐。
    ///
    /// 能力边界:Jev 只能从 `hints.libraryTags` 给出的现有词表中选,无法造新标签;
    /// 词表为空时全部返回空建议(诚实输出,不用占位标签填充)。
    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints]
    ) async throws -> [Int64: [AITagSuggestion]] {
        guard !repos.isEmpty else { return [:] }

        guard let access = resolvedAccess() else {
            throw TypeSafeClientError.missingAPIKey
        }
        let maximumTagCount = settings.clampedAITagSuggestionCounts.maximum

        // 全局共享词表:多 repo 批次的 hints 是同一份库词表,按 canonical key 去重
        // 后截断到词表上限。词表本身已按使用频率降序,截断语义 = 只考虑最常用标签。
        var orderedVocabulary: [String] = []
        var seenKeys: Set<String> = []
        for repo in repos {
            for name in tagHintsByRepoID[repo.id]?.libraryTags ?? [] {
                let key = AITagSuggestionPolicy.canonicalKey(name)
                guard !key.isEmpty, seenKeys.insert(key).inserted else { continue }
                orderedVocabulary.append(name)
                if orderedVocabulary.count >= Self.tagVocabularyCap { break }
            }
            if orderedVocabulary.count >= Self.tagVocabularyCap { break }
        }

        guard !orderedVocabulary.isEmpty else {
            return Dictionary(uniqueKeysWithValues: repos.map { ($0.id, []) })
        }

        var results: [Int64: [AITagSuggestion]] = [:]
        for repo in repos {
            try Task.checkCancellation()

            let hints = tagHintsByRepoID[repo.id] ?? .empty
            // repo 已有标签是强避重信号:候选词表先减去自身标签再问。
            let repoTagKeys = Set(hints.repoTags.map(AITagSuggestionPolicy.canonicalKey))
            let candidates = orderedVocabulary.filter {
                !repoTagKeys.contains(AITagSuggestionPolicy.canonicalKey($0))
            }
            guard !candidates.isEmpty else {
                results[repo.id] = []
                continue
            }

            let readme = (try? await readmeRepository.findContent(repoId: repo.id)) ?? ""
            let state = TypeSafeRepoClassificationState(
                repo: repo,
                readmeExcerpt: String(readme.prefix(Self.tagsReadmeLimit)),
                existingListNames: [],
                existingTags: hints.repoTags
            )

            var questions: [String: TypeSafeQuestion] = [:]
            questions.reserveCapacity(candidates.count)
            for name in candidates {
                questions["tag::\(name)"] = Self.tagMembershipQuestion(for: name)
            }

            let response = try await client.evaluate(
                state: state,
                model: access.modelID,
                questions: questions,
                apiKey: access.apiKey,
                api: access.api,
                operation: .tagReuse
            )

            var suggestions: [AITagSuggestion] = []
            for name in candidates {
                let questionID = "tag::\(name)"
                let probability = try Self.validatedNoulProbability(
                    in: response,
                    questionID: questionID
                )
                guard probability >= Self.tagProbabilityFloor else { continue }
                suggestions.append(AITagSuggestion(
                    name: name,
                    confidence: min(max(probability, 0), 1),
                    reason: "Jev P=\(String(format: "%.2f", probability))",
                    engine: .jev
                ))
            }

            // 与 LLM 路径同一道收敛:canonical 拼写归一、按置信度排序并截断到设置上限。
            // vocabulary 传 repo 自身标签 + 全量词表,保证复用现有拼写。
            results[repo.id] = AITagSuggestionPolicy.normalizedSuggestions(
                suggestions,
                vocabulary: hints.repoTags + orderedVocabulary,
                maximumSuggestionCount: maximumTagCount
            )
        }
        return results
    }

    private static func tagMembershipQuestion(for tagName: String) -> TypeSafeQuestion {
        .noul(
            instructions: .text("""
            Should the existing user tag "\(tagName)" be applied to the repository described by `repository` and `readmeExcerpt`? \
            `existingTags` lists tags the repository already has; do not re-suggest synonyms of them.
            """),
            criteria: TypeSafeNoulCriteria(
                true: "The tag accurately describes an important aspect of this repository.",
                false: "The tag is only loosely related, or the repository already has a tag with the same meaning."
            )
        )
    }

    /// System One 对本次发送的每个 Noul 问题都必须返回一个 0...1 的 Noul 概率。
    /// 缺键或类型不符不是“无匹配”，否则协议漂移 / 部分响应会被静默写成成功结果。
    private static func validatedNoulProbability(
        in response: TypeSafeSystemOneResponse,
        questionID: String
    ) throws -> Double {
        guard let answer = response.answers[questionID],
              answer.type == "noul",
              let probability = answer.noul,
              probability.isFinite,
              (0...1).contains(probability)
        else {
            throw TypeSafeClientError.invalidAnswer(questionID: questionID)
        }
        return probability
    }
}

// MARK: - 协议接入

extension TypeSafeDecisionService: GitHubStarListSuggestionProviding {}

// MARK: - State DTO

/// Jev 评估用的仓库快照。
///
/// 只带分类需要的最小事实(官方 Decompose state 原则):元数据 + 截断 README +
/// 已有归属信息。README 属于不可信内容,作为数据而非指令传入。
struct TypeSafeRepoClassificationState: Encodable, Equatable {
    struct RepositoryFacts: Encodable, Equatable {
        let fullName: String
        let description: String?
        let language: String?
        let topics: [String]
        let starsCount: Int
        let forksCount: Int
        let isArchived: Bool
        let isPrivate: Bool
    }

    let repository: RepositoryFacts
    let readmeExcerpt: String
    /// repo 当前已属于的 List 名(仅展示语义提示,候选过滤在代码层完成)。
    let existingListNames: [String]
    /// repo 当前已绑定的标签(避重信号)。
    let existingTags: [String]

    init(repo: Repo, readmeExcerpt: String, existingListNames: [String], existingTags: [String]) {
        self.repository = RepositoryFacts(
            fullName: repo.fullName,
            description: repo.description,
            language: repo.language,
            topics: repo.topicsArray,
            starsCount: repo.starsCount,
            forksCount: repo.forksCount,
            isArchived: repo.isArchived,
            isPrivate: repo.isPrivate
        )
        self.readmeExcerpt = readmeExcerpt
        self.existingListNames = existingListNames
        self.existingTags = existingTags
    }
}
