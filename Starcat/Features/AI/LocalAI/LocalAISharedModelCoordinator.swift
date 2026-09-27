//
//  LocalAISharedModelCoordinator.swift
//  Starcat
//
//  App Store / Direct 本地 AI 模型共享协调器：旧目录迁移、跨进程文件锁与安全删除。
//
//  为什么不能只把路径改到 App Group：两个 App 可能同时推理、下载或删除同一模型。
//  没有跨进程锁时，另一个进程可在 MLX mmap 权重期间删目录，或两个下载任务同时写
//  `.part` 文件。这里用 BSD flock 建立统一锁层级：
//  - 全局 shared + 单模型 shared：模型驻留 / 推理；
//  - 全局 shared + 单模型 exclusive：下载 / 单模型删除；
//  - 全局 exclusive：旧目录迁移 / 删除全部 / 清理临时文件。
//
//  锁文件位于 models 同级的 locks 目录，删除全部模型不会删除正在协调进程的 inode。
//

import CryptoKit
import Darwin
import Foundation

// Darwin 同时导出 `struct flock`，Swift 名称解析会遮蔽同名 C 函数；用独立符号名
// 绑定 libc 的 flock(2)，避免退回不具备同进程 descriptor 冲突语义的 fcntl 锁。
@_silgen_name("flock")
private func starcatFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// 一次旧目录迁移的可审计结果。被保留项不会被静默覆盖或删除。
struct LocalAIModelMigrationReport: Equatable, Sendable {
    var migrated: [String] = []
    var deduplicated: [String] = []
    var preserved: [String] = []
}

/// 一个已取得的 flock。显式 release 与 deinit 都是幂等的，便于跨 actor 持有。
final class LocalAIFileLockLease: @unchecked Sendable {
    private let mutex = NSLock()
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func release() {
        mutex.lock()
        guard let descriptor else {
            mutex.unlock()
            return
        }
        self.descriptor = nil
        mutex.unlock()

        _ = starcatFlock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }

    deinit {
        release()
    }
}

/// 一次模型访问同时持有全局锁和模型锁，释放时按获取顺序的反向释放。
final class LocalAIModelAccessLease: @unchecked Sendable {
    private let mutex = NSLock()
    private var globalLease: LocalAIFileLockLease?
    private var modelLease: LocalAIFileLockLease?

    init(globalLease: LocalAIFileLockLease, modelLease: LocalAIFileLockLease) {
        self.globalLease = globalLease
        self.modelLease = modelLease
    }

    func release() {
        mutex.lock()
        let modelLease = self.modelLease
        let globalLease = self.globalLease
        self.modelLease = nil
        self.globalLease = nil
        mutex.unlock()

        modelLease?.release()
        globalLease?.release()
    }

    deinit {
        release()
    }
}

private enum LocalAIFileLock {
    enum Mode {
        case shared
        case exclusive

        var operation: Int32 {
            switch self {
            case .shared: LOCK_SH
            case .exclusive: LOCK_EX
            }
        }
    }

    /// 非阻塞轮询让 Task cancellation 有机会生效；阻塞 flock 会占住 cooperative thread。
    static func acquire(at url: URL, mode: Mode) async throws -> LocalAIFileLockLease {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
        }

        do {
            while starcatFlock(descriptor, mode.operation | LOCK_NB) != 0 {
                let code = Darwin.errno
                guard code == EWOULDBLOCK || code == EAGAIN else {
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            return LocalAIFileLockLease(descriptor: descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }
}

/// 共享模型目录的唯一写协调入口。
///
/// actor 只串行化本进程的状态；真正覆盖 App Store / Direct 两个进程的是 flock。
actor LocalAISharedModelCoordinator {
    static let shared = LocalAISharedModelCoordinator()

    /// 根目录会被测试覆盖，因此按实际 path 记准备状态，不能只用一个 Bool。
    private var preparedRootPath: String?

    /// 创建共享目录并迁移当前渠道的旧模型。重复调用只做一次。
    @discardableResult
    func prepareSharedStorageIfNeeded() async throws -> LocalAIModelMigrationReport {
        let fileManager = FileManager()
        let modelsRoot = try LocalAIModelStorage.modelsRootURL(fileManager: fileManager)
        if preparedRootPath == modelsRoot.path {
            return LocalAIModelMigrationReport()
        }

        let locksRoot = try LocalAIModelStorage.locksRootURL(fileManager: fileManager)
        try fileManager.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: locksRoot, withIntermediateDirectories: true)
        let globalLease = try await LocalAIFileLock.acquire(
            at: locksRoot.appendingPathComponent("store.lock"),
            mode: .exclusive)
        defer { globalLease.release() }

        // actor 在等待 flock 时可重入；第二个调用取得锁后必须重新检查。
        if preparedRootPath == modelsRoot.path {
            return LocalAIModelMigrationReport()
        }

        let legacyRoot = try LocalAIModelStorage.legacyModelsRootURL(fileManager: fileManager)
        let report = try migrateLegacyModels(
            from: legacyRoot,
            to: modelsRoot,
            fileManager: fileManager)
        preparedRootPath = modelsRoot.path

        if !report.migrated.isEmpty || !report.deduplicated.isEmpty || !report.preserved.isEmpty {
            AppLog.ai.info(
                "Local AI shared storage prepared: migrated=\(report.migrated.count, privacy: .public) deduplicated=\(report.deduplicated.count, privacy: .public) preserved=\(report.preserved.count, privacy: .public)")
        }
        return report
    }

    /// 模型容器加载前取得共享读租约；租约必须持有到 MLX 容器真正释放。
    func acquireModelRead(at modelDirectory: URL) async throws -> LocalAIModelAccessLease {
        try await prepareSharedStorageIfNeeded()
        return try await acquireModelLease(at: modelDirectory, mode: .shared)
    }

    /// 下载和单模型删除使用独占模型租约，不阻塞其它模型的推理。
    func acquireModelWrite(at modelDirectory: URL) async throws -> LocalAIModelAccessLease {
        try await prepareSharedStorageIfNeeded()
        return try await acquireModelLease(at: modelDirectory, mode: .exclusive)
    }

    /// 删除单模型。调用方必须先让本进程对应 MLX 容器卸载。
    func removeModel(at modelDirectory: URL) async throws {
        let lease = try await acquireModelWrite(at: modelDirectory)
        defer { lease.release() }
        if FileManager.default.fileExists(atPath: modelDirectory.path) {
            try FileManager.default.removeItem(at: modelDirectory)
        }
    }

    /// 删除所有共享模型。全局独占锁会等待另一渠道的推理 / 下载安全结束。
    func removeAllModels() async throws {
        try await prepareSharedStorageIfNeeded()
        let fileManager = FileManager()
        let modelsRoot = try LocalAIModelStorage.modelsRootURL(fileManager: fileManager)
        let globalLease = try await acquireGlobal(mode: .exclusive, fileManager: fileManager)
        defer { globalLease.release() }
        if fileManager.fileExists(atPath: modelsRoot.path) {
            try fileManager.removeItem(at: modelsRoot)
        }
        try fileManager.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    }

    /// 切换下载源时清理 `.part`。全局独占锁避免与另一个进程的下载混流。
    func cleanPartialFiles() async throws {
        try await prepareSharedStorageIfNeeded()
        let fileManager = FileManager()
        let globalLease = try await acquireGlobal(mode: .exclusive, fileManager: fileManager)
        defer { globalLease.release() }
        LocalAIModelStorage.cleanPartialFiles(fileManager: fileManager)
    }

    private func acquireModelLease(
        at modelDirectory: URL,
        mode: LocalAIFileLock.Mode
    ) async throws -> LocalAIModelAccessLease {
        let fileManager = FileManager()
        let globalLease = try await acquireGlobal(mode: .shared, fileManager: fileManager)
        do {
            let locksRoot = try LocalAIModelStorage.locksRootURL(fileManager: fileManager)
            let digest = SHA256.hash(
                data: Data(modelDirectory.standardizedFileURL.path.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            let modelLease = try await LocalAIFileLock.acquire(
                at: locksRoot.appendingPathComponent("model-\(digest).lock"),
                mode: mode)
            return LocalAIModelAccessLease(
                globalLease: globalLease,
                modelLease: modelLease)
        } catch {
            globalLease.release()
            throw error
        }
    }

    private func acquireGlobal(
        mode: LocalAIFileLock.Mode,
        fileManager: FileManager
    ) async throws -> LocalAIFileLockLease {
        let locksRoot = try LocalAIModelStorage.locksRootURL(fileManager: fileManager)
        return try await LocalAIFileLock.acquire(
            at: locksRoot.appendingPathComponent("store.lock"),
            mode: mode)
    }

    /// 只迁移“可证明完整”的目录。任何不确定情况都保留旧副本，避免以节省磁盘为由
    /// 破坏用户已经下载的数 GB 权重。
    private func migrateLegacyModels(
        from legacyRoot: URL,
        to sharedRoot: URL,
        fileManager: FileManager
    ) throws -> LocalAIModelMigrationReport {
        guard legacyRoot.standardizedFileURL != sharedRoot.standardizedFileURL,
            fileManager.fileExists(atPath: legacyRoot.path)
        else { return LocalAIModelMigrationReport() }

        var report = LocalAIModelMigrationReport()
        for sourceDirectory in LocalAIModelStorage.modelDirectories(
            at: legacyRoot,
            fileManager: fileManager)
        {
            let name = sourceDirectory.lastPathComponent
            guard let manifest = try? LocalAIModelStorage.loadManifest(
                from: sourceDirectory,
                fileManager: fileManager),
                let entry = LocalAIModelCatalog.entry(id: manifest.id),
                entry.type == manifest.type,
                LocalAIModelStorage.isInstallationValid(
                    manifest: manifest,
                    directory: sourceDirectory,
                    verifyHashes: true,
                    fileManager: fileManager)
            else {
                report.preserved.append(name)
                continue
            }

            let destination = LocalAIModelStorage.modelDirectory(
                entry: entry,
                revision: manifest.revision,
                modelsRoot: sharedRoot)
            if fileManager.fileExists(atPath: destination.path) {
                guard let destinationManifest = try? LocalAIModelStorage.loadManifest(
                    from: destination,
                    fileManager: fileManager),
                    LocalAIModelStorage.hasSameContent(manifest, destinationManifest),
                    LocalAIModelStorage.isInstallationValid(
                        manifest: destinationManifest,
                        directory: destination,
                        verifyHashes: true,
                        fileManager: fileManager)
                else {
                    report.preserved.append(name)
                    continue
                }
                try fileManager.removeItem(at: sourceDirectory)
                report.deduplicated.append(name)
                continue
            }

            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            do {
                // 同一磁盘上优先原子 rename，避免再复制数 GB 权重。
                try fileManager.moveItem(at: sourceDirectory, to: destination)
                report.migrated.append(name)
            } catch {
                // 跨卷或系统拒绝 rename 时才走 staging copy；源目录在最终校验前不删。
                guard !fileManager.fileExists(atPath: destination.path) else {
                    report.preserved.append(name)
                    continue
                }
                let staging = destination.deletingLastPathComponent()
                    .appendingPathComponent(".migration-\(UUID().uuidString)", isDirectory: true)
                defer { try? fileManager.removeItem(at: staging) }
                do {
                    try fileManager.copyItem(at: sourceDirectory, to: staging)
                    guard let stagedManifest = try LocalAIModelStorage.loadManifest(
                        from: staging,
                        fileManager: fileManager),
                        LocalAIModelStorage.hasSameContent(manifest, stagedManifest),
                        LocalAIModelStorage.isInstallationValid(
                            manifest: stagedManifest,
                            directory: staging,
                            verifyHashes: true,
                            fileManager: fileManager)
                    else {
                        report.preserved.append(name)
                        continue
                    }
                    try fileManager.moveItem(at: staging, to: destination)
                    try fileManager.removeItem(at: sourceDirectory)
                    report.migrated.append(name)
                } catch {
                    report.preserved.append(name)
                }
            }
        }

        removeEmptyLegacyDirectories(at: legacyRoot, fileManager: fileManager)
        return report
    }

    private func removeEmptyLegacyDirectories(at root: URL, fileManager: FileManager) {
        for type in LocalAIModelType.allCases {
            let directory = LocalAIModelStorage.typeDirectory(for: type, modelsRoot: root)
            if (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try? fileManager.removeItem(at: directory)
            }
        }
        if (try? fileManager.contentsOfDirectory(atPath: root.path).isEmpty) == true {
            try? fileManager.removeItem(at: root)
        }
    }
}
