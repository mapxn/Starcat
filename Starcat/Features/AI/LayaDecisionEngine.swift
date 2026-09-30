//
//  LayaDecisionEngine.swift
//  Starcat
//
//  Laya 本地 MLX 决策引擎与进程级 runtime 容器。
//
//  Runtime 持有共享模型读租约直到显式卸载，保证 App Store / Direct 两个进程中
//  任一方推理时，另一方不能删除 mmap 中的权重。引擎只做中立请求到 Laya 文本
//  prompt 的映射，不包含仓库候选筛选或产品阈值。
//

import Foundation

actor LayaDecisionRuntimeStore {
    static let shared = LayaDecisionRuntimeStore()

    /// MLX actor 在 `await` 时仍会重入；这里复用 Local AI 的串行准入门，保证一次
    /// 加载/推理结束前，删除流程不能释放 mmap 权重对应的共享读锁。
    private let operationGate = LocalAIOperationGate()
    private var runtime: LayaMLXDecisionRuntime?
    private var loadedDirectory: URL?
    private var modelAccessLease: LocalAIModelAccessLease?

    func preload(from directory: URL) async throws {
        try await operationGate.acquire()
        do {
            try await preloadWhileAdmitted(from: directory)
            await operationGate.release()
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private func preloadWhileAdmitted(from directory: URL) async throws {
        let normalizedDirectory = directory.standardizedFileURL
        if runtime != nil, loadedDirectory == normalizedDirectory { return }

        unloadLoadedModel(reason: "model_switch")
        let lease = try await LocalAISharedModelCoordinator.shared.acquireModelRead(
            at: normalizedDirectory
        )
        do {
            let loaded = try await LayaMLXDecisionRuntime.load(from: normalizedDirectory)
            runtime = loaded
            loadedDirectory = normalizedDirectory
            modelAccessLease = lease
        } catch {
            lease.release()
            throw error
        }
    }

    func evaluate(
        state: String,
        questions: [String: String],
        modelDirectory: URL
    ) async throws -> [String: LayaNoulPrediction] {
        try await operationGate.acquire()
        do {
            try await preloadWhileAdmitted(from: modelDirectory)
            guard let runtime else { throw LayaMLXDecisionError.runtimeNotLoaded }
            let result = try await runtime.predictNoulBatch(
                state: state,
                questions: questions
            )
            await operationGate.release()
            return result
        } catch {
            await operationGate.release()
            throw error
        }
    }

    /// 等当前加载/推理完整退出后才释放读锁；调用方随后才可取得写锁删除目录。
    func unload(reason: String) async throws {
        try await operationGate.acquire()
        unloadLoadedModel(reason: reason)
        await operationGate.release()
    }

    private func unloadLoadedModel(reason: String) {
        guard runtime != nil || modelAccessLease != nil else { return }
        runtime = nil
        loadedDirectory = nil
        modelAccessLease?.release()
        modelAccessLease = nil
        AppLog.ai.debug("Laya runtime unloaded: \(reason, privacy: .public)")
    }
}

@MainActor
final class LayaDecisionEngine: DecisionEngineProviding {
    let id: DecisionEngineID = .laya

    private let modelManager: LayaDecisionModelManager
    private let runtimeStore: LayaDecisionRuntimeStore

    init(
        modelManager: LayaDecisionModelManager = .shared,
        runtimeStore: LayaDecisionRuntimeStore = .shared
    ) {
        self.modelManager = modelManager
        self.runtimeStore = runtimeStore
    }

    var availability: DecisionEngineAvailability {
        modelManager.installedDirectoryURL == nil
            ? .unavailable(reason: "Laya multilingual model is not installed")
            : .available
    }

    func evaluate(_ request: DecisionEvaluationRequest) async throws -> DecisionEvaluationResponse {
        guard let directory = modelManager.installedDirectoryURL else {
            throw DecisionEngineError.engineUnavailable(
                .laya,
                reason: "Laya multilingual model is not installed"
            )
        }
        let prompts = request.questions.mapValues(\.localPromptText)
        let predictions = try await runtimeStore.evaluate(
            state: request.state.localPromptText,
            questions: prompts,
            modelDirectory: directory
        )
        let answers = predictions.mapValues {
            DecisionNoulAnswer(probability: $0.trueProbability)
        }
        return DecisionEvaluationResponse(answers: answers)
    }
}
