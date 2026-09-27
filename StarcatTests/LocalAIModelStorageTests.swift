//
//  LocalAIModelStorageTests.swift
//  StarcatTests
//
//  本地模型存储：manifest 读写、安装列表扫描、脏目录容错、清理与用量统计。
//  通过 `LocalAIModelStorage.testRootOverride` 把 models 根目录指到临时目录，
//  避免污染测试宿主的真实 Application Support。
//

import Foundation
import Testing
@testable import Starcat

@Suite("LocalAIModelStorage", .serialized)
struct LocalAIModelStorageTests {

    private var tempRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("localai-storage-tests-\(UUID().uuidString)", isDirectory: true)
    }

    /// 写一个假模型目录（带或不带 manifest）。
    private func makeModelDirectory(
        entry: LocalAIModelCatalogEntry, revision: String, manifest: LocalAIInstalledModel?
    ) throws -> URL {
        let directory = try LocalAIModelStorage.modelDirectory(entry: entry, revision: revision)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("model.safetensors")
        try Data("weights".utf8).write(to: fileURL)
        if let manifest {
            try LocalAIModelStorage.save(manifest, in: directory)
        }
        return directory
    }

    private func sampleManifest(_ entry: LocalAIModelCatalogEntry, revision: String) -> LocalAIInstalledModel {
        LocalAIInstalledModel(
            id: entry.id,
            displayName: entry.displayName,
            type: entry.type,
            revision: revision,
            installedAt: Date(timeIntervalSince1970: 100),
            sourceKind: .huggingFace,
            files: [LocalAIFileRecord(name: "model.safetensors", sha256: "abc", sizeBytes: 7)],
            embeddingDimension: entry.embeddingDimension,
            totalBytes: 7)
    }

    /// 迁移测试必须使用真实摘要；生产迁移在删旧副本前会逐文件校验 SHA256。
    private func makeValidModelDirectory(
        at modelsRoot: URL,
        entry: LocalAIModelCatalogEntry,
        revision: String,
        contents: Data = Data("weights".utf8)
    ) throws -> (directory: URL, manifest: LocalAIInstalledModel) {
        let directory = LocalAIModelStorage.modelDirectory(
            entry: entry,
            revision: revision,
            modelsRoot: modelsRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("model.safetensors")
        try contents.write(to: fileURL)
        let manifest = LocalAIInstalledModel(
            id: entry.id,
            displayName: entry.displayName,
            type: entry.type,
            revision: revision,
            installedAt: Date(timeIntervalSince1970: 100),
            sourceKind: .huggingFace,
            files: [LocalAIFileRecord(
                name: "model.safetensors",
                sha256: try LocalAIModelStorage.sha256(ofFileAt: fileURL),
                sizeBytes: Int64(contents.count))],
            embeddingDimension: entry.embeddingDimension,
            totalBytes: Int64(contents.count))
        try LocalAIModelStorage.save(manifest, in: directory)
        return (directory, manifest)
    }

    @Test("manifest 写后可读且字段一致")
    func manifestRoundtrip() throws {
        let root = tempRoot
        LocalAIModelStorage.testRootOverride = root
        defer {
            LocalAIModelStorage.testRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        let entry = LocalAIModelCatalog.embedding
        let revision = "rev123"
        let manifest = sampleManifest(entry, revision: revision)
        let directory = try LocalAIModelStorage.modelDirectory(entry: entry, revision: revision)
        try LocalAIModelStorage.save(manifest, in: directory)

        let loaded = try LocalAIModelStorage.loadManifest(from: directory)
        #expect(loaded == manifest)
        #expect(loaded?.revision == "rev123")
        #expect(LocalAIModelStorage.installedDirectoryURL(entryID: entry.id)?.path == directory.path)
    }

    @Test("无 manifest 的脏目录被扫描跳过且可清理")
    func dirtyDirectorySkipped() throws {
        let root = tempRoot
        LocalAIModelStorage.testRootOverride = root
        defer {
            LocalAIModelStorage.testRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        let entry = LocalAIModelCatalog.llm
        _ = try makeModelDirectory(entry: entry, revision: "r1", manifest: nil)

        #expect(try LocalAIModelStorage.listInstalled().isEmpty)
        #expect(LocalAIModelStorage.installedDirectoryURL(entryID: entry.id) == nil)
    }

    @Test("listInstalled 覆盖多个类型子目录")
    func listAcrossTypes() throws {
        let root = tempRoot
        LocalAIModelStorage.testRootOverride = root
        defer {
            LocalAIModelStorage.testRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        _ = try makeModelDirectory(
            entry: LocalAIModelCatalog.embedding, revision: "r1",
            manifest: sampleManifest(LocalAIModelCatalog.embedding, revision: "r1"))
        _ = try makeModelDirectory(
            entry: LocalAIModelCatalog.reranker, revision: "r2",
            manifest: sampleManifest(LocalAIModelCatalog.reranker, revision: "r2"))

        let installed = try LocalAIModelStorage.listInstalled()
        #expect(Set(installed.map(\.id)) == [LocalAIModelCatalog.embedding.id, LocalAIModelCatalog.reranker.id])
    }

    @Test("损坏的 manifest 抛出明确错误")
    func corruptedManifestThrows() throws {
        let root = tempRoot
        LocalAIModelStorage.testRootOverride = root
        defer {
            LocalAIModelStorage.testRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        let entry = LocalAIModelCatalog.embedding
        let directory = try LocalAIModelStorage.modelDirectory(entry: entry, revision: "rx")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: LocalAIModelStorage.manifestURL(in: directory))

        #expect(throws: LocalAIModelStorage.StorageError.manifestCorrupted(directory.lastPathComponent)) {
            _ = try LocalAIModelStorage.loadManifest(from: directory)
        }
    }

    @Test("删除模型目录与残留 .part 清理")
    func deleteAndPartialCleanup() throws {
        let root = tempRoot
        LocalAIModelStorage.testRootOverride = root
        defer {
            LocalAIModelStorage.testRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        let entry = LocalAIModelCatalog.embedding
        let directory = try makeModelDirectory(
            entry: entry, revision: "r1",
            manifest: sampleManifest(entry, revision: "r1"))
        let partURL = directory.appendingPathComponent("tokenizer.json.part")
        try Data("partial".utf8).write(to: partURL)

        try LocalAIModelStorage.remove(modelDirectory: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        // 另一个目录残留 .part，应被 cleanPartialFiles 清掉。
        let other = try LocalAIModelStorage.modelDirectory(entry: entry, revision: "r2")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherPart = other.appendingPathComponent("model.safetensors.part")
        try Data("x".utf8).write(to: otherPart)
        LocalAIModelStorage.cleanPartialFiles()
        #expect(!FileManager.default.fileExists(atPath: otherPart.path))
    }

    @Test("目录用量统计大于零")
    func directorySize() throws {
        let root = tempRoot
        LocalAIModelStorage.testRootOverride = root
        defer {
            LocalAIModelStorage.testRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        _ = try makeModelDirectory(
            entry: LocalAIModelCatalog.embedding, revision: "r1",
            manifest: sampleManifest(LocalAIModelCatalog.embedding, revision: "r1"))
        #expect(LocalAIModelStorage.totalDiskUsage() > 0)
    }

    @Test("完整旧模型迁入共享目录并删除已验证旧副本")
    func migratesVerifiedLegacyModel() async throws {
        let base = tempRoot
        let sharedRoot = base.appendingPathComponent("shared", isDirectory: true)
        let legacyRoot = base.appendingPathComponent("legacy", isDirectory: true)
        LocalAIModelStorage.testRootOverride = sharedRoot
        LocalAIModelStorage.testLegacyRootOverride = legacyRoot
        defer {
            LocalAIModelStorage.testRootOverride = nil
            LocalAIModelStorage.testLegacyRootOverride = nil
            try? FileManager.default.removeItem(at: base)
        }

        let entry = LocalAIModelCatalog.embedding
        let source = try makeValidModelDirectory(
            at: legacyRoot,
            entry: entry,
            revision: "migration-r1").directory
        let report = try await LocalAISharedModelCoordinator.shared
            .prepareSharedStorageIfNeeded()
        let destination = LocalAIModelStorage.modelDirectory(
            entry: entry,
            revision: "migration-r1",
            modelsRoot: sharedRoot)

        #expect(report.migrated == [source.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("共享目录已有同内容模型时只删除校验通过的旧重复副本")
    func deduplicatesIdenticalLegacyModel() async throws {
        let base = tempRoot
        let sharedRoot = base.appendingPathComponent("shared", isDirectory: true)
        let legacyRoot = base.appendingPathComponent("legacy", isDirectory: true)
        LocalAIModelStorage.testRootOverride = sharedRoot
        LocalAIModelStorage.testLegacyRootOverride = legacyRoot
        defer {
            LocalAIModelStorage.testRootOverride = nil
            LocalAIModelStorage.testLegacyRootOverride = nil
            try? FileManager.default.removeItem(at: base)
        }

        let entry = LocalAIModelCatalog.reranker
        let source = try makeValidModelDirectory(
            at: legacyRoot,
            entry: entry,
            revision: "same-r1").directory
        _ = try makeValidModelDirectory(
            at: sharedRoot,
            entry: entry,
            revision: "same-r1")

        let report = try await LocalAISharedModelCoordinator.shared
            .prepareSharedStorageIfNeeded()
        #expect(report.deduplicated == [source.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
    }

    @Test("共享目录内容冲突时保留旧模型且不覆盖目标")
    func preservesConflictingLegacyModel() async throws {
        let base = tempRoot
        let sharedRoot = base.appendingPathComponent("shared", isDirectory: true)
        let legacyRoot = base.appendingPathComponent("legacy", isDirectory: true)
        LocalAIModelStorage.testRootOverride = sharedRoot
        LocalAIModelStorage.testLegacyRootOverride = legacyRoot
        defer {
            LocalAIModelStorage.testRootOverride = nil
            LocalAIModelStorage.testLegacyRootOverride = nil
            try? FileManager.default.removeItem(at: base)
        }

        let entry = LocalAIModelCatalog.llm
        let source = try makeValidModelDirectory(
            at: legacyRoot,
            entry: entry,
            revision: "conflict-r1",
            contents: Data("legacy".utf8)).directory
        let destination = try makeValidModelDirectory(
            at: sharedRoot,
            entry: entry,
            revision: "conflict-r1",
            contents: Data("shared".utf8)).directory

        let report = try await LocalAISharedModelCoordinator.shared
            .prepareSharedStorageIfNeeded()
        #expect(report.preserved == [source.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: destination.appendingPathComponent("model.safetensors")) == Data("shared".utf8))
    }

    @Test("共享读锁释放前同模型独占锁不会取得")
    func sharedLeaseBlocksExclusiveLease() async throws {
        let base = tempRoot
        let sharedRoot = base.appendingPathComponent("shared", isDirectory: true)
        let legacyRoot = base.appendingPathComponent("legacy", isDirectory: true)
        LocalAIModelStorage.testRootOverride = sharedRoot
        LocalAIModelStorage.testLegacyRootOverride = legacyRoot
        defer {
            LocalAIModelStorage.testRootOverride = nil
            LocalAIModelStorage.testLegacyRootOverride = nil
            try? FileManager.default.removeItem(at: base)
        }

        let directory = LocalAIModelStorage.modelDirectory(
            entry: LocalAIModelCatalog.embedding,
            revision: "lock-r1",
            modelsRoot: sharedRoot)
        let readLease = try await LocalAISharedModelCoordinator.shared
            .acquireModelRead(at: directory)
        let probe = LocalAIFileLockProbe()
        let writer = Task {
            let lease = try await LocalAISharedModelCoordinator.shared
                .acquireModelWrite(at: directory)
            await probe.markAcquired()
            return lease
        }

        try await Task.sleep(for: .milliseconds(150))
        #expect(await probe.isAcquired == false)
        readLease.release()
        let writeLease = try await writer.value
        #expect(await probe.isAcquired)
        writeLease.release()
    }
}

private actor LocalAIFileLockProbe {
    private(set) var isAcquired = false

    func markAcquired() {
        isAcquired = true
    }
}
