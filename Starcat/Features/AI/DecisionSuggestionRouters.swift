//
//  DecisionSuggestionRouters.swift
//  Starcat
//
//  实验性决策引擎与既有 LLM 路径之间的统一路由。
//
//  选择的引擎在调用前不可用时走原 LLM；一旦引擎开始执行，失败会原样上抛，
//  不自动改用另一个决策引擎或再次调用 LLM，避免重复费用、延迟和语义漂移。
//

import Foundation

@MainActor
final class DecisionGitHubListSuggestionRouter: GitHubStarListSuggestionProviding {
    private let llmProvider: any GitHubStarListSuggestionProviding
    private let decisionProvider: RepositoryDecisionService
    private let settings: AppSettings

    init(
        llmProvider: any GitHubStarListSuggestionProviding,
        decisionProvider: RepositoryDecisionService,
        settings: AppSettings
    ) {
        self.llmProvider = llmProvider
        self.decisionProvider = decisionProvider
        self.settings = settings
    }

    private var shouldRouteToDecisionEngine: Bool {
        settings.decisionEngineEnabled
            && settings.decisionGroupingSuggestionsEnabled
            && decisionProvider.isSelectedEngineAvailable
    }

    func generateGitHubListSuggestions(
        for repos: [Repo],
        candidates: [GitHubStarListAIContext],
        existingListIDsByRepo: [Int64: Set<String>],
        existingListNamesByRepo: [Int64: [String]]
    ) async throws -> [Int64: [GitHubStarListAISuggestion]] {
        if shouldRouteToDecisionEngine {
            do {
                return try await decisionProvider.generateGitHubListSuggestions(
                    for: repos,
                    candidates: candidates,
                    existingListIDsByRepo: existingListIDsByRepo,
                    existingListNamesByRepo: existingListNamesByRepo
                )
            } catch {
                AppLog.ai.error(
                    "[decisionEngine] grouping suggestions failed, surfacing error: \(error.localizedDescription, privacy: .public)"
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

@MainActor
final class DecisionTagSuggestionRouter {
    private let decisionProvider: RepositoryDecisionService
    private let settings: AppSettings

    init(
        decisionProvider: RepositoryDecisionService,
        settings: AppSettings
    ) {
        self.decisionProvider = decisionProvider
        self.settings = settings
    }

    var isRoutingToDecisionEngine: Bool {
        settings.decisionEngineEnabled
            && settings.decisionTagSuggestionsEnabled
            && decisionProvider.isSelectedEngineAvailable
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
        guard isRoutingToDecisionEngine else {
            return try await llmFallback(repos, tagHintsByRepoID, .reuseFirst)
        }

        do {
            let reusableResults = try await decisionProvider.generateBatchTagSuggestions(
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
            // 决策模型只复用既有词表；确需新概念时仍由 LLM 生成一次，新标签不再
            // 回送决策引擎二次否决，否则缺少历史样本的新词会天然吃亏。
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
                let reusableLimit = max(0, maximum - normalizedNew.count)
                mergedResults[repo.id] = AITagSuggestionPolicy.sortedByConfidenceDescending(
                    Array(reusable.prefix(reusableLimit)) + normalizedNew
                )
            }
            return mergedResults
        } catch {
            AppLog.ai.error(
                "[decisionEngine] tag suggestions failed, surfacing error: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }
}
