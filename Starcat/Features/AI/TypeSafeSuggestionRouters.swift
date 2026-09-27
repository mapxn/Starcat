//
//  TypeSafeSuggestionRouters.swift
//  Starcat
//
//  Jev 决策服务的两个装配路由器 —— 实验性功能(Labs)POC。
//
//  为什么用路由器而不是直接替换 Provider:
//  - 现有 LLM 路径必须保留为默认路径：开关关闭或 Key 未配置时原样调用 LLM，
//    不能让实验功能的配置状态阻断正式标签能力；
//  - Jev 是实验特性,后续可能整体下线 —— 下线时只需从 AppDependencies 摘掉这两层
//    路由,业务文件(会话 / 队列 / 服务)零改动。
//
//  路由边界(POC 安全边界):
//  - 分组：手动整理与 AutoTidyScheduler 后台自动分组共用 Jev-first 路由；Jev 只
//    返回候选概率，封闭集校验、置信度阈值与写入规则仍由现有会话负责；
//  - 标签：所有标签生成入口统一先让 Jev 对现有词表打分；结果不足且业务策略允许新增时，
//    才按需调用一次 LLM 生成词表外的新标签，新标签不再回送 Jev 做二次否决；
//  - 失败语义:Jev 失败不静默回退 LLM(双跑烧两份钱 + 加倍延迟),错误沿既有
//    失败分类上抛,由会话 / 队列现有的重试与展示语义接管。
//

import Foundation

// MARK: - 分组建议路由

/// `GitHubStarListAIGroupingSession` 的 Provider 路由层。
///
/// 手动窗口与 AutoTidyScheduler 共享同一 Provider，因此这里只按 Labs 配置与凭据
/// 决定是否使用 Jev；调用来源对应的审核、阈值和自动写入边界继续留在会话层。
@MainActor
final class TypeSafeGitHubListSuggestionRouter: GitHubStarListSuggestionProviding {
    private let llmProvider: any GitHubStarListSuggestionProviding
    private let typesafeProvider: TypeSafeDecisionService
    private let settings: AppSettings

    init(
        llmProvider: any GitHubStarListSuggestionProviding,
        typesafeProvider: TypeSafeDecisionService,
        settings: AppSettings
    ) {
        self.llmProvider = llmProvider
        self.typesafeProvider = typesafeProvider
        self.settings = settings
    }

    private var shouldRouteToTypesafe: Bool {
        settings.typesafeDecisionEnabled
            && settings.typesafeGroupingSuggestionsEnabled
            && typesafeProvider.canResolveAPIKey()
    }

    func generateGitHubListSuggestions(
        for repos: [Repo],
        candidates: [GitHubStarListAIContext],
        existingListIDsByRepo: [Int64: Set<String>],
        existingListNamesByRepo: [Int64: [String]]
    ) async throws -> [Int64: [GitHubStarListAISuggestion]] {
        if shouldRouteToTypesafe {
            do {
                return try await typesafeProvider.generateGitHubListSuggestions(
                    for: repos,
                    candidates: candidates,
                    existingListIDsByRepo: existingListIDsByRepo,
                    existingListNamesByRepo: existingListNamesByRepo
                )
            } catch let error as TypeSafeClientError {
                AppLog.ai.error(
                    "[typesafePOC] grouping suggestions failed, surfacing error: \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
        }
        return try await llmProvider.generateGitHubListSuggestions(
            for: repos,
            candidates: candidates,
            existingListIDsByRepo: existingListIDsByRepo,
            existingListNamesByRepo: existingListNamesByRepo
        )
    }
}

// MARK: - 标签建议路由

/// 所有 AI 标签入口共用的 Jev-first 路由。
///
/// 路由器不持有 `RepoAIInsightService`，而是由调用方传入本次 LLM fallback 闭包：
/// 这样单仓面板可以复用已经准备好的 README / 代码上下文，批量队列也能继续使用轻量
/// 批请求，同时避免 Service 与 Router 互相强持有。
@MainActor
final class TypeSafeTagSuggestionRouter {
    private let typesafeProvider: TypeSafeDecisionService
    private let settings: AppSettings

    init(
        typesafeProvider: TypeSafeDecisionService,
        settings: AppSettings
    ) {
        self.typesafeProvider = typesafeProvider
        self.settings = settings
    }

    var isRoutingToTypesafe: Bool {
        settings.typesafeDecisionEnabled
            && settings.typesafeTagSuggestionsEnabled
            && typesafeProvider.canResolveAPIKey()
    }

    func generateTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints],
        policy: AITagGenerationPolicy,
        llmFallback: @MainActor (
            _ repos: [Repo],
            _ tagHintsByRepoID: [Int64: AITagHints],
            _ purpose: AITagSuggestionPurpose
        ) async throws -> [Int64: [AITagSuggestion]]
    ) async throws -> [Int64: [AITagSuggestion]] {
        guard !repos.isEmpty else { return [:] }
        guard isRoutingToTypesafe else {
            return try await llmFallback(repos, tagHintsByRepoID, .reuseFirst)
        }

        do {
            let reusableResults = try await typesafeProvider.generateBatchTagSuggestions(
                for: repos,
                tagHintsByRepoID: tagHintsByRepoID
            )
            guard policy.allowNewTags else { return reusableResults }

            let minimum = settings.clampedAITagSuggestionCounts.minimum
            let maximum = settings.clampedAITagSuggestionCounts.maximum
            let fallbackRepos = repos.filter { repo in
                (reusableResults[repo.id] ?? []).count { suggestion in
                    suggestion.confidence >= policy.minimumReusableConfidence
                } < minimum
            }
            guard !fallbackRepos.isEmpty else { return reusableResults }

            let fallbackHints = Dictionary(uniqueKeysWithValues: fallbackRepos.map { repo in
                (repo.id, tagHintsByRepoID[repo.id] ?? .empty)
            })
            // LLM 只补词表外的新概念。它的产出直接进入审核 / 阈值应用，不再回送 Jev，
            // 否则新标签天然缺少历史样本，低分会让这次 LLM 调用变成无效消耗。
            let generatedResults = try await llmFallback(fallbackRepos, fallbackHints, .newOnly)

            var mergedResults = Dictionary(uniqueKeysWithValues: repos.map { repo in
                (repo.id, reusableResults[repo.id] ?? [])
            })
            for repo in fallbackRepos {
                let hints = fallbackHints[repo.id] ?? .empty
                let reusable = reusableResults[repo.id] ?? []
                let forbiddenKeys = Set(
                    (hints.repoTags + hints.libraryTags).map(AITagSuggestionPolicy.canonicalKey)
                )
                let reusableKeys = Set(reusable.map { AITagSuggestionPolicy.canonicalKey($0.name) })
                let genuinelyNew = (generatedResults[repo.id] ?? []).filter { suggestion in
                    let key = AITagSuggestionPolicy.canonicalKey(suggestion.name)
                    return !key.isEmpty
                        && !forbiddenKeys.contains(key)
                        && !reusableKeys.contains(key)
                }
                let normalizedNew = AITagSuggestionPolicy.normalizedSuggestions(
                    genuinelyNew,
                    vocabulary: [],
                    maximumSuggestionCount: 1
                )
                // 一旦 Jev 判定旧标签不足并实际调用了 LLM，有效新标签必须保留；否则低分
                // 旧标签占满 maximum 后会把新标签截掉，形成“付费生成但结果不可见”的浪费。
                let reusableLimit = max(0, maximum - normalizedNew.count)
                mergedResults[repo.id] = AITagSuggestionPolicy.sortedByConfidenceDescending(
                    Array(reusable.prefix(reusableLimit)) + normalizedNew
                )
            }
            return mergedResults
        } catch let error as TypeSafeClientError {
            AppLog.ai.error(
                "[typesafePOC] tag suggestions failed, surfacing error: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }
}
