//
//  LocalAIModelDownloader.swift
//  Starcat
//
//  本地 AI 模型文件下载器（actor）。
//
//  与 `ReleaseAssetDownloader` 的关系：复用「临时文件 + 完成后 move」的思路，但补齐
//  大模型下载必需而全仓此前缺失的三个能力：
//  1. HTTP Range 断点续传 —— `.part` 临时文件记录已写字节，重试 / 重启后续传；
//  2. 流式 SHA256 —— 下载过程中同步计算，完成后与 manifest 对账；
//  3. 磁盘空间预检 —— `volumeAvailableCapacityForImportantUsage` 不足时直接失败。
//
//  为什么不用 `URLSession.downloadTask`：它拿不到已写字节的落盘控制权，无法实现跨进程
//  的 Range 续传（resumeData 不能跨版本 / 重启可靠复用）。这里用 `session.bytes(for:)`
//  + 1MB 合并缓冲：AsyncBytes 内部带缓冲读取，逐字节消费但不是逐字节 syscall，实测对
//  GB 级文件吞吐可接受；缓冲层保证磁盘写入与哈希计算都按 1MB 块进行。
//

import Foundation
import CryptoKit

/// 下载器错误。`errorDescription` 由 LocalAIModelManager 映射为设置页可见文案。
enum LocalAIDownloadError: LocalizedError, Equatable {
    case invalidURL(String)
    case httpStatus(Int)
    case diskSpaceInsufficient(required: Int64, available: Int64)
    case serverDoesNotSupportRange
    case cancelled
    case sizeMismatch(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let name):
            return String(format: String.l10n("settings.localai.error.invalidURLFormat"), name)
        case .httpStatus(let code):
            return String(
                format: String.l10n("settings.localai.error.httpStatusFormat"), code)
        case .diskSpaceInsufficient(let required, let available):
            return String(
                format: String.l10n("settings.localai.error.diskSpaceInsufficientFormat"),
                ByteCountFormatter.string(fromByteCount: required, countStyle: .file),
                ByteCountFormatter.string(fromByteCount: available, countStyle: .file))
        case .serverDoesNotSupportRange:
            return String.l10n("settings.localai.error.serverDoesNotSupportRange")
        case .cancelled:
            return String.l10n("settings.localai.error.cancelled")
        case .sizeMismatch(let expected, let actual):
            return String(
                format: String.l10n("settings.localai.error.sizeMismatchFormat"), expected, actual)
        }
    }
}

/// 单文件下载结果。
struct LocalAIDownloadResult: Sendable, Equatable {
    var name: String
    var sha256: String
    var sizeBytes: Int64
}

/// 单文件下载进度快照。
///
/// 必须携带真实落盘字节，而不是只回传比例：模型由多个体积悬殊的文件组成，调用方若
/// 再用 catalog 预估体积反推字节，会把 KB 级配置文件错误计成数百 MB。
struct LocalAIDownloadProgress: Sendable, Equatable {
    let completedBytes: Int64
    /// 服务端未返回 Content-Length / Content-Range 时为 nil，已完成字节仍可用于速度采样。
    let totalBytes: Int64?
}

/// 模型文件下载器。串行 actor：同一时刻只允许一个下载任务在跑（顺序下载三件套）。
actor LocalAIModelDownloader {

    /// 单文件真实字节进度。闭包 @Sendable，UI 侧自行 hop MainActor。
    typealias ProgressHandler = @Sendable (LocalAIDownloadProgress) -> Void

    private let session: URLSession
    private var runningTask: Task<LocalAIDownloadResult, Error>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public

    /// 取消当前下载（若有）。
    func cancel() {
        runningTask?.cancel()
        runningTask = nil
    }

    /// 下载单个模型文件到 `destinationDirectory`，返回校验记录。
    ///
    /// - Parameters:
    ///   - remotePath: 形如 `<repo>/resolve/<revision>/<file>` 的服务端相对/绝对路径。
    ///   - fileName: 相对目标目录的落盘路径，可包含受控子目录。
    ///   - expectedTotalBytes: catalog 预估体积（仅用于磁盘预检，不作为硬校验）。
    func downloadFile(
        remoteURL: URL,
        fileName: String,
        sourceKind: LocalAIModelSource.Kind,
        into destinationDirectory: URL,
        expectedTotalBytes: Int64?,
        onProgress: ProgressHandler?
    ) async throws -> LocalAIDownloadResult {
        let pathComponents = fileName.split(separator: "/", omittingEmptySubsequences: false)
        guard !fileName.isEmpty,
              !fileName.hasPrefix("/"),
              pathComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            // catalog 最终可能来自远端元数据；允许子目录不等于允许逃出模型目录。
            throw LocalAIDownloadError.invalidURL(fileName)
        }
        // .part 按下载源隔离：不同源的权重内容不保证逐字节一致（镜像/版本差异），
        // 跨源复用断点会把两份数据混写成一个文件。
        let partURL = destinationDirectory.appendingPathComponent(
            "\(fileName).\(sourceKind.rawValue).part")
        let finalURL = destinationDirectory.appendingPathComponent(fileName)

        // 目录准备 + 已完成文件短路（重试场景：前面的文件已下好）。
        try FileManager.default.createDirectory(
            at: destinationDirectory, withIntermediateDirectories: true)
        // Laya 等 checkpoint 会保留上游子目录（如 encoder/config.json）。下载器必须
        // 为最终文件和同目录 `.part` 一并建父目录，不能要求 catalog 把层级拍平；
        // 拍平会破坏 tokenizer / encoder 按相对路径加载的协议。
        try FileManager.default.createDirectory(
            at: finalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: partURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: finalURL.path) {
            let size = (try? FileManager.default.attributesOfItem(
                atPath: finalURL.path)[.size] as? Int64) ?? 0
            let sha = try LocalAIModelStorage.sha256(ofFileAt: finalURL)
            // 重试时已完成文件也要报告真实字节，否则下一文件开始前整体进度会缺一段。
            onProgress?(LocalAIDownloadProgress(completedBytes: size, totalBytes: size))
            return LocalAIDownloadResult(name: fileName, sha256: sha, sizeBytes: size)
        }

        // 磁盘预检：剩余空间需覆盖预估体积 + 20% 余量。
        try checkDiskSpace(expectedBytes: expectedTotalBytes ?? 0)

        let task = Task { [session] in
            try await Self.streamDownload(
                session: session,
                remoteURL: remoteURL,
                partURL: partURL,
                finalURL: finalURL,
                onProgress: onProgress)
        }
        runningTask = task
        defer { runningTask = nil }

        do {
            var result = try await task.value
            // stream 层只看到最终 URL，`lastPathComponent` 会丢掉 encoder/ 等相对层级；
            // manifest 必须保留调用方传入的完整相对路径才能做完整性校验。
            result.name = fileName
            return result
        } catch is CancellationError {
            throw LocalAIDownloadError.cancelled
        }
    }

    // MARK: - 磁盘空间

    private func checkDiskSpace(expectedBytes: Int64) throws {
        guard expectedBytes > 0 else { return }
        let required = expectedBytes + expectedBytes / 5
        do {
            let values = try URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let available = values.volumeAvailableCapacityForImportantUsage ?? 0
            if available < required {
                throw LocalAIDownloadError.diskSpaceInsufficient(
                    required: required, available: available)
            }
        } catch let error as LocalAIDownloadError {
            throw error
        } catch {
            // 卷容量查询失败不阻断下载（部分容器卷不支持该 key），交给写入阶段自然失败。
            AppLog.network.debug(
                "LocalAI disk space check unavailable: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - 流式下载（含 Range 续传）

    private static func streamDownload(
        session: URLSession,
        remoteURL: URL,
        partURL: URL,
        finalURL: URL,
        onProgress: ProgressHandler?
    ) async throws -> LocalAIDownloadResult {
        let fileManager = FileManager.default
        var offset: Int64 = 0
        if let attrs = try? fileManager.attributesOfItem(atPath: partURL.path),
            let size = attrs[.size] as? Int64, size > 0 {
            offset = size
        }

        var request = URLRequest(url: remoteURL)
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalAIDownloadError.httpStatus(-1)
        }

        let resumed: Bool
        switch http.statusCode {
        case 206:
            resumed = true
        case 200:
            // 服务端忽略 Range：放弃续传，从头覆盖。
            resumed = false
            offset = 0
            try? fileManager.removeItem(at: partURL)
        default:
            throw LocalAIDownloadError.httpStatus(http.statusCode)
        }
        if offset > 0 && !resumed {
            offset = 0
        }

        // 服务端返回 206 但本地没有 .part（异常态）也按从头处理。
        if !fileManager.fileExists(atPath: partURL.path) {
            offset = 0
        }

        let handle: FileHandle
        if offset > 0 {
            handle = try FileHandle(forWritingTo: partURL)
            try handle.seek(toOffset: UInt64(offset))
        } else {
            if !fileManager.fileExists(atPath: partURL.path) {
                fileManager.createFile(atPath: partURL.path, contents: nil)
            }
            handle = try FileHandle(forWritingTo: partURL)
        }
        defer { try? handle.close() }

        // 总长度：206 且带 Content-Range 时，"/" 后的 total 就是完整文件大小（无需加
        // offset）；否则回退 Content-Length（200 时即完整长度；206 无 Content-Range 的
        // 罕见服务端再补 offset）。
        let totalBytes: Int64?
        if http.statusCode == 206,
            let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
            let totalString = contentRange.split(separator: "/").last,
            let total = Int64(totalString), total > 0 {
            totalBytes = total
        } else if http.expectedContentLength > 0 {
            totalBytes = Int64(http.expectedContentLength) + offset
        } else {
            totalBytes = nil
        }

        var hasher = SHA256()
        if offset > 0 {
            // 续传时先补算已写字节的哈希，保证最终摘要覆盖完整文件。
            let existing = try FileHandle(forReadingFrom: partURL)
            defer { try? existing.close() }
            while let chunk = try existing.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        }

        var written: Int64 = offset
        onProgress?(LocalAIDownloadProgress(
            completedBytes: written,
            totalBytes: totalBytes))
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                hasher.update(data: buffer)
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                onProgress?(LocalAIDownloadProgress(
                    completedBytes: written,
                    totalBytes: totalBytes))
            }
        }
        if !buffer.isEmpty {
            hasher.update(data: buffer)
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        onProgress?(LocalAIDownloadProgress(
            completedBytes: written,
            totalBytes: totalBytes))

        if let totalBytes, written != totalBytes {
            throw LocalAIDownloadError.sizeMismatch(expected: totalBytes, actual: written)
        }

        // 完成原子改名。
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.moveItem(at: partURL, to: finalURL)

        return LocalAIDownloadResult(
            name: finalURL.lastPathComponent,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            sizeBytes: written)
    }
}
