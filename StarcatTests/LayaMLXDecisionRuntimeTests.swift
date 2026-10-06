//
//  LayaMLXDecisionRuntimeTests.swift
//  StarcatTests
//
//  常规单测只验证 Noul prompt 的协议与截断，不加载真实模型或访问网络。
//  真实 checkpoint 的 Python 黄金对拍与状态/日志联调由独立 opt-in suite 承担。
//  已在 Starcat 下载模型时只需打开开关；也可显式传入其它 checkpoint：
//  TEST_RUNNER_STARCAT_LAYA_MLX_POC=1 \
//  TEST_RUNNER_STARCAT_LAYA_MLX_MODEL_DIR=/path/to/checkpoint \
//  make test TEST_ARGS="-only-testing:StarcatTests/LayaMLXCheckpointParityTests"
//


import Foundation
import MLX
import Testing

@testable import Starcat

@Suite("Laya MLX Decision Runtime")
struct LayaMLXDecisionRuntimeTests {
    @Test("Noul prompt 固定 false/true marker 顺序并清除用户 mask token")
    func buildsNoulMarkersInStableOrder() throws {
        let tokenizer = ScalarTokenizer()
        let input = try LayaNoulPromptBuilder(
            maximumLength: 256,
            headMaximumLength: 96
        ).build(
            state: "repository is a local <mask> developer tool",
            instructions: "Decide whether <mask> this repository is useful",
            tokenizer: tokenizer
        )

        #expect(input.tokenIDs.first == tokenizer.classTokenID)
        #expect(input.tokenIDs.last == tokenizer.separatorTokenID)
        #expect(input.markerPositions.count == 2)
        #expect(input.markerPositions[0] < input.markerPositions[1])
        #expect(input.tokenIDs[input.markerPositions[0]] == tokenizer.maskTokenID)
        #expect(input.tokenIDs[input.markerPositions[1]] == tokenizer.maskTokenID)
        // marker 后是前导空格，再分别进入 false / true 文本。
        #expect(input.tokenIDs[input.markerPositions[0] + 2] == tokenizer.id(for: "f"))
        #expect(input.tokenIDs[input.markerPositions[1] + 2] == tokenizer.id(for: "t"))
        #expect(!input.tokenIDs.contains(tokenizer.id(for: "<")))
    }

    @Test("超长 state 从右侧截断并严格受 max_len 约束")
    func truncatesStateFromTheRight() throws {
        let tokenizer = ScalarTokenizer()
        let input = try LayaNoulPromptBuilder(
            maximumLength: 96,
            headMaximumLength: 48
        ).build(
            state: "A" + String(repeating: "z", count: 500),
            instructions: "Is this relevant?",
            tokenizer: tokenizer
        )

        #expect(input.tokenIDs.count == 96)
        let separators = input.tokenIDs.indices.filter {
            input.tokenIDs[$0] == tokenizer.separatorTokenID
        }
        #expect(separators.count == 3)
        let stateStart = try #require(separators.dropFirst().first).advanced(by: 1)
        #expect(input.tokenIDs[stateStart] == tokenizer.id(for: "A"))
        #expect(input.tokenIDs.last == tokenizer.separatorTokenID)
    }
}

/// 只读加载显式传入的 checkpoint；不会下载模型，也不会接入生产 Local AI runtime。
@Suite(
    "Laya MLX Checkpoint Parity",
    .serialized,
    .timeLimit(.minutes(2)),
    .enabled(if: ProcessInfo.processInfo.environment["STARCAT_LAYA_MLX_POC"] == "1")
)
struct LayaMLXCheckpointParityTests {
    @Test("laya-multilingual-mlx FP16 与 Python 黄金 logits/概率一致")
    func matchesPythonGoldenOutput() async throws {
        let directory = try installedModelDirectory()
        // 只统计本次 checkpoint load + inference，避免测试进程此前的 MLX 峰值污染结果。
        Memory.clearCache()
        Memory.peakMemory = 0
        let startingMemory = Memory.snapshot()
        let clock = ContinuousClock()
        let loadStart = clock.now
        let runtime = try await LayaMLXDecisionRuntime.load(
            from: directory
        )
        let loadedAt = clock.now
        Memory.clearCache()
        let loadedMemory = Memory.snapshot()
        let prediction = try await runtime.predictNoul(
            state: "Starcat 是一款原生 macOS GitHub Star 管理工具，支持本地搜索、标签、README 浏览和 AI 知识库。",
            instructions: "这个仓库属于 AI 开发工具。"
        )
        let firstInferenceAt = clock.now
        // 首次 forward 包含 Metal kernel JIT；第二次才代表常驻模型的交互延迟。
        let warmPrediction = try await runtime.predictNoul(
            state: "Starcat 是一款原生 macOS GitHub Star 管理工具，支持本地搜索、标签、README 浏览和 AI 知识库。",
            instructions: "这个仓库属于 AI 开发工具。"
        )
        let warmInferenceAt = clock.now
        let batchPredictions = try await runtime.predictNoulBatch(
            state: "Starcat 是一款原生 macOS GitHub Star 管理工具，支持本地搜索、标签、README 浏览和 AI 知识库。",
            questions: [
                "ai": "这个仓库属于 AI 开发工具。",
                "cooking": "这个仓库主要用于烹饪食谱管理。",
            ]
        )
        let batchInferenceAt = clock.now
        Memory.clearCache()
        let completedMemory = Memory.snapshot()

        #expect(prediction.inputTokenCount == 59)
        #expect(prediction.logits.count == 2)
        #expect(abs(prediction.logits[0] - (-4.359_375)) < 0.01)
        #expect(abs(prediction.logits[1] - 0.258_300_78) < 0.01)
        // MLX Swift 0.31.6 与 Python MLX 0.32.2 的 FP16 kernel 有 1e-4 级舍入差异。
        #expect(abs(prediction.trueProbability - 0.9902) < 0.0002)
        #expect(abs(prediction.confidence - 0.9902) < 0.0002)
        #expect(prediction.decision)
        #expect(warmPrediction.decision == prediction.decision)
        #expect(warmPrediction.trueProbability == prediction.trueProbability)
        #expect(batchPredictions["ai"]?.trueProbability == prediction.trueProbability)
        #expect(batchPredictions["cooking"] != nil)
        print(
            "Laya MLX Swift parity load=\(loadStart.duration(to: loadedAt)) "
                + "firstInference=\(loadedAt.duration(to: firstInferenceAt)) "
                + "warmInference=\(firstInferenceAt.duration(to: warmInferenceAt)) "
                + "batchInference=\(warmInferenceAt.duration(to: batchInferenceAt)) "
                + "tokens=\(prediction.inputTokenCount) logits=\(prediction.logits) "
                + "noul=\(prediction.trueProbability) "
                + "loadedActiveMiB=\(mebibytes(loadedMemory.activeMemory - startingMemory.activeMemory)) "
                + "completedActiveMiB=\(mebibytes(completedMemory.activeMemory - startingMemory.activeMemory)) "
                + "peakMiB=\(mebibytes(completedMemory.peakMemory))"
        )
    }

    @Test("状态快照与结构化日志覆盖手动加载和卸载")
    func publishesResidentStateAndLogs() async throws {
        let directory = try installedModelDirectory()
        let runtimeStore = LayaDecisionRuntimeStore()
        let logStore = LocalAILogStore(persistenceEnabled: false)

        try await LocalAILogContext.$store.withValue(logStore) {
            try await runtimeStore.preload(from: directory)
            let loaded = await runtimeStore.snapshot()
            #expect(loaded.model?.phase == .ready)
            #expect(loaded.model?.directory.standardizedFileURL == directory.standardizedFileURL)
            #expect(loaded.isMLXInitialized)

            try await runtimeStore.unload(reason: "test")
            let unloaded = await runtimeStore.snapshot()
            #expect(unloaded.model?.phase == .unloaded)
            #expect(unloaded.model?.loadedBytes == 0)
        }

        let events = await logStore.snapshot().events
        #expect(events.contains { $0.stage == "model.load.completed" })
        #expect(events.contains { $0.stage == "model.unloaded" })
        #expect(events.allSatisfy {
            $0.modelID == LayaDecisionModelCatalog.multilingual.id
        })
    }

    /// 测试宿主带 App Group entitlement，可直接读取 Starcat 已安装模型；显式路径仅用于
    /// 对拍外部 checkpoint。两种来源都只读，不下载、不删除用户模型。
    private func installedModelDirectory() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["STARCAT_LAYA_MLX_MODEL_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return try #require(LayaDecisionModelStorage.installedModel()?.directory)
    }

    /// 用固定精度输出 MiB，便于在不同机器上比较而不把硬件差异写成测试断言。
    private func mebibytes(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}

/// Unicode scalar tokenizer 让测试能精确观察 prompt 拼接，不复制生产 tokenizer 实现。
private struct ScalarTokenizer: LayaTokenizing {
    let classTokenID = 1
    let separatorTokenID = 2
    let paddingTokenID = 0
    let maskToken = "<mask>"
    let maskTokenID = 3

    func encodeWithoutSpecialTokens(_ text: String) -> [Int] {
        text.unicodeScalars.map { Int($0.value) + 1_000 }
    }

    func id(for scalar: Character) -> Int {
        Int(String(scalar).unicodeScalars.first!.value) + 1_000
    }
}
