//
//  LayaDecisionModelManager.swift
//  Starcat
//
//  Labs 设置页观察的 Laya 模型安装状态机。
//
//  它复用通用 Local AI 下载器与跨进程锁，但不写入 AIProviderProfile。下载完成后
//  必须先落 manifest、释放独占写锁，再取得读锁预热 MLX runtime，避免同进程自锁。
//  `.part` 文件在暂停后保留，下次继续 Range 下载。
//

import Foundation
import Observation

@MainActor
@Observable
final class LayaDecisionModelManager {
    static let shared = LayaDecisionModelManager()

    private(set) var installState: LocalAIInstallState = .idle
    private(set) var installedManifest: LayaDecisionInstalledModel?
    private(set) var installedDirectoryURL: URL?

    private let downloader: LocalAIModelDownloader
    private let runtimeStore: LayaDecisionRuntimeStore
    private var runningInstall: Task<Void, Never>?
    private var generation = 0

    init(
        downloader: LocalAIModelDownloader = LocalAIModelDownloader(),
        runtimeStore: LayaDecisionRuntimeStore = .shared
    ) {
        self.downloader = downloader
        self.runtimeStore = runtimeStore
        refreshInstalledModel()
        if !TestEnvironment.isRunning {
            refreshFromSharedStorage()
        }
    }

    var diskUsage: Int64 {
        LayaDecisionModelStorage.totalDiskUsage()
    }

    func refreshFromSharedStorage() {
        guard !TestEnvironment.isRunning else { return }
        Task {
            do {
                try await LocalAISharedModelCoordinator.shared.prepareSharedStorageIfNeeded()
                refreshInstalledModel()
            } catch {
                AppLog.ai.error(
                    "Prepare shared Laya storage failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func install() {
        guard !TestEnvironment.isRunning, runningInstall == nil else { return }
        guard installedDirectoryURL == nil else { return }

        generation += 1
        let currentGeneration = generation
        installState = .preparing
        runningInstall = Task {
            await runInstall(generation: currentGeneration)
        }
    }

    /// 暂停只取消本次任务并保留 `.part`；代数使飞行中的进度回调立即失效。
    func pause() {
        generation += 1
        runningInstall?.cancel()
        runningInstall = nil
        Task { await downloader.cancel() }
        switch installState {
        case .preparing, .downloading:
            installState = .idle
        default:
            break
        }
    }

    func retryLoad() {
        guard case .loadFailed = installState,
              let directory = installedDirectoryURL,
              runningInstall == nil
        else { return }
        generation += 1
        let currentGeneration = generation
        installState = .loading
        runningInstall = Task {
            await preload(directory: directory, generation: currentGeneration)
        }
    }

    /// 状态面板只请求内存加载，不改变磁盘安装清单，也不触发重新下载。
    func loadIntoMemory() async throws {
        guard let directory = installedDirectoryURL else {
            throw LocalAIError.modelNotInstalled(
                LayaDecisionModelCatalog.multilingual.displayName
            )
        }
        installState = .loading
        do {
            try await runtimeStore.preload(from: directory)
            installState = .installed
        } catch {
            installState = .loadFailed(message: error.localizedDescription)
            throw error
        }
    }

    /// 只释放当前进程中的 runtime；模型文件仍保留，稍后可从状态面板重新加载。
    func unloadFromMemory(reason: String = "manual") async throws {
        try await runtimeStore.unload(reason: reason)
        if installedDirectoryURL != nil { installState = .installed }
    }

    func delete() {
        pause()
        guard let directory = installedDirectoryURL else { return }
        installState = .deleting
        generation += 1
        let currentGeneration = generation
        runningInstall = Task {
            do {
                try await runtimeStore.unload(reason: "model_deleted")
                try await LocalAISharedModelCoordinator.shared.removeModel(at: directory)
                guard generation == currentGeneration else { return }
                refreshInstalledModel()
                installState = .idle
            } catch {
                guard generation == currentGeneration else { return }
                installState = .deleteFailed(message: error.localizedDescription)
            }
            runningInstall = nil
        }
    }

    private func runInstall(generation currentGeneration: Int) async {
        let descriptor = LayaDecisionModelCatalog.multilingual
        var writeLease: LocalAIModelAccessLease?
        defer { writeLease?.release() }
        do {
            try await LocalAISharedModelCoordinator.shared.prepareSharedStorageIfNeeded()
            let revision = try await resolveRevision(for: descriptor.source)
            let directory = try LayaDecisionModelStorage.modelDirectory(revision: revision)
            writeLease = try await LocalAISharedModelCoordinator.shared.acquireModelWrite(
                at: directory
            )

            let existingManifest = try? LayaDecisionModelStorage.loadManifest(from: directory)
            let alreadyInstalled = existingManifest.map {
                LayaDecisionModelStorage.isInstallationValid(
                    manifest: $0,
                    directory: directory,
                    verifyHashes: false
                )
            } ?? false

            if !alreadyInstalled {
                if FileManager.default.fileExists(
                    atPath: LayaDecisionModelStorage.manifestURL(in: directory).path
                ) {
                    // 有 manifest 却不完整代表已完成安装被破坏，不能把旧文件与新下载混用。
                    try FileManager.default.removeItem(at: directory)
                }

                let fileSizes = await resolveFileSizes(
                    descriptor: descriptor,
                    revision: revision
                )
                let knownTotal = descriptor.files.compactMap { fileSizes[$0.name] }.reduce(0, +)
                let hasCompleteSizePlan = descriptor.files.allSatisfy { fileSizes[$0.name] != nil }
                let totalBytes = hasCompleteSizePlan && knownTotal > 0
                    ? knownTotal
                    : descriptor.estimatedDownloadSize
                var completedBefore: Int64 = 0
                var records: [LocalAIFileRecord] = []

                for file in descriptor.files {
                    try Task.checkCancellation()
                    let completedSnapshot = completedBefore
                    let remoteURL = try remoteURL(
                        source: descriptor.source,
                        revision: revision,
                        fileName: file.name
                    )
                    let result = try await downloader.downloadFile(
                        remoteURL: remoteURL,
                        fileName: file.name,
                        sourceKind: descriptor.source.kind,
                        into: directory,
                        expectedTotalBytes: descriptor.estimatedDownloadSize,
                        onProgress: { [weak self] progress in
                            Task { @MainActor [weak self] in
                                guard let self, self.generation == currentGeneration else { return }
                                let completed = completedSnapshot + progress.completedBytes
                                let ratio = totalBytes > 0
                                    ? Double(completed) / Double(totalBytes)
                                    : 0
                                self.installState = .downloading(
                                    progress: min(hasCompleteSizePlan ? 1 : 0.99, ratio),
                                    completedBytes: completed,
                                    totalBytes: totalBytes,
                                    speedBytesPerSecond: nil
                                )
                            }
                        }
                    )
                    guard generation == currentGeneration else { return }
                    records.append(LocalAIFileRecord(
                        name: result.name,
                        sha256: result.sha256,
                        sizeBytes: result.sizeBytes
                    ))
                    completedBefore += result.sizeBytes
                }

                let manifest = LayaDecisionInstalledModel(
                    id: descriptor.id,
                    displayName: descriptor.displayName,
                    revision: revision,
                    installedAt: Date(),
                    sourceKind: descriptor.source.kind,
                    files: records,
                    totalBytes: records.reduce(0) { $0 + $1.sizeBytes }
                )
                try LayaDecisionModelStorage.save(manifest, in: directory)
            }

            // Runtime preload 会获取共享读锁，必须先释放当前独占写锁。
            writeLease?.release()
            writeLease = nil
            refreshInstalledModel()
            guard let installedDirectoryURL else {
                throw LayaMLXDecisionError.incompleteCheckpoint(directory.path)
            }
            installState = .loading
            do {
                try await runtimeStore.preload(from: installedDirectoryURL)
                guard generation == currentGeneration else { return }
                installState = .installed
            } catch {
                guard generation == currentGeneration else { return }
                // 权重已经完整安装，加载失败必须允许“仅重试加载”，不能诱导用户重下。
                installState = .loadFailed(message: error.localizedDescription)
            }
        } catch is CancellationError {
            guard generation == currentGeneration else { return }
            installState = .idle
        } catch let error as LocalAIDownloadError where error == .cancelled {
            guard generation == currentGeneration else { return }
            installState = .idle
        } catch {
            guard generation == currentGeneration else { return }
            installState = .failed(message: error.localizedDescription)
        }
        runningInstall = nil
    }

    private func preload(directory: URL, generation currentGeneration: Int) async {
        do {
            try await runtimeStore.preload(from: directory)
            guard generation == currentGeneration else { return }
            installState = .installed
        } catch {
            guard generation == currentGeneration else { return }
            installState = .loadFailed(message: error.localizedDescription)
        }
        runningInstall = nil
    }

    private func refreshInstalledModel() {
        let installed = LayaDecisionModelStorage.installedModel()
        installedManifest = installed?.manifest
        installedDirectoryURL = installed?.directory
        if installed != nil {
            switch installState {
            case .loading, .loadFailed, .deleting, .deleteFailed:
                break
            default:
                installState = .installed
            }
        } else if installState.isInstalled {
            installState = .idle
        }
    }

    private func resolveRevision(for source: LocalAIModelSource) async throws -> String {
        if let revision = source.revision { return revision }
        guard source.kind == .huggingFace,
              let url = URL(string: "https://huggingface.co/api/models/\(source.repo)")
        else {
            throw LocalAIDownloadError.invalidURL(source.repo)
        }
        var request = URLRequest(url: url)
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LocalAIDownloadError.invalidURL(source.repo)
        }
        struct HFModelInfo: Decodable { let sha: String }
        return try JSONDecoder().decode(HFModelInfo.self, from: data).sha
    }

    private func resolveFileSizes(
        descriptor: LayaDecisionModelDescriptor,
        revision: String
    ) async -> [String: Int64] {
        guard let url = URL(string:
            "https://huggingface.co/api/models/\(descriptor.source.repo)/tree/\(revision)?recursive=true"
        ) else { return [:] }
        var request = URLRequest(url: url)
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [:] }
            struct TreeEntry: Decodable {
                let path: String
                let size: Int64?
                let lfs: LFSInfo?
                struct LFSInfo: Decodable { let size: Int64? }
            }
            let wanted = Set(descriptor.files.map(\.name))
            return try JSONDecoder().decode([TreeEntry].self, from: data).reduce(into: [:]) {
                result, item in
                guard wanted.contains(item.path),
                      let size = item.lfs?.size ?? item.size,
                      size > 0
                else { return }
                result[item.path] = size
            }
        } catch {
            AppLog.ai.debug(
                "Laya file size lookup failed (fallback to estimate): \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }

    private func remoteURL(
        source: LocalAIModelSource,
        revision: String,
        fileName: String
    ) throws -> URL {
        guard source.kind == .huggingFace,
              let url = URL(string:
                "https://huggingface.co/\(source.repo)/resolve/\(revision)/\(fileName)"
              )
        else {
            throw LocalAIDownloadError.invalidURL(fileName)
        }
        return url
    }
}
