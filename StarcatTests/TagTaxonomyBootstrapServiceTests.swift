//
//  TagTaxonomyBootstrapServiceTests.swift
//  StarcatTests
//
//  首次标签体系本地候选生成的回归测试。
//
//  重点验证：单仓独有 topic 不会膨胀成标签、README 只能补强受控概念、目标范围与
//  全库语料严格分离，以及最终建议明确标记为 local 而不是伪装成 Jev / LLM。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Local tag taxonomy bootstrap")
struct TagTaxonomyBootstrapServiceTests {
    @Test("大语料只保留跨仓库重复候选")
    func filtersSingleRepositoryTopics() async {
        let corpus = (1...41).map { index -> Repo in
            var repo = makeRepo(id: index)
            repo.topics = topicsJSON(index <= 3 ? ["machine-learning"] : ["unique-topic-\(index)"])
            return repo
        }

        let session = await TagTaxonomyBootstrapAnalyzer().analyze(
            corpusRepositories: corpus,
            targetRepositories: corpus,
            cachedReadmesByRepositoryID: [:]
        )

        let ai = session.candidates.first { $0.name == "AI" }
        #expect(ai?.supportCount == 3)
        #expect(session.candidates.allSatisfy { !$0.name.hasPrefix("Unique Topic") })
        #expect(session.candidates.count <= 24)
    }

    @Test("缓存 README 只补强受控技术概念")
    func cachedReadmeAddsControlledConceptEvidence() async {
        let corpus = (1...10).map { makeRepo(id: $0) }
        let readmes = [
            corpus[0].id: "# Storage\nA PostgreSQL database toolkit for applications.",
            corpus[1].id: "# Query Layer\nBuild reliable database clients with SQLite."
        ]

        let session = await TagTaxonomyBootstrapAnalyzer().analyze(
            corpusRepositories: corpus,
            targetRepositories: corpus,
            cachedReadmesByRepositoryID: readmes
        )

        let database = session.candidates.first { $0.name == "Database" }
        #expect(database?.supportCount == 2)
        #expect(database?.signals.contains(.readme) == true)
        #expect(session.cachedReadmeCount == 2)
    }

    @Test("全库候选只映射到本轮目标仓库")
    func mapsGlobalCandidatesOnlyToTargetScope() async throws {
        var first = makeRepo(id: 1)
        first.language = "Swift"
        var second = makeRepo(id: 2)
        second.language = "Swift"
        var outsideTarget = makeRepo(id: 3)
        outsideTarget.language = "Swift"

        let session = await TagTaxonomyBootstrapAnalyzer().analyze(
            corpusRepositories: [first, second, outsideTarget],
            targetRepositories: [first, second],
            cachedReadmesByRepositoryID: [:]
        )
        var swift = try #require(session.candidates.first { $0.name == "Swift" })
        swift.name = "Apple Development"

        let suggestions = session.suggestions(
            candidates: [swift],
            maximumPerRepository: 1,
            reason: "local evidence"
        )

        #expect(suggestions.keys.sorted() == [first.id, second.id])
        #expect(suggestions[outsideTarget.id] == nil)
        #expect(suggestions[first.id]?.first?.name == "Apple Development")
        #expect(suggestions[first.id]?.first?.engine == .local)
    }

    @Test("全部 topic 均为单仓独有时不生成候选")
    func rejectsOneTagPerRepositoryShape() async {
        let corpus = (1...12).map { index -> Repo in
            var repo = makeRepo(id: index)
            repo.topics = topicsJSON(["isolated-concept-\(index)"])
            return repo
        }

        let session = await TagTaxonomyBootstrapAnalyzer().analyze(
            corpusRepositories: corpus,
            targetRepositories: corpus,
            cachedReadmesByRepositoryID: [:]
        )

        #expect(session.candidates.isEmpty)
    }

    private func makeRepo(id: Int) -> Repo {
        var repo = Repo.makeMinimal(owner: "acme", name: "repo-\(id)")
        repo.id = Int64(id)
        repo.description = nil
        repo.language = nil
        repo.topics = nil
        repo.isStarred = true
        return repo
    }

    private func topicsJSON(_ topics: [String]) -> String {
        let data = try! JSONEncoder().encode(topics)
        return String(decoding: data, as: UTF8.self)
    }
}
