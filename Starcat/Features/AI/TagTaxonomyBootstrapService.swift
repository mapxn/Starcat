//
//  TagTaxonomyBootstrapService.swift
//  Starcat
//
//  首次标签体系的本地分析模型与候选生成器。
//
//  模块职责：
//  - 在标签库为空时，基于全部 Star 仓库的 topics、language、description 与已缓存 README
//    生成一个受控、有限的候选词表；
//  - 只把候选映射到本次批量整理范围，不直接创建 repo_tags 关联；
//  - 输出可解释的来源、覆盖率与样例仓库，供用户确认后进入既有批量审核流程。
//
//  关键约束：
//  - 全流程不调用 LLM / Jev，也不要求用户先配置 AI Provider；
//  - 未知 topic 必须在多个仓库中重复出现才有资格进入候选，避免退化为“一仓一标签”；
//  - README 只用于补强预先定义的技术概念，不把任意高频单词直接变成标签。
//

import Foundation

enum TagTaxonomySessionKind: String, Codable, Equatable, Sendable {
    /// 空标签库的纯本地首次建词表流程。
    case bootstrap
    /// 常规批次中，针对 Jev 未覆盖仓库生成的受控增量词表。
    case expansion
}

enum TagTaxonomySignalKind: String, CaseIterable, Codable, Hashable, Sendable {
    case topic
    case language
    case description
    case readme
    /// 只表示候选来自一次整批 LLM 概念发现，不代表已经通过用户确认或写入标签库。
    case llm
}

/// 首次标签体系生成期间向窗口回报的本地准备进度。
///
/// 数据读取阶段无法从 GRDB 获得稳定的逐行进度，因此只展示阶段状态；仓库分析阶段才使用
/// 确定进度。把两者统一成值类型，可以让 SwiftUI 明确表达当前阶段，而不是继续停在预检页。
struct TagTaxonomyBootstrapProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case loadingLocalData
        case analyzingRepositories
        case buildingCandidates
    }

    let phase: Phase
    let completedRepositoryCount: Int
    let totalRepositoryCount: Int?

    static let loadingLocalData = TagTaxonomyBootstrapProgress(
        phase: .loadingLocalData,
        completedRepositoryCount: 0,
        totalRepositoryCount: nil
    )
}

/// 进度最终由窗口级 `@State` 消费，因此回调明确隔离到 MainActor；`@Sendable` 允许分析 actor
/// 安全地跨隔离域调用，而不把 SwiftUI View 或其它可变引用传进分析器。
typealias TagTaxonomyBootstrapProgressHandler =
    @MainActor @Sendable (TagTaxonomyBootstrapProgress) -> Void

struct TagTaxonomyRepositoryMatch: Codable, Equatable, Sendable {
    let repoID: Int64
    let repositoryFullName: String
    let confidence: Double
    let signals: Set<TagTaxonomySignalKind>
}

struct TagTaxonomyCandidate: Identifiable, Codable, Equatable, Sendable {
    /// ID 在用户改名后仍保持稳定，避免 SwiftUI List 因编辑文字而重建整行。
    let id: String
    var name: String
    let supportCount: Int
    let targetSupportCount: Int
    let signals: Set<TagTaxonomySignalKind>
    let sampleRepositoryNames: [String]
    let targetMatches: [TagTaxonomyRepositoryMatch]
}

struct TagTaxonomyBootstrapSession: Codable, Equatable, Sendable {
    /// 同一套确认 UI 同时承载首次建词表与增量扩词；kind 决定文案和后续提交路径。
    let kind: TagTaxonomySessionKind
    /// 确认后投影到逐仓审核的建议来源，必须由本地调用边界盖章。
    let suggestionEngine: AITagSuggestionEngine
    let targetRepositories: [Repo]
    let candidates: [TagTaxonomyCandidate]
    let defaultSelectedCandidateIDs: Set<String>
    let corpusRepositoryCount: Int
    let cachedReadmeCount: Int

    init(
        kind: TagTaxonomySessionKind = .bootstrap,
        suggestionEngine: AITagSuggestionEngine = .local,
        targetRepositories: [Repo],
        candidates: [TagTaxonomyCandidate],
        defaultSelectedCandidateIDs: Set<String>,
        corpusRepositoryCount: Int,
        cachedReadmeCount: Int
    ) {
        self.kind = kind
        self.suggestionEngine = suggestionEngine
        self.targetRepositories = targetRepositories
        self.candidates = candidates
        self.defaultSelectedCandidateIDs = defaultSelectedCandidateIDs
        self.corpusRepositoryCount = corpusRepositoryCount
        self.cachedReadmeCount = cachedReadmeCount
    }

    func targetCoverage(selectedCandidateIDs: Set<String>) -> Int {
        Set(
            candidates
                .filter { selectedCandidateIDs.contains($0.id) }
                .flatMap(\.targetMatches)
                .map(\.repoID)
        ).count
    }

    /// 把用户确认后的词表投影为既有批量审核模型。
    ///
    /// 这里只产生建议，不建立 repo_tags 关系；最终写入仍由 BatchAIQueueService 的人工审核
    /// 出口完成。每仓上限沿用全局标签建议设置，避免首次引导产生过密的标签组合。
    func suggestions(
        candidates selectedCandidates: [TagTaxonomyCandidate],
        maximumPerRepository: Int,
        reason: String
    ) -> [Int64: [AITagSuggestion]] {
        let limit = min(max(maximumPerRepository, 1), AITagSuggestionCountPolicy.allowedRange.upperBound)
        var rankedByRepository: [Int64: [(candidate: TagTaxonomyCandidate, match: TagTaxonomyRepositoryMatch)]] = [:]

        for candidate in selectedCandidates {
            let displayName = AITagSuggestionPolicy.normalizedDisplayName(candidate.name)
            guard !displayName.isEmpty else { continue }
            var normalizedCandidate = candidate
            normalizedCandidate.name = displayName
            for match in candidate.targetMatches {
                rankedByRepository[match.repoID, default: []].append((normalizedCandidate, match))
            }
        }

        return rankedByRepository.reduce(into: [:]) { result, entry in
            var seenNames: Set<String> = []
            let suggestions = entry.value
                .sorted { lhs, rhs in
                    if lhs.match.confidence != rhs.match.confidence {
                        return lhs.match.confidence > rhs.match.confidence
                    }
                    if lhs.candidate.supportCount != rhs.candidate.supportCount {
                        return lhs.candidate.supportCount > rhs.candidate.supportCount
                    }
                    return lhs.candidate.name.localizedCaseInsensitiveCompare(rhs.candidate.name) == .orderedAscending
                }
                .compactMap { item -> AITagSuggestion? in
                    let key = AITagSuggestionPolicy.canonicalKey(item.candidate.name)
                    guard !key.isEmpty, seenNames.insert(key).inserted else { return nil }
                    return AITagSuggestion(
                        name: item.candidate.name,
                        confidence: item.match.confidence,
                        reason: reason,
                        engine: suggestionEngine
                    )
                }
                .prefix(limit)
            result[entry.key] = Array(suggestions)
        }
    }
}

/// 把纯 CPU 的语料分析隔离到独立 actor，避免上千份 README 的规范化阻塞 SwiftUI 主线程。
actor TagTaxonomyBootstrapAnalyzer {
    private struct ConceptDefinition: Sendable {
        let name: String
        let aliases: [String]
    }

    private struct EvidenceAccumulator: Sendable {
        let fullName: String
        var confidence: Double
        var signals: Set<TagTaxonomySignalKind>
    }

    private struct CandidateAccumulator: Sendable {
        var displayName: String
        var evidenceByRepositoryID: [Int64: EvidenceAccumulator] = [:]

        mutating func add(
            repository: Repo,
            signal: TagTaxonomySignalKind,
            confidence: Double
        ) {
            var evidence = evidenceByRepositoryID[repository.id] ?? EvidenceAccumulator(
                fullName: repository.fullName,
                confidence: confidence,
                signals: []
            )
            evidence.signals.insert(signal)
            // 多种独立信号同时命中时只小幅加权，避免 README 高频词压过 GitHub topic。
            evidence.confidence = min(0.99, max(evidence.confidence, confidence) + Double(evidence.signals.count - 1) * 0.02)
            evidenceByRepositoryID[repository.id] = evidence
        }
    }

    private static let maximumCandidateCount = 24
    private static let defaultSelectedCandidateCount = 12

    /// 只维护跨项目稳定、歧义较低的技术概念。README 不从自由文本造词，而是用这些
    /// alias 给 topics / language 缺失的仓库补充归类证据。
    private static let conceptDefinitions: [ConceptDefinition] = [
        .init(name: "AI", aliases: ["ai", "artificial intelligence", "machine learning", "deep learning", "llm", "large language model", "generative ai"]),
        .init(name: "Automation", aliases: ["automation", "workflow automation", "automated workflow"]),
        .init(name: "Backend", aliases: ["backend", "back end", "server side"]),
        .init(name: "Browser Extension", aliases: ["browser extension", "chrome extension", "safari extension", "firefox extension"]),
        .init(name: "CLI", aliases: ["cli", "command line", "command-line", "terminal tool"]),
        .init(name: "Database", aliases: ["database", "sqlite", "postgresql", "mysql", "mongodb", "redis"]),
        .init(name: "Developer Tools", aliases: ["developer tools", "developer tool", "devtools", "development tool"]),
        .init(name: "DevOps", aliases: ["devops", "continuous integration", "continuous delivery", "ci cd", "kubernetes", "docker"]),
        .init(name: "Documentation", aliases: ["documentation", "docs generator", "documentation generator"]),
        .init(name: "iOS", aliases: ["ios", "iphone", "ipad"]),
        .init(name: "macOS", aliases: ["macos", "mac os", "osx", "os x"]),
        .init(name: "Networking", aliases: ["networking", "network protocol", "http client", "proxy server"]),
        .init(name: "Observability", aliases: ["observability", "monitoring", "distributed tracing", "telemetry"]),
        .init(name: "Productivity", aliases: ["productivity", "personal knowledge management", "note taking"]),
        .init(name: "Security", aliases: ["security", "cybersecurity", "vulnerability", "encryption"]),
        .init(name: "SwiftUI", aliases: ["swiftui"]),
        .init(name: "Testing", aliases: ["testing", "test framework", "unit test", "ui test"]),
        .init(name: "Web", aliases: ["web app", "web application", "frontend", "front end", "website"])
    ]

    private static let ignoredTopicKeys: Set<String> = [
        "awesome", "awesome list", "collection", "curated list", "github", "github api",
        "hacktoberfest", "learning", "list", "open source", "resources", "template", "tutorial"
    ]

    func analyze(
        corpusRepositories: [Repo],
        targetRepositories: [Repo],
        cachedReadmesByRepositoryID: [Int64: String],
        onProgress: (@Sendable (TagTaxonomyBootstrapProgress) async -> Void)? = nil
    ) async throws -> TagTaxonomyBootstrapSession {
        let targetIDs = Set(targetRepositories.map(\.id))
        let corpusIDs = Set(corpusRepositories.map(\.id))
        var accumulators: [String: CandidateAccumulator] = [:]

        if let onProgress {
            await onProgress(TagTaxonomyBootstrapProgress(
                phase: .analyzingRepositories,
                completedRepositoryCount: 0,
                totalRepositoryCount: corpusRepositories.count
            ))
        }

        // 最多向 MainActor 回报约 100 次，既让 2,000+ 仓库的进度可见，也避免每处理一仓
        // 就触发一次 SwiftUI diff。小语料仍逐仓更新，保证短任务不会一直显示 0%。
        let progressStride = max(1, corpusRepositories.count / 100)

        for (repositoryIndex, repository) in corpusRepositories.enumerated() {
            try Task.checkCancellation()
            for topic in repository.topicsArray {
                addStructuredSignal(
                    rawName: topic,
                    repository: repository,
                    signal: .topic,
                    confidence: 0.97,
                    accumulators: &accumulators
                )
            }
            if let language = repository.language {
                addStructuredSignal(
                    rawName: language,
                    repository: repository,
                    signal: .language,
                    confidence: 0.88,
                    accumulators: &accumulators
                )
            }

            if let description = repository.description {
                addKnownConceptSignals(
                    text: description,
                    repository: repository,
                    signal: .description,
                    confidence: 0.80,
                    accumulators: &accumulators
                )
            }
            if let readme = cachedReadmesByRepositoryID[repository.id] {
                addKnownConceptSignals(
                    text: Self.relevantReadmeText(readme),
                    repository: repository,
                    signal: .readme,
                    confidence: 0.72,
                    accumulators: &accumulators
                )
            }

            let completedCount = repositoryIndex + 1
            if let onProgress,
               completedCount == corpusRepositories.count
                || completedCount.isMultiple(of: progressStride) {
                await onProgress(TagTaxonomyBootstrapProgress(
                    phase: .analyzingRepositories,
                    completedRepositoryCount: completedCount,
                    totalRepositoryCount: corpusRepositories.count
                ))
            }
        }

        try Task.checkCancellation()
        if let onProgress {
            await onProgress(TagTaxonomyBootstrapProgress(
                phase: .buildingCandidates,
                completedRepositoryCount: corpusRepositories.count,
                totalRepositoryCount: corpusRepositories.count
            ))
        }

        let minimumSupport = Self.minimumRepositorySupport(corpusCount: corpusRepositories.count)
        let candidates = accumulators.compactMap { key, accumulator -> (candidate: TagTaxonomyCandidate, score: Double)? in
            let evidence = accumulator.evidenceByRepositoryID
            guard evidence.count >= minimumSupport else { return nil }

            let allSignals = evidence.values.reduce(into: Set<TagTaxonomySignalKind>()) { result, item in
                result.formUnion(item.signals)
            }
            let targetMatches = evidence.compactMap { repoID, item -> TagTaxonomyRepositoryMatch? in
                guard targetIDs.contains(repoID) else { return nil }
                return TagTaxonomyRepositoryMatch(
                    repoID: repoID,
                    repositoryFullName: item.fullName,
                    confidence: item.confidence,
                    signals: item.signals
                )
            }
            .sorted { lhs, rhs in
                if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
                return lhs.repositoryFullName < rhs.repositoryFullName
            }

            let samples = evidence.values
                .sorted { lhs, rhs in
                    if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
                    return lhs.fullName < rhs.fullName
                }
                .prefix(8)
                .map(\.fullName)
            let signalScore = evidence.values.reduce(0.0) { $0 + $1.confidence }
            let targetBoost = Double(min(targetMatches.count, 12)) * 1.25
            let diversityBoost = Double(allSignals.count) * 0.35
            let candidate = TagTaxonomyCandidate(
                id: key,
                name: accumulator.displayName,
                supportCount: evidence.count,
                targetSupportCount: targetMatches.count,
                signals: allSignals,
                sampleRepositoryNames: samples,
                targetMatches: targetMatches
            )
            return (candidate, signalScore + targetBoost + diversityBoost)
        }
        .sorted { lhs, rhs in
            if lhs.candidate.targetSupportCount != rhs.candidate.targetSupportCount {
                return lhs.candidate.targetSupportCount > rhs.candidate.targetSupportCount
            }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.candidate.name.localizedCaseInsensitiveCompare(rhs.candidate.name) == .orderedAscending
        }
        .prefix(Self.maximumCandidateCount)
        .map(\.candidate)

        let preferredDefaults = candidates.filter { $0.targetSupportCount > 0 }
        let defaultCandidates = preferredDefaults.isEmpty ? candidates : preferredDefaults
        let defaultIDs = Set(defaultCandidates.prefix(Self.defaultSelectedCandidateCount).map(\.id))

        try Task.checkCancellation()

        return TagTaxonomyBootstrapSession(
            targetRepositories: targetRepositories,
            candidates: candidates,
            defaultSelectedCandidateIDs: defaultIDs,
            corpusRepositoryCount: corpusRepositories.count,
            cachedReadmeCount: cachedReadmesByRepositoryID.keys.lazy.filter(corpusIDs.contains).count
        )
    }

    private func addStructuredSignal(
        rawName: String,
        repository: Repo,
        signal: TagTaxonomySignalKind,
        confidence: Double,
        accumulators: inout [String: CandidateAccumulator]
    ) {
        guard let normalized = Self.normalizedCandidate(rawName),
              !Self.ignoredTopicKeys.contains(normalized.key)
        else { return }
        var accumulator = accumulators[normalized.key] ?? CandidateAccumulator(displayName: normalized.name)
        accumulator.add(repository: repository, signal: signal, confidence: confidence)
        accumulators[normalized.key] = accumulator
    }

    private func addKnownConceptSignals(
        text: String,
        repository: Repo,
        signal: TagTaxonomySignalKind,
        confidence: Double,
        accumulators: inout [String: CandidateAccumulator]
    ) {
        let searchable = " \(Self.normalizedSearchText(text)) "
        guard searchable.count > 2 else { return }

        for definition in Self.conceptDefinitions where definition.aliases.contains(where: { alias in
            searchable.contains(" \(Self.normalizedSearchText(alias)) ")
        }) {
            let key = AITagSuggestionPolicy.canonicalKey(definition.name)
            var accumulator = accumulators[key] ?? CandidateAccumulator(displayName: definition.name)
            accumulator.add(repository: repository, signal: signal, confidence: confidence)
            accumulators[key] = accumulator
        }
    }

    private static func normalizedCandidate(_ rawName: String) -> (key: String, name: String)? {
        let trimmed = AITagSuggestionPolicy.normalizedDisplayName(rawName)
        guard !trimmed.isEmpty, trimmed.count <= 36, !trimmed.contains("http") else { return nil }

        let exactLowercased = trimmed.lowercased()
        if let exactName = ["c++": "C++", "c#": "C#", "f#": "F#"][exactLowercased] {
            return (AITagSuggestionPolicy.canonicalKey(exactName), exactName)
        }

        let searchable = normalizedSearchText(trimmed)
        if let definition = conceptDefinitions.first(where: { definition in
            definition.aliases.contains { normalizedSearchText($0) == searchable }
                || normalizedSearchText(definition.name) == searchable
        }) {
            return (AITagSuggestionPolicy.canonicalKey(definition.name), definition.name)
        }

        let words = searchable.split(separator: " ")
        guard !words.isEmpty, words.count <= 4 else { return nil }
        let displayName = words.map(displayToken).joined(separator: " ")
        let key = AITagSuggestionPolicy.canonicalKey(displayName)
        guard !key.isEmpty else { return nil }
        return (key, displayName)
    }

    private static func displayToken(_ token: Substring) -> String {
        switch token {
        case "api": return "API"
        case "cli": return "CLI"
        case "css": return "CSS"
        case "html": return "HTML"
        case "ios": return "iOS"
        case "javascript", "js": return "JavaScript"
        case "macos", "osx": return "macOS"
        case "sdk": return "SDK"
        case "sql": return "SQL"
        case "swiftui": return "SwiftUI"
        case "typescript", "ts": return "TypeScript"
        case "ui": return "UI"
        case "ux": return "UX"
        default: return String(token).capitalized
        }
    }

    private static func minimumRepositorySupport(corpusCount: Int) -> Int {
        if corpusCount <= 8 { return 1 }
        if corpusCount <= 40 { return 2 }
        // 大仓库按约 0.3% 设置下限；1886 个 Star 时需至少 6 个仓库共同支持。
        return max(3, Int(ceil(Double(corpusCount) * 0.003)))
    }

    private static func normalizedSearchText(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " " }
            .reduce(into: "") { result, character in
                if character == " ", result.last == " " { return }
                result.append(character)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// README 只取标题与开头说明，并忽略 fenced code / badge / HTML 行。
    /// 这样既能识别项目用途，又不会让安装命令、依赖清单或徽章文本制造虚假命中。
    private static func relevantReadmeText(_ markdown: String) -> String {
        var isInsideCodeFence = false
        var output: [String] = []
        var characterCount = 0

        for rawLine in markdown.prefix(16_000).split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                isInsideCodeFence.toggle()
                continue
            }
            guard !isInsideCodeFence,
                  !line.isEmpty,
                  !line.hasPrefix("!["),
                  !line.hasPrefix("<")
            else { continue }

            let isHeading = line.hasPrefix("#")
            if isHeading || characterCount < 4_000 {
                output.append(line)
                characterCount += line.count
            }
            if characterCount >= 6_000 { break }
        }
        return output.joined(separator: " ")
    }
}
