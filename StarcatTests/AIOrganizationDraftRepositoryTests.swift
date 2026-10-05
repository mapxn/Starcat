//
//  AIOrganizationDraftRepositoryTests.swift
//  StarcatTests
//
//  验证手动 AI 整理草稿的事务建档、逐仓更新与级联清理。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("AI organization draft repository")
struct AIOrganizationDraftRepositoryTests {

    @Test("批量标签草稿保留结构化忽略原因并兼容旧草稿")
    func preservesBatchTagIgnoreReason() throws {
        var repo = Repo.makeMinimal(owner: "octo", name: "ignored-draft")
        repo.id = 41
        var job = BatchAIJob(repoId: repo.id, repoFullName: repo.fullName)
        job.status = .ignored
        job.tagReviewState = .ignored
        job.ignoreReason = .taxonomyUncovered

        let snapshot = BatchAIOrganizationDraftItem(
            repo: repo,
            job: job,
            isSelectedForTagApplication: false
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(BatchAIOrganizationDraftItem.self, from: encoded).restoredJob()
        #expect(restored.ignoreReason == .taxonomyUncovered)

        // 旧草稿没有 ignoreReason key；Optional 的 Codable 恢复必须继续成功并交给 UI 通用兜底。
        job.ignoreReason = nil
        let legacySnapshot = BatchAIOrganizationDraftItem(
            repo: repo,
            job: job,
            isSelectedForTagApplication: false
        )
        let legacyEncoded = try JSONEncoder().encode(legacySnapshot)
        let legacyRestored = try JSONDecoder()
            .decode(BatchAIOrganizationDraftItem.self, from: legacyEncoded)
            .restoredJob()
        #expect(legacyRestored.ignoreReason == nil)
    }

    @Test("恢复时把执行中状态收口为可重试中断失败")
    func normalizesInterruptedStates() {
        var repo = Repo.makeMinimal(owner: "octo", name: "draft")
        repo.id = 42
        var tagJob = BatchAIJob(repoId: repo.id, repoFullName: repo.fullName)
        tagJob.status = .processing
        tagJob.tagReviewState = .applying
        let restoredTagJob = BatchAIOrganizationDraftItem(
            repo: repo,
            job: tagJob,
            isSelectedForTagApplication: true
        ).restoredJob()
        #expect(restoredTagJob.status == .failed)
        #expect(restoredTagJob.failure == .interrupted)
        #expect(restoredTagJob.tagReviewState == .failed(.interrupted))

        let groupingJob = GitHubStarListAIGroupingJob(
            repo: repo,
            status: .analyzing,
            applyState: .applying
        )
        let restoredGroupingJob = GitHubStarListAIOrganizationDraftItem(
            job: groupingJob,
            existingListIDs: [],
            selectedListIDs: ["list-1"],
            isSelectedForBulkApply: true,
            editedListIDs: nil,
            isIgnored: false
        ).restoredJob()
        #expect(restoredGroupingJob.status == .failed)
        #expect(restoredGroupingJob.analysisFailure == .interrupted)
        #expect(restoredGroupingJob.applyState == .failed(.init(kind: .interrupted, detail: nil)))
    }

    @Test("GitHub Lists 草稿保留本地应用状态")
    func preservesLocallyAppliedGroupingState() {
        var repo = Repo.makeMinimal(owner: "octo", name: "local-group")
        repo.id = 43
        let groupingJob = GitHubStarListAIGroupingJob(
            repo: repo,
            status: .completed,
            applyState: .applied(["list-1"]),
            isLocallyApplied: true
        )

        let restored = GitHubStarListAIOrganizationDraftItem(
            job: groupingJob,
            existingListIDs: ["list-1"],
            selectedListIDs: [],
            isSelectedForBulkApply: false,
            editedListIDs: nil,
            isIgnored: false
        ).restoredJob()

        #expect(restored.applyState == .applied(["list-1"]))
        #expect(restored.isLocallyApplied)
    }

    @Test("同类草稿原子替换并逐仓更新")
    func replaceAndUpdateItems() async throws {
        let database = try InMemoryDatabaseManager(userId: 1)
        let repository = GRDBAIOrganizationDraftRepository(database: database)
        let draftID = UUID()
        try await repository.replaceDraft(AIOrganizationDraft(
            id: draftID,
            kind: .batchTags,
            headerJSON: #"{"version":1}"#,
            items: [
                AIOrganizationDraftItem(repoID: 1, payloadJSON: #"{"status":"queued"}"#),
                AIOrganizationDraftItem(repoID: 2, payloadJSON: #"{"status":"queued"}"#),
            ]
        ))

        try await repository.upsertItem(
            draftID: draftID,
            kind: .batchTags,
            repoID: 1,
            payloadJSON: #"{"status":"completed"}"#
        )
        try await repository.deleteItems(draftID: draftID, kind: .batchTags, repoIDs: [2])

        let restored = try #require(try await repository.loadDraft(kind: .batchTags))
        #expect(restored.id == draftID)
        #expect(restored.items == [
            AIOrganizationDraftItem(repoID: 1, payloadJSON: #"{"status":"completed"}"#)
        ])
    }

    @Test("批量更新逐仓草稿并保留未涉及的 Item")
    func batchUpdatesItems() async throws {
        let database = try InMemoryDatabaseManager(userId: 1)
        let repository = GRDBAIOrganizationDraftRepository(database: database)
        let draftID = UUID()
        try await repository.replaceDraft(AIOrganizationDraft(
            id: draftID,
            kind: .batchTags,
            headerJSON: #"{"version":1}"#,
            items: [
                AIOrganizationDraftItem(repoID: 1, payloadJSON: #"{"status":"queued"}"#),
                AIOrganizationDraftItem(repoID: 2, payloadJSON: #"{"status":"queued"}"#),
                AIOrganizationDraftItem(repoID: 3, payloadJSON: #"{"status":"queued"}"#),
            ]
        ))

        try await repository.upsertItems(
            draftID: draftID,
            kind: .batchTags,
            items: [
                AIOrganizationDraftItem(repoID: 1, payloadJSON: #"{"status":"completed"}"#),
                AIOrganizationDraftItem(repoID: 2, payloadJSON: #"{"status":"failed"}"#),
            ]
        )

        let restored = try #require(try await repository.loadDraft(kind: .batchTags))
        #expect(restored.items == [
            AIOrganizationDraftItem(repoID: 1, payloadJSON: #"{"status":"completed"}"#),
            AIOrganizationDraftItem(repoID: 2, payloadJSON: #"{"status":"failed"}"#),
            AIOrganizationDraftItem(repoID: 3, payloadJSON: #"{"status":"queued"}"#),
        ])
    }

    @Test("删除 Header 会级联清理逐仓 Item")
    func deleteDraftCascadesItems() async throws {
        let database = try InMemoryDatabaseManager(userId: 1)
        let repository = GRDBAIOrganizationDraftRepository(database: database)
        let draftID = UUID()
        try await repository.replaceDraft(AIOrganizationDraft(
            id: draftID,
            kind: .githubStarLists,
            headerJSON: "{}",
            items: [AIOrganizationDraftItem(repoID: 7, payloadJSON: "{}")]
        ))

        try await repository.deleteDraft(draftID: draftID, kind: .githubStarLists)

        #expect(try await repository.loadDraft(kind: .githubStarLists) == nil)
        let itemCount = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ai_organization_draft_items") ?? -1
        }
        #expect(itemCount == 0)
    }
}
