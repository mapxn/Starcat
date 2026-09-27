//
//  LocalAIModelStorage.swift
//  Starcat
//
//  本地 AI 模型磁盘布局与安装清单（manifest）读写。
//
//  关键约束：
//  - 模型是「机器级资源」，不进 per-user 数据库：数据库按 users/<userId>/ 隔离，
//    而模型应该跨账号共享。安装状态单一真源 = 每个模型目录里的 manifest.json。
//  - 当前路径统一落在 Local AI App Group。App Store / Direct 只共享模型资源，
//    用户数据库、偏好和缓存仍按渠道隔离。
//  - 旧路径仍可解析，但只供一次性迁移读取，禁止新下载继续写入旧目录。
//  - 目录名 = `<entry.id>@<revision>`：revision 进目录名让版本可追溯；同时保证
//    Qwen3 reranker 的目录名包含 "rerank"，满足 `RerankerModelFactory` 的
//    verified-naming 要求。
//  - 启动扫描容忍脏目录：没有 manifest 的目录视为未完成下载，可被清理。
//

import Foundation
import CryptoKit

/// 单个已安装文件的校验记录。SHA256 在下载完成时流式计算，供后续完整性检查。
struct LocalAIFileRecord: Codable, Equatable, Sendable {
    var name: String
    var sha256: String
    var sizeBytes: Int64
}

/// 一个已安装模型的安装清单。
struct LocalAIInstalledModel: Codable, Equatable, Identifiable, Sendable {
    /// catalog entry id，如 `qwen3-embedding-0.6b-8bit`。
    var id: String
    var displayName: String
    var type: LocalAIModelType
    /// 安装时解析出的仓库 revision（commit SHA）。
    var revision: String
    var installedAt: Date
    var sourceKind: LocalAIModelSource.Kind
    var files: [LocalAIFileRecord]
    /// embedding 专用维度，写入向量元数据口径。
    var embeddingDimension: Int?
    var totalBytes: Int64

    var idWithRevision: String { "\(id)@\(revision)" }
}

/// manifest 存取 / 目录解析的纯函数集合。线程安全：无状态，全部显式传参。
enum LocalAIModelStorage {

    /// 单测注入的 models 根目录。仅 `TestEnvironment.isRunning` 时生效，
    /// 避免测试把文件写进测试宿主真实的 Application Support。
    nonisolated(unsafe) static var testRootOverride: URL?
    /// 单测注入的旧版 models 根目录。与共享根目录分开，才能覆盖迁移 / 冲突场景。
    nonisolated(unsafe) static var testLegacyRootOverride: URL?

    enum StorageError: LocalizedError, Equatable {
        case applicationSupportUnavailable
        case manifestCorrupted(String)

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                return String.l10n("settings.localai.error.applicationSupportUnavailable")
            case .manifestCorrupted(let path):
                return String(
                    format: String.l10n("settings.localai.error.manifestCorruptedFormat"), path)
            }
        }
    }

    // MARK: - 路径解析

    /// App Group 内的版本化共享模型目录。
    ///
    /// `v1` 是磁盘协议版本，不是 App 版本。未来若目录语义变化，应新增版本迁移，
    /// 不能原地改变已安装用户的共享目录解释方式。
    static func modelsRootURL(fileManager: FileManager = .default) throws -> URL {
        if TestEnvironment.isRunning, let testRootOverride {
            return testRootOverride
        }
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.localAIAppGroupIdentifier
        ) else {
            throw StorageError.applicationSupportUnavailable
        }
        return container
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Starcat", isDirectory: true)
            .appendingPathComponent("LocalAI", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// 当前渠道升级前使用的私有模型目录。沙盒版与 Direct 版会解析到各自旧位置。
    static func legacyModelsRootURL(fileManager: FileManager = .default) throws -> URL {
        if TestEnvironment.isRunning, let testLegacyRootOverride {
            return testLegacyRootOverride
        }
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw StorageError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// 锁文件与模型目录分离，删除全部模型时不会删掉正在协调其它进程的 inode。
    static func locksRootURL(fileManager: FileManager = .default) throws -> URL {
        try modelsRootURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("locks", isDirectory: true)
    }

    /// 某个 catalog 类型在 models 下的子目录（embedding / reranker / llm）。
    static func typeDirectory(
        for type: LocalAIModelType, fileManager: FileManager = .default
    ) throws -> URL {
        typeDirectory(
            for: type,
            modelsRoot: try modelsRootURL(fileManager: fileManager))
    }

    static func typeDirectory(for type: LocalAIModelType, modelsRoot: URL) -> URL {
        modelsRoot
            .appendingPathComponent(type.storagePathComponent, isDirectory: true)
    }

    /// 单个模型安装目录：`models/<type>/<entry.id>@<revision>/`。
    static func modelDirectory(
        entry: LocalAIModelCatalogEntry, revision: String, fileManager: FileManager = .default
    ) throws -> URL {
        modelDirectory(
            entry: entry,
            revision: revision,
            modelsRoot: try modelsRootURL(fileManager: fileManager))
    }

    static func modelDirectory(
        entry: LocalAIModelCatalogEntry, revision: String, modelsRoot: URL
    ) -> URL {
        typeDirectory(for: entry.type, modelsRoot: modelsRoot)
            .appendingPathComponent("\(entry.id)@\(revision)", isDirectory: true)
    }

    static func manifestURL(in modelDirectory: URL) -> URL {
        modelDirectory.appendingPathComponent("manifest.json")
    }

    /// 线程安全便捷查询：按 entry id 扫描磁盘解析安装目录。
    ///
    /// 为什么不走 `LocalAIModelManager`：manager 是 @MainActor 的 UI 状态机，而
    /// `LocalMLXClient` 的模型目录解析发生在推理任务上下文（任意线程）。磁盘扫描
    /// 是本模块的唯一真源，推理路径直接读它，避免跨 actor 阻塞。
    static func installedDirectoryURL(
        entryID: String, fileManager: FileManager = .default
    ) -> URL? {
        guard let entry = LocalAIModelCatalog.entry(id: entryID),
            let manifest = try? listInstalled(fileManager: fileManager)
                .first(where: { $0.id == entryID })
        else { return nil }
        return try? modelDirectory(entry: entry, revision: manifest.revision, fileManager: fileManager)
    }

    // MARK: - manifest 读写

    static func save(
        _ manifest: LocalAIInstalledModel, in modelDirectory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: modelDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder.prettySorted.encode(manifest)
        try data.write(to: manifestURL(in: modelDirectory), options: .atomic)
    }

    static func loadManifest(
        from modelDirectory: URL, fileManager: FileManager = .default
    ) throws -> LocalAIInstalledModel? {
        let url = manifestURL(in: modelDirectory)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder.manifest.decode(
                LocalAIInstalledModel.self, from: Data(contentsOf: url))
        } catch {
            throw StorageError.manifestCorrupted(modelDirectory.lastPathComponent)
        }
    }

    /// 扫描全部类型子目录，返回已安装模型列表（按类型 + id 排序，保证 UI 稳定）。
    ///
    /// 无 manifest 的目录视为未完成下载，静默跳过（由 `cleanIncompleteDownloads` 物理清理）。
    static func listInstalled(fileManager: FileManager = .default) throws -> [LocalAIInstalledModel] {
        try listInstalled(
            at: modelsRootURL(fileManager: fileManager),
            fileManager: fileManager)
    }

    static func listInstalled(
        at modelsRoot: URL, fileManager: FileManager = .default
    ) throws -> [LocalAIInstalledModel] {
        var result: [LocalAIInstalledModel] = []
        for type in LocalAIModelType.allCases {
            let typeDir = typeDirectory(for: type, modelsRoot: modelsRoot)
            let children = (try? fileManager.contentsOfDirectory(
                at: typeDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else { continue }
                if let manifest = try loadManifest(from: child, fileManager: fileManager) {
                    result.append(manifest)
                }
            }
        }
        return result
    }

    /// 返回根目录下全部模型目录，包括没有 manifest 的未完成目录。
    static func modelDirectories(
        at modelsRoot: URL, fileManager: FileManager = .default
    ) -> [URL] {
        LocalAIModelType.allCases.flatMap { type in
            let typeRoot = typeDirectory(for: type, modelsRoot: modelsRoot)
            return ((try? fileManager.contentsOfDirectory(
                at: typeRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []).filter { child in
                    (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
        }
    }

    /// 校验 manifest 声明的文件、大小与 SHA256。迁移删除旧副本前必须通过此检查。
    static func isInstallationValid(
        manifest: LocalAIInstalledModel,
        directory: URL,
        verifyHashes: Bool,
        fileManager: FileManager = .default
    ) -> Bool {
        guard !manifest.files.isEmpty else { return false }
        for file in manifest.files {
            let url = directory.appendingPathComponent(file.name, isDirectory: false)
            guard fileManager.fileExists(atPath: url.path),
                let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                let number = attributes[.size] as? NSNumber,
                number.int64Value == file.sizeBytes
            else { return false }
            if verifyHashes {
                guard let digest = try? sha256(ofFileAt: url),
                    digest.caseInsensitiveCompare(file.sha256) == .orderedSame
                else { return false }
            }
        }
        return true
    }

    /// 判断两个清单是否描述同一份不可变模型内容；安装时间和下载源不影响等价性。
    static func hasSameContent(
        _ lhs: LocalAIInstalledModel,
        _ rhs: LocalAIInstalledModel
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.type == rhs.type
            && lhs.revision == rhs.revision
            && lhs.files.sorted(by: { $0.name < $1.name }) == rhs.files.sorted(by: { $0.name < $1.name })
            && lhs.embeddingDimension == rhs.embeddingDimension
            && lhs.totalBytes == rhs.totalBytes
    }

    /// 删除整个模型目录。
    static func remove(modelDirectory: URL) throws {
        try FileManager.default.removeItem(at: modelDirectory)
    }

    // MARK: - 用量与清理

    /// models 根目录总占用（字节）。
    static func totalDiskUsage(fileManager: FileManager = .default) -> Int64 {
        guard let root = try? modelsRootURL(fileManager: fileManager) else { return 0 }
        return directorySize(at: root, fileManager: fileManager)
    }

    static func directorySize(
        at url: URL, fileManager: FileManager = .default
    ) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    /// 清理残留的 `.part` 临时文件（断点续传的中间产物）。
    static func cleanPartialFiles(fileManager: FileManager = .default) {
        guard let root = try? modelsRootURL(fileManager: fileManager),
            let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return }
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "part" {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    /// 流式计算文件 SHA256。
    static func sha256(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension JSONEncoder {
    /// manifest 用：pretty 输出 + keys 排序，保证同一内容序列化结果稳定（diff 友好）。
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var manifest: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
