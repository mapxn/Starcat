//
//  AIOrganizationDraftSnapshots.swift
//  Starcat
//
//  两套 AI 整理状态机的可持久化快照。
//
//  这些 DTO 刻意与运行时 Job 分离：运行时失败枚举可能包含 SDK Error，复制诊断还可能
//  带 Request / Response；草稿只保存恢复审核所必需的安全字段和短失败说明。
//

import Foundation

// MARK: - 批量标签整理

struct BatchAIOrganizationDraftHeader: Codable, Sendable {
    let options: BatchAIQueueOptions
    let startedAt: Date
    /// 增量扩词是用户尚未确认的生成结果，必须随现有批量草稿恢复，不能因退出 App 丢失。
    let pendingTagExpansionSession: TagTaxonomyBootstrapSession?
    /// 生成增量候选失败时保留待发现仓库，用户修复 Provider 后可只重试整批发现。
    let uncoveredTagRepositoryIDs: Set<Int64>?
    let tagExpansionError: String?

    init(
        options: BatchAIQueueOptions,
        startedAt: Date,
        pendingTagExpansionSession: TagTaxonomyBootstrapSession? = nil,
        uncoveredTagRepositoryIDs: Set<Int64>? = nil,
        tagExpansionError: String? = nil
    ) {
        self.options = options
        self.startedAt = startedAt
        self.pendingTagExpansionSession = pendingTagExpansionSession
        self.uncoveredTagRepositoryIDs = uncoveredTagRepositoryIDs
        self.tagExpansionError = tagExpansionError
    }
}

private enum PersistedBatchTagReviewKind: String, Codable, Sendable {
    case notRequired
    case pending
    case applying
    case applied
    case ignored
    case failed
}

private struct PersistedBelowThresholdTag: Codable, Sendable {
    let name: String
    let confidence: Double
}

struct BatchAIOrganizationDraftItem: Codable, Sendable {
    let repo: Repo
    let status: BatchAIJobStatus
    let attempts: Int
    let failureMessage: String?
    let errorDiagnostic: String?
    let appliedTagNames: [String]
    let suggestedTags: [AITagSuggestion]
    let selectedSuggestedTagIDs: Set<String>
    let suggestedTagAvailability: [String: BatchAITagSuggestionAvailability]
    private let tagReviewKind: PersistedBatchTagReviewKind
    private let tagReviewFailureMessage: String?
    /// 可选字段保证旧版本草稿在没有该 key 时仍能恢复，并由 UI 使用通用兜底文案。
    let ignoreReason: BatchAIIgnoreReason?
    private let belowThresholdTags: [PersistedBelowThresholdTag]
    let finishedAt: Date?
    let didGenerateSummary: Bool
    let isSelectedForTagApplication: Bool

    init(repo: Repo, job: BatchAIJob, isSelectedForTagApplication: Bool) {
        self.repo = repo
        self.status = job.status
        self.attempts = job.attempts
        self.failureMessage = job.failure?.localizedMessage
        self.errorDiagnostic = job.errorDiagnostic
        self.appliedTagNames = job.appliedTagNames
        self.suggestedTags = job.suggestedTags
        self.selectedSuggestedTagIDs = job.selectedSuggestedTagIDs
        self.suggestedTagAvailability = job.suggestedTagAvailability
        switch job.tagReviewState {
        case .notRequired:
            tagReviewKind = .notRequired
            tagReviewFailureMessage = nil
        case .pending:
            tagReviewKind = .pending
            tagReviewFailureMessage = nil
        case .applying:
            tagReviewKind = .applying
            tagReviewFailureMessage = nil
        case .applied:
            tagReviewKind = .applied
            tagReviewFailureMessage = nil
        case .ignored:
            tagReviewKind = .ignored
            tagReviewFailureMessage = nil
        case .failed(let failure):
            tagReviewKind = .failed
            tagReviewFailureMessage = failure.localizedMessage
        }
        self.ignoreReason = job.ignoreReason
        self.belowThresholdTags = job.belowThresholdTags.map {
            PersistedBelowThresholdTag(name: $0.name, confidence: $0.confidence)
        }
        self.finishedAt = job.finishedAt
        self.didGenerateSummary = job.didGenerateSummary
        self.isSelectedForTagApplication = isSelectedForTagApplication
    }

    /// 恢复时把进程退出瞬间的执行中状态收口为失败，不猜测远端是否完成，也不自动重放。
    func restoredJob() -> BatchAIJob {
        var job = BatchAIJob(
            repoId: repo.id,
            repoFullName: repo.fullName,
            repoDescription: repo.description,
            ownerAvatarURL: repo.ownerAvatar
        )
        job.status = status == .processing ? .failed : status
        job.attempts = attempts
        job.failure = status == .processing
            ? .interrupted
            : failureMessage.map { .unknown($0) }
        job.errorDiagnostic = errorDiagnostic
        // copyDiagnostic 可能包含完整 Provider payload，按设计永不持久化。
        job.copyDiagnostic = nil
        job.appliedTagNames = appliedTagNames
        job.suggestedTags = suggestedTags
        job.selectedSuggestedTagIDs = selectedSuggestedTagIDs
        job.suggestedTagAvailability = suggestedTagAvailability
        switch tagReviewKind {
        case .notRequired:
            job.tagReviewState = .notRequired
        case .pending:
            job.tagReviewState = .pending
        case .applying:
            job.tagReviewState = .failed(.interrupted)
        case .applied:
            job.tagReviewState = .applied
        case .ignored:
            job.tagReviewState = .ignored
        case .failed:
            job.tagReviewState = .failed(tagReviewFailureMessage.map { .unknown($0) } ?? .interrupted)
        }
        job.ignoreReason = ignoreReason
        job.belowThresholdTags = belowThresholdTags.map { ($0.name, $0.confidence) }
        job.finishedAt = status == .processing ? .now : finishedAt
        job.didGenerateSummary = didGenerateSummary
        return job
    }
}

// MARK: - GitHub Lists 分组

struct GitHubStarListAIOrganizationDraftHeader: Codable, Sendable {
    let availableLists: [GitHubStarList]
    let rules: [GitHubStarListAIRule]
    let membershipCountByListID: [String: Int]
    let preparedRepositoryCount: Int
    let ungroupedRepositoryCount: Int
    let preparedAnalysisRepositoryCount: Int
    let preparedAutomaticallyIgnoredRepoIDs: Set<Int64>
    let manualAutomaticThreshold: Double?
}

private enum PersistedGitHubStarListApplyKind: String, Codable, Sendable {
    case idle
    case applying
    case applied
    case ignored
    case failed
}

struct GitHubStarListAIOrganizationDraftItem: Codable, Sendable {
    let repo: Repo
    let status: GitHubStarListAIGroupingJobStatus
    let suggestions: [GitHubStarListAISuggestion]
    let analysisFailureMessage: String?
    private let applyKind: PersistedGitHubStarListApplyKind
    private let appliedListIDs: Set<String>
    private let applyFailureKind: GitHubStarListAIApplyFailureKind?
    private let applyFailureDetail: String?
    let finishedAt: Date?
    let isExcludedFromAnalysis: Bool
    /// Optional 保证旧版本草稿仍可解码；缺失时按已写入 GitHub 处理。
    let isLocallyApplied: Bool?
    let existingListIDs: Set<String>
    let selectedListIDs: Set<String>
    let isSelectedForBulkApply: Bool
    let editedListIDs: Set<String>?
    let isIgnored: Bool

    init(
        job: GitHubStarListAIGroupingJob,
        existingListIDs: Set<String>,
        selectedListIDs: Set<String>,
        isSelectedForBulkApply: Bool,
        editedListIDs: Set<String>?,
        isIgnored: Bool
    ) {
        self.repo = job.repo
        self.status = job.status
        self.suggestions = job.suggestions
        self.analysisFailureMessage = job.analysisFailure?.localizedMessage
        switch job.applyState {
        case .idle:
            applyKind = .idle
            appliedListIDs = []
            applyFailureKind = nil
            applyFailureDetail = nil
        case .applying:
            applyKind = .applying
            appliedListIDs = []
            applyFailureKind = nil
            applyFailureDetail = nil
        case .applied(let listIDs):
            applyKind = .applied
            appliedListIDs = listIDs
            applyFailureKind = nil
            applyFailureDetail = nil
        case .ignored(let failure):
            applyKind = .ignored
            appliedListIDs = []
            applyFailureKind = failure.kind
            applyFailureDetail = failure.detail
        case .failed(let failure):
            applyKind = .failed
            appliedListIDs = []
            applyFailureKind = failure.kind
            applyFailureDetail = failure.detail
        }
        self.finishedAt = job.finishedAt
        self.isExcludedFromAnalysis = job.isExcludedFromAnalysis
        self.isLocallyApplied = job.isLocallyApplied
        self.existingListIDs = existingListIDs
        self.selectedListIDs = selectedListIDs
        self.isSelectedForBulkApply = isSelectedForBulkApply
        self.editedListIDs = editedListIDs
        self.isIgnored = isIgnored
    }

    func restoredJob() -> GitHubStarListAIGroupingJob {
        let restoredStatus: GitHubStarListAIGroupingJobStatus = status == .analyzing ? .failed : status
        let restoredAnalysisFailure: BatchAIFailure? = status == .analyzing
            ? .interrupted
            : analysisFailureMessage.map { .unknown($0) }
        let restoredApplyState: GitHubStarListAIApplyState
        switch applyKind {
        case .idle:
            restoredApplyState = .idle
        case .applying:
            restoredApplyState = .failed(.init(kind: .interrupted, detail: nil))
        case .applied:
            restoredApplyState = .applied(appliedListIDs)
        case .ignored:
            restoredApplyState = .ignored(.init(
                kind: applyFailureKind ?? .permanent,
                detail: applyFailureDetail
            ))
        case .failed:
            restoredApplyState = .failed(.init(
                kind: applyFailureKind ?? .permanent,
                detail: applyFailureDetail
            ))
        }
        return GitHubStarListAIGroupingJob(
            repo: repo,
            status: restoredStatus,
            suggestions: suggestions,
            analysisFailure: restoredAnalysisFailure,
            applyState: restoredApplyState,
            finishedAt: status == .analyzing ? .now : finishedAt,
            isExcludedFromAnalysis: isExcludedFromAnalysis,
            isLocallyApplied: isLocallyApplied ?? false
        )
    }
}
