//
//  LocalAIModelDownloaderTests.swift
//  StarcatTests
//
//  下载器契约测试：整段下载 + SHA256、Range 断点续传、服务器忽略 Range 时重下、
//  HTTP 错误与体积不符错误。全部走 URLProtocolStub，无真实网络。
//

import Foundation
import Testing
import CryptoKit
@testable import Starcat

/// `ProgressHandler` 是跨 actor 的同步回调，测试用锁保护采样数组，避免把断言依赖于
/// 未结构化 Task 的调度时机。该类型仅用于测试，不参与生产下载链路。
private final class LocalAIProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LocalAIDownloadProgress] = []

    func append(_ progress: LocalAIDownloadProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }

    var values: [LocalAIDownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Suite("LocalAIModelDownloader")
struct LocalAIModelDownloaderTests {

    private func makeSession() -> URLSession { URLProtocolStub.ephemeralSession() }

    private func response(url: URL, statusCode: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    @Test("整段下载落盘并返回正确 SHA256")
    func fullDownload() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let payload = Data("hello local model weights".utf8)
        let expectedSHA = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        URLProtocolStub.requestHandler = { request in
            let headers = ["Content-Length": "\(payload.count)"]
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!, payload)
        }

        let downloader = LocalAIModelDownloader(session: makeSession())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localai-dl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await downloader.downloadFile(
            remoteURL: URL(string: "https://models.test.invalid/model.safetensors")!,
            fileName: "model.safetensors",
            sourceKind: .huggingFace,
            into: directory,
            expectedTotalBytes: Int64(payload.count),
            onProgress: nil)

        #expect(result.sha256 == expectedSHA)
        #expect(result.sizeBytes == Int64(payload.count))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.safetensors").path))
        // 下载完成后 .part 不应残留。
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.safetensors.huggingface.part").path))
    }

    @Test("保留 checkpoint 子目录并在 manifest 结果中返回完整相对路径")
    func downloadsNestedCheckpointFile() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let payload = Data(#"{"model_type":"modernbert"}"#.utf8)
        URLProtocolStub.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "\(payload.count)"]
                )!,
                payload
            )
        }

        let downloader = LocalAIModelDownloader(session: makeSession())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localai-dl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await downloader.downloadFile(
            remoteURL: URL(string: "https://models.test.invalid/encoder/config.json")!,
            fileName: "encoder/config.json",
            sourceKind: .huggingFace,
            into: directory,
            expectedTotalBytes: Int64(payload.count),
            onProgress: nil
        )

        #expect(result.name == "encoder/config.json")
        #expect(try Data(contentsOf: directory.appendingPathComponent(result.name)) == payload)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                "encoder/config.json.huggingface.part"
            ).path
        ))
    }

    @Test("嵌套模型路径不能逃出目标目录")
    func rejectsNestedPathTraversal() async {
        let downloader = LocalAIModelDownloader(session: makeSession())
        await #expect(throws: LocalAIDownloadError.invalidURL("../outside.bin")) {
            _ = try await downloader.downloadFile(
                remoteURL: URL(string: "https://models.test.invalid/outside.bin")!,
                fileName: "../outside.bin",
                sourceKind: .huggingFace,
                into: FileManager.default.temporaryDirectory,
                expectedTotalBytes: nil,
                onProgress: nil
            )
        }
    }

    @Test("进度回调报告真实落盘字节")
    func reportsActualDownloadedBytes() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let payload = Data(repeating: 0xA5, count: (1 << 20) + 1_234)
        URLProtocolStub.requestHandler = { request in
            let headers = ["Content-Length": "\(payload.count)"]
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, payload)
        }

        let recorder = LocalAIProgressRecorder()
        let downloader = LocalAIModelDownloader(session: makeSession())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localai-dl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await downloader.downloadFile(
            remoteURL: URL(string: "https://models.test.invalid/model.safetensors")!,
            fileName: "model.safetensors",
            sourceKind: .modelScope,
            into: directory,
            expectedTotalBytes: Int64(payload.count),
            onProgress: { recorder.append($0) })

        let values = recorder.values
        #expect(values.first?.completedBytes == 0)
        #expect(values.contains { $0.completedBytes == 1 << 20 })
        #expect(values.last == LocalAIDownloadProgress(
            completedBytes: Int64(payload.count),
            totalBytes: Int64(payload.count)))
        #expect(zip(values, values.dropFirst()).allSatisfy {
            $0.completedBytes <= $1.completedBytes
        })
    }

    @Test("魔塔文件清单解析真实文件大小")
    func modelScopeFileListParsesActualSizes() throws {
        let data = Data(#"""
        {"Code":200,"Data":{"Files":[
          {"Path":"config.json","Size":886},
          {"Path":"model.safetensors","Size":1416035216},
          {"Path":"README.md","Size":112379}
        ]}}
        """#.utf8)

        let response = try JSONDecoder().decode(
            LocalAIModelScopeFileListResponse.self, from: data)
        let sizes = response.fileSizes(wanted: ["config.json", "model.safetensors"])

        #expect(sizes == [
            "config.json": 886,
            "model.safetensors": 1_416_035_216,
        ])
    }

    @Test("已有 .part 时走 206 续传并拼接哈希")
    func resumeWithRange() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let full = Data("0123456789abcdef".utf8)
        let prefixCount = 6
        let prefix = full.prefix(prefixCount)
        let rest = full.dropFirst(prefixCount)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localai-dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try prefix.write(to: directory.appendingPathComponent("model.safetensors.huggingface.part"))

        URLProtocolStub.requestHandler = { request in
            let range = request.value(forHTTPHeaderField: "Range")
            #expect(range == "bytes=\(prefixCount)-")
            let headers = [
                "Content-Range": "bytes \(prefixCount)-\(full.count - 1)/\(full.count)",
                "Content-Length": "\(rest.count)",
            ]
            return (
                HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!,
                Data(rest)
            )
        }

        let downloader = LocalAIModelDownloader(session: makeSession())
        let result = try await downloader.downloadFile(
            remoteURL: URL(string: "https://models.test.invalid/model.safetensors")!,
            fileName: "model.safetensors",
            sourceKind: .huggingFace,
            into: directory,
            expectedTotalBytes: Int64(full.count),
            onProgress: nil)

        let expectedSHA = SHA256.hash(data: full).map { String(format: "%02x", $0) }.joined()
        #expect(result.sha256 == expectedSHA)
        #expect(result.sizeBytes == Int64(full.count))
        let onDisk = try Data(contentsOf: directory.appendingPathComponent("model.safetensors"))
        #expect(onDisk == full)
    }

    @Test("服务器忽略 Range（200）时从头重下")
    func serverIgnoresRange() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let payload = Data("fresh-complete-payload".utf8)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localai-dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("stale".utf8).write(to: directory.appendingPathComponent("model.safetensors.huggingface.part"))

        URLProtocolStub.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Range") != nil)
            let headers = ["Content-Length": "\(payload.count)"]
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!, payload)
        }

        let downloader = LocalAIModelDownloader(session: makeSession())
        let result = try await downloader.downloadFile(
            remoteURL: URL(string: "https://models.test.invalid/model.safetensors")!,
            fileName: "model.safetensors",
            sourceKind: .huggingFace,
            into: directory,
            expectedTotalBytes: Int64(payload.count),
            onProgress: nil)

        #expect(result.sizeBytes == Int64(payload.count))
        let onDisk = try Data(contentsOf: directory.appendingPathComponent("model.safetensors"))
        #expect(onDisk == payload)
    }

    @Test("HTTP 404 抛出状态码错误")
    func httpErrorSurfaces() async {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        URLProtocolStub.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!, Data())
        }

        let downloader = LocalAIModelDownloader(session: makeSession())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localai-dl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await downloader.downloadFile(
                remoteURL: URL(string: "https://models.test.invalid/missing.safetensors")!,
                fileName: "missing.safetensors",
                sourceKind: .huggingFace,
                into: directory,
                expectedTotalBytes: nil,
                onProgress: nil)
            Issue.record("404 应抛错")
        } catch let error as LocalAIDownloadError {
            #expect(error == .httpStatus(404))
        } catch {
            Issue.record("意外错误类型: \(error)")
        }
    }

    @Test("体积与 Content-Length 不符时抛 sizeMismatch")
    func sizeMismatchThrows() async {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let payload = Data("short".utf8)
        URLProtocolStub.requestHandler = { request in
            let headers = ["Content-Length": "1000"]
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!, payload)
        }

        let downloader = LocalAIModelDownloader(session: makeSession())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localai-dl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await downloader.downloadFile(
                remoteURL: URL(string: "https://models.test.invalid/model.safetensors")!,
                fileName: "model.safetensors",
                sourceKind: .huggingFace,
                into: directory,
                expectedTotalBytes: nil,
                onProgress: nil)
            Issue.record("体积不符应抛错")
        } catch let error as LocalAIDownloadError {
            #expect(error == .sizeMismatch(expected: 1000, actual: Int64(payload.count)))
        } catch {
            Issue.record("意外错误类型: \(error)")
        }
    }
}
