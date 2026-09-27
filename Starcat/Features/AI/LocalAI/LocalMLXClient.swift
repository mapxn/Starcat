//
//  LocalMLXClient.swift
//  Starcat
//
//  本地 AI（MLX）的 AIClientProtocol 适配层。
//
//  定位：与 `OpenAIClient`（HTTP）、`RAGCLIModelClient`（外部 CLI）并列的第三个
//  Starcat AI 后端。业务层（摘要 / 标签 / 对话 / 向量化 / RAG）只认协议，不感知
//  本地推理的存在；`AIClient.swift` 头注释预留的「Apple 本地模型只需替换 adapter」
//  由本文件兑现。
//
//  关键约束：
//  - 无 Key、无 baseURL：`AIClientConfiguration` 仅用于 providerID / 归因 / 超时口径，
//    网络相关字段被忽略。
//  - 本类型可以在任意执行上下文使用（业务服务多为 @MainActor，但流式迭代不在），
//    因此模型目录解析走 `LocalAIModelStorage` 的磁盘查询（非隔离），不触碰
//    @MainActor 的 `LocalAIModelManager`。
//  - embedding 维度在运行时校验 catalog 声明，防止 mlx-swift-lm 的 pooling 回归
//    （issue #36 曾输出 16384 维）污染向量库。
//

import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon

struct LocalMLXClient: AIClientProtocol {

    private let runtime: LocalMLXRuntime
    private let configuration: AIClientConfiguration?
    private let usageRecorder: any AIUsageRecording
    /// 模型展示名（= catalog displayName）→ 安装目录。未安装抛 `LocalAIError.modelNotInstalled`。
    private let directoryForModelName: @Sendable (String) throws -> URL

    init(
        runtime: LocalMLXRuntime = .shared,
        directoryForModelName: @escaping @Sendable (String) throws -> URL,
        configuration: AIClientConfiguration? = nil,
        usageRecorder: any AIUsageRecording = AIUsageRecorder.shared
    ) {
        self.runtime = runtime
        self.directoryForModelName = directoryForModelName
        self.configuration = configuration
        self.usageRecorder = usageRecorder
    }

    /// 装配入口（`AIClientFactory` 调用）。
    ///
    /// 注意不在这里校验 chat 模型已安装：同一 profile 下可能是「embedding 本地 +
    /// chat 名字只是配置残留」的混合形态，强校验会把纯 embedding 路径误杀；
    /// 每次调用时的目录解析才是精确校验点（未安装抛 `modelNotInstalled`）。
    public static func makeClient(configuration: AIClientConfiguration) -> LocalMLXClient {
        LocalMLXClient(directoryForModelName: directoryResolver, configuration: configuration)
    }

    /// 展示名 → 安装目录。任何线程可用（磁盘扫描即真源）。
    private static let directoryResolver: @Sendable (String) throws -> URL = { name in
        guard let entry = LocalAIModelCatalog.entries.first(where: { $0.displayName == name }),
            let directory = LocalAIModelStorage.installedDirectoryURL(entryID: entry.id)
        else {
            throw LocalAIError.modelNotInstalled(name)
        }
        return directory
    }

    // MARK: - AITextGenerating

    func chat(request: AIChatRequest) async throws -> AIChatResponse {
        let events = chatStream(request: request)
        var finalResponse: AIChatResponse?
        for try await event in events {
            if case .completed(let response) = event {
                finalResponse = response
            }
        }
        guard let finalResponse else {
            throw AIClientError.emptyResponse
        }
        return finalResponse
    }

    func chatStream(request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await runChat(request: request, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 日志上下文在请求入口固定，并随超时任务、运行时准入和 MLX 子任务传播。
    private func runChat(
        request: AIChatRequest, continuation: AsyncThrowingStream<AIChatStreamEvent, Error>.Continuation
    ) async {
        let directory: Result<URL, Error>
        do {
            try await prepareSharedStorageForAccess()
            directory = Result { try directoryForModelName(request.model) }
        } catch {
            directory = .failure(error)
        }
        let context = LocalAILogContext(
            modelName: request.model,
            feature: (request.usageContext ?? configuration?.usageContext)?.feature.rawValue ?? "chat",
            directory: try? directory.get())
        await LocalAILogContext.$current.withValue(context) {
            let startedAt = Date().timeIntervalSince1970
            var response: AIChatResponse?
            LocalAILog.record("request.received", "Generation request received.", fields: [
                "maxOutputTokens": String(request.parameters.maxCompletionTokens),
                "timeoutSeconds": String(request.parameters.timeoutSeconds),
                "temperature": String(request.parameters.temperature), "topP": String(request.parameters.topP)
            ])
            do {
                let directory = try directory.get()
                let completed = try await LocalAIGenerationPolicy.withTimeout(seconds: request.parameters.timeoutSeconds) {
                    try await runtime.withLLM(directory: directory) { container in
                        try await LocalMLXRuntime.generate(container: container, request: request) {
                            continuation.yield($0)
                        }
                    }
                }
                response = completed
                try Task.checkCancellation()
                try LocalAIGenerationPolicy.validateCompletion(completed)
                await recordGeneration(request: request, response: completed, startedAt: startedAt, error: nil)
                continuation.yield(.completed(completed))
                continuation.finish()
            } catch {
                await recordGeneration(request: request, response: response, startedAt: startedAt, error: error)
                continuation.finish(throwing: error)
            }
        }
    }

    // MARK: - AIClientProtocol

    func chat(systemPrompt: String, userPrompt: String, model: String?) async throws -> String {
        let modelName = model ?? configuration?.chatModel ?? ""
        let response = try await chat(request: AIChatRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: modelName,
            parameters: LocalAIGenerationPolicy.defaultParameters(model: modelName, capability: .chat)))
        return response.content
    }

    func embedding(input: String, model: String?) async throws -> [Float] {
        let vectors = try await embeddings(inputs: [input], model: model)
        guard let vector = vectors.first else {
            throw AIClientError.emptyResponse
        }
        return vector
    }

    func embeddings(inputs: [String], model: String?) async throws -> [[Float]] {
        let modelName = model ?? configuration?.embeddingModel ?? ""
        try await prepareSharedStorageForAccess()
        let resolved = Result { try directoryForModelName(modelName) }
        let context = LocalAILogContext(modelName: modelName, feature: "embedding", directory: try? resolved.get())
        return try await LocalAILogContext.$current.withValue(context) {
            let start = ProcessInfo.processInfo.systemUptime
            LocalAILog.record("request.received", "Embedding request received.", fields: ["items": String(inputs.count)])
            do {
                let vectors = try await generateEmbeddings(inputs: inputs, modelName: modelName, directory: resolved.get())
                LocalAILog.record("request.completed", "Embedding request completed.", fields: [
                    "items": String(vectors.count), "dimensions": String(vectors.first?.count ?? 0),
                    "durationSeconds": LocalAILogEvent.seconds(ProcessInfo.processInfo.systemUptime - start)
                ])
                return vectors
            } catch {
                LocalAILog.record("request.failed", "Embedding request ended without a result.",
                                  level: error is CancellationError ? .info : .error, fields: LocalAILogEvent.errorFields(error))
                throw error
            }
        }
    }

    private func generateEmbeddings(inputs: [String], modelName: String, directory: URL) async throws -> [[Float]] {
        let expectedDimension = LocalAIModelCatalog.entries
            .first { $0.displayName == modelName }?
            .embeddingDimension

        let vectors = try await runtime.withEmbedder(directory: directory) { container in
            // 长文档批次不能按上层数组长度无限扩张，pad 后的注意力张量会同时放大。
            var vectors: [[Float]] = []
            var lastProgress = ProcessInfo.processInfo.systemUptime
            for start in stride(from: 0, to: inputs.count, by: 4) {
                try Task.checkCancellation()
                let batch = Array(inputs[start..<min(start + 4, inputs.count)])
                vectors += try await Self.embed(container: container, inputs: batch)
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastProgress >= 1 {
                    lastProgress = now
                    LocalAILog.record("embedding.progress", "Embedding batch completed.", fields: [
                        "completedItems": String(vectors.count), "totalItems": String(inputs.count)
                    ])
                }
            }
            return vectors
        }

        if let expectedDimension, vectors.contains(where: { $0.count != expectedDimension }) {
            // pooling 回归的向量绝不能写进向量库。
            throw LocalAIError.embeddingDimensionMismatch(
                expected: expectedDimension, actual: vectors.first?.count ?? 0)
        }
        return vectors
    }

    func listModels() async throws -> [AIModelDescriptor] {
        try await prepareSharedStorageForAccess()
        let installedIDs = Set(
            ((try? LocalAIModelStorage.listInstalled()) ?? []).map(\.id))
        return LocalAIModelCatalog.entries.compactMap { entry in
            guard installedIDs.contains(entry.id) else { return nil }
            return AIModelDescriptor(
                providerID: LocalAIModelCatalog.builtInProfileID,
                name: entry.displayName,
                ownedBy: "Starcat Local AI",
                capability: entry.capability,
                isEnabled: true)
        }
    }

    func testConnection() async throws {
        try await prepareSharedStorageForAccess()
        // 本地「连接测试」= 完整性检查：manifest 声明的文件都真实存在。
        let installed = (try? LocalAIModelStorage.listInstalled()) ?? []
        for manifest in installed {
            guard let entry = LocalAIModelCatalog.entry(id: manifest.id) else { continue }
            guard let directory = LocalAIModelStorage.installedDirectoryURL(entryID: entry.id)
            else { continue }
            for file in manifest.files
            where !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(file.name).path) {
                throw LocalAIError.modelNotInstalled(entry.displayName)
            }
        }
    }

    /// 推理解析目录前等待一次性迁移完成，避免升级后的首个请求在旧目录尚未搬完时
    /// 短暂误报“模型未安装”。测试保留原有注入路径，不触碰真实 App Group。
    private func prepareSharedStorageForAccess() async throws {
        guard !TestEnvironment.isRunning else { return }
        try await LocalAISharedModelCoordinator.shared.prepareSharedStorageIfNeeded()
    }

    /// 只记录统计元数据；没有 usage 时保持 nil，不把字符数伪装成 token。
    /// 推理 token 的单独计数未由 SDK 提供，统计记录中保持未知。
    private func recordGeneration(
        request: AIChatRequest, response: AIChatResponse?, startedAt: Double, error: Error?
    ) async {
        let reason = error.map(LocalAIGenerationPolicy.finishReason(for:)) ?? response?.finishReason ?? "unknown"
        var fields = error.map(LocalAILogEvent.errorFields) ?? [:]
        fields["finishReason"] = reason
        fields["durationSeconds"] = LocalAILogEvent.seconds(Date().timeIntervalSince1970 - startedAt)
        fields["inputTokens"] = response?.usage.map { String($0.inputTokens) }
        fields["outputTokens"] = response?.usage.map { String($0.outputTokens) }
        LocalAILog.record("request.finished", "Generation request finished.",
                          level: error == nil || error is CancellationError ? .info : .error, fields: fields)
        guard let configuration else { return }
        let status: AIUsageStatus = error == nil ? .succeeded : (error is CancellationError ? .cancelled : .failed)
        await usageRecorder.record(AIUsageEventFactory.make(
            startedAt: startedAt, configuration: configuration, usageContext: request.usageContext,
            model: request.model, operation: .chat,
            inputTokens: response?.usage?.inputTokens, outputTokens: response?.usage?.outputTokens,
            totalTokens: response?.usage?.totalTokens, cachedInputTokens: response?.usage?.cachedTokens,
            reasoningOutputTokens: nil, itemCount: 1, status: status, error: error))
    }

    // MARK: - Embedding 推理

    /// 批量 embedding：右填充 + attention mask（Qwen3 是 last-token pooling，
    /// mask 决定取哪个 token，批次推理时必须传）。
    static func embed(
        container: EmbedderModelContainer, inputs: [String]
    ) async throws -> [[Float]] {
        guard !inputs.isEmpty else { return [] }
        return await container.perform { context in
            let tokenizer = context.tokenizer
            let tokenized = inputs.map { text -> [Int] in
                let encoded = tokenizer.encode(text: text, addSpecialTokens: true)
                // 单条超长截断：embedding 输入上限远小于 LLM 上下文，2K token 覆盖
                // 任何 README chunk（chunker 目标 700 token）。
                return Array(encoded.prefix(2_048))
            }
            let maxLength = tokenized.map(\.count).max() ?? 1

            var inputIDs: [Int32] = []
            var attentionMask: [Int32] = []
            inputIDs.reserveCapacity(inputs.count * maxLength)
            attentionMask.reserveCapacity(inputs.count * maxLength)
            for ids in tokenized {
                let padding = maxLength - ids.count
                inputIDs.append(contentsOf: ids.map(Int32.init))
                inputIDs.append(contentsOf: [Int32](repeating: 0, count: padding))
                attentionMask.append(contentsOf: [Int32](repeating: 1, count: ids.count))
                attentionMask.append(contentsOf: [Int32](repeating: 0, count: padding))
            }

            let inputArray = MLXArray(inputIDs).reshaped([inputs.count, maxLength])
            let maskArray = MLXArray(attentionMask).reshaped([inputs.count, maxLength])
            let output = context.model(
                inputArray, positionIds: nil, tokenTypeIds: nil, attentionMask: maskArray)
            let pooled = context.pooling(
                output, mask: maskArray, normalize: true, applyLayerNorm: true)
            pooled.eval()
            let rows = pooled.shape[0]
            return (0..<rows).map { row in
                Array(pooled[row].asArray(Float.self))
            }
        }
    }
}
