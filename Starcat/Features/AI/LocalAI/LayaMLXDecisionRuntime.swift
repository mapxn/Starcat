//
//  LayaMLXDecisionRuntime.swift
//  Starcat
//
//  Laya Multilingual checkpoint 的进程内 MLX Swift runtime。
//
//  当前产品只需要 Noul（false/true）决策：同一仓库的候选 List / 标签按最多 16 个
//  问题组成 batch，一次 forward 返回概率，不做 token-by-token decode。模型、tokenizer
//  与 MLXArray 全部留在 actor 内，避免并发业务把非 Sendable 图状态泄漏出去。
//


import Foundation
import MLX
import MLXNN
import Tokenizers

/// 加载或推理失败时保留足够上下文，避免把 checkpoint 不兼容误报成普通 AI 失败。
enum LayaMLXDecisionError: Error, LocalizedError, Sendable {
    case incompleteCheckpoint(String)
    case invalidConfiguration(String)
    case invalidTokenizer(String)
    case runtimeNotLoaded
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .incompleteCheckpoint(let path):
            return "Laya checkpoint 缺少必需文件：\(path)"
        case .invalidConfiguration(let reason):
            return "Laya checkpoint 配置不兼容：\(reason)"
        case .invalidTokenizer(let reason):
            return "Laya tokenizer 不兼容：\(reason)"
        case .runtimeNotLoaded:
            return "Laya MLX runtime 尚未完成加载"
        case .invalidOutput(let reason):
            return "Laya MLX 推理输出无效：\(reason)"
        }
    }
}

/// checkpoint 权重精度；产品默认与社区预转换模型一致使用 FP16。
enum LayaMLXPrecision: Sendable {
    case float16
    case float32

    fileprivate var dataType: DType {
        switch self {
        case .float16: .float16
        case .float32: .float32
        }
    }
}

/// Noul 的公开结果。`trueProbability` 与 `confidence` 按 laya-mlx 规则保留四位小数。
struct LayaNoulPrediction: Equatable, Sendable {
    let decision: Bool
    let trueProbability: Double
    let confidence: Double
    let logits: [Float]
    let inputTokenCount: Int
}

/// prompt builder 只依赖这一小段 tokenizer 能力，常规单测无需加载 644 MB 权重。
protocol LayaTokenizing: Sendable {
    var classTokenID: Int { get }
    var separatorTokenID: Int { get }
    var paddingTokenID: Int { get }
    var maskToken: String { get }
    var maskTokenID: Int { get }

    func encodeWithoutSpecialTokens(_ text: String) -> [Int]
}

/// Swift Transformers tokenizer 的轻量适配，特殊 token 仍以 checkpoint 配置为准。
private struct LayaTokenizerAdapter: LayaTokenizing {
    let tokenizer: any Tokenizer
    let classTokenID: Int
    let separatorTokenID: Int
    let paddingTokenID: Int
    let maskToken: String
    let maskTokenID: Int

    func encodeWithoutSpecialTokens(_ text: String) -> [Int] {
        tokenizer.encode(text: text, addSpecialTokens: false)
    }
}

/// 单条 Noul 输入的 CPU 表示，marker 顺序恒为 `[false, true]`。
struct LayaPreparedNoulInput: Equatable, Sendable {
    let tokenIDs: [Int]
    let markerPositions: [Int]
}

/// 逐 token 复刻 laya-mlx 的 Noul prompt 和截断规则。
struct LayaNoulPromptBuilder: Sendable {
    let maximumLength: Int
    let headMaximumLength: Int

    /// 格式：`[CLS] noul question... [SEP] [MASK] false... [MASK] true... [SEP] state [SEP]`。
    func build(
        state: String,
        instructions: String,
        tokenizer: any LayaTokenizing
    ) throws -> LayaPreparedNoulInput {
        let options = [
            "false: no, the statement does not hold",
            "true: yes, the statement holds",
        ]
        let sanitizedInstructions = instructions.replacingOccurrences(
            of: tokenizer.maskToken,
            with: " "
        )
        var headIDs = tokenizer.encodeWithoutSpecialTokens(
            "noul question: \(sanitizedInstructions)"
        )
        var optionIDs = options.map { option in
            [tokenizer.maskTokenID]
                + tokenizer.encodeWithoutSpecialTokens(" \(option)").prefix(48)
        }

        var optionBudget = headMaximumLength - optionIDs.reduce(0) { $0 + $1.count }
        if optionBudget < 16 {
            let perOption = max(4, (headMaximumLength - 16) / max(1, optionIDs.count))
            optionIDs = optionIDs.map { Array($0.prefix(perOption)) }
            optionBudget = headMaximumLength - optionIDs.reduce(0) { $0 + $1.count }
        }
        headIDs = Array(headIDs.prefix(max(8, optionBudget)))

        var tokenIDs = [tokenizer.classTokenID] + headIDs + [tokenizer.separatorTokenID]
        var markers: [Int] = []
        for option in optionIDs {
            markers.append(tokenIDs.count)
            tokenIDs.append(contentsOf: option)
        }
        tokenIDs.append(tokenizer.separatorTokenID)

        let room = max(0, maximumLength - tokenIDs.count - 1)
        let sanitizedState = state.replacingOccurrences(of: tokenizer.maskToken, with: " ")
        let stateIDs = tokenizer.encodeWithoutSpecialTokens(sanitizedState)
        tokenIDs.append(contentsOf: stateIDs.prefix(room))
        tokenIDs.append(tokenizer.separatorTokenID)
        tokenIDs = Array(tokenIDs.prefix(maximumLength))
        markers = markers.filter { $0 < maximumLength }

        guard markers.count == options.count else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "head_max_len 无法容纳固定的 false/true marker"
            )
        }
        return LayaPreparedNoulInput(tokenIDs: tokenIDs, markerPositions: markers)
    }
}

/// actor 隔离所有 MLXArray/Module 状态，避免未来接入并发业务后让非 Sendable 图逃逸。
actor LayaMLXDecisionRuntime {
    /// 与 laya-mlx 默认 batch size 对齐；限制峰值内存，较大问题集分块执行。
    private static let maximumBatchSize = 16

    private let modelDirectory: URL
    private let precision: LayaMLXPrecision

    private var model: LayaMLXDecisionModel?
    private var tokenizer: (any LayaTokenizing)?
    private var promptBuilder: LayaNoulPromptBuilder?
    private var calibrationTemperature: Double?

    private init(modelDirectory: URL, precision: LayaMLXPrecision) {
        self.modelDirectory = modelDirectory
        self.precision = precision
    }

    /// 从 laya-mlx 目录加载并严格校验全部权重；方法返回时模型已 materialize。
    static func load(
        from modelDirectory: URL,
        precision: LayaMLXPrecision = .float16
    ) async throws -> LayaMLXDecisionRuntime {
        let runtime = LayaMLXDecisionRuntime(
            modelDirectory: modelDirectory,
            precision: precision
        )
        try await runtime.prepare()
        return runtime
    }

    /// 对一个 statement 执行 Noul 判断，不做生成式 decode。
    func predictNoul(state: String, instructions: String) throws -> LayaNoulPrediction {
        let key = "single"
        let results = try predictNoulBatch(
            state: state,
            questions: [key: instructions]
        )
        guard let result = results[key] else {
            throw LayaMLXDecisionError.invalidOutput("单条 Noul batch 缺少返回值")
        }
        return result
    }

    /// 对共享 state 的多条 Noul 问题分块推理。
    ///
    /// Dictionary 先按 question id 排序，保证 batch 编排稳定；返回仍以 id 为键，
    /// 调用方不依赖模型输出顺序。每个 chunk 独立 padding，避免 150 个标签被最长输入
    /// 拖成一个超大张量。
    func predictNoulBatch(
        state: String,
        questions: [String: String],
        batchSize requestedBatchSize: Int = maximumBatchSize
    ) throws -> [String: LayaNoulPrediction] {
        guard
            let model,
            let tokenizer,
            let promptBuilder,
            let calibrationTemperature
        else {
            throw LayaMLXDecisionError.runtimeNotLoaded
        }
        guard !questions.isEmpty else { return [:] }

        let batchSize = min(max(1, requestedBatchSize), Self.maximumBatchSize)
        let ordered = try questions.sorted { $0.key < $1.key }.map { question in
            (
                id: question.key,
                input: try promptBuilder.build(
                    state: state,
                    instructions: question.value,
                    tokenizer: tokenizer
                )
            )
        }
        var predictions: [String: LayaNoulPrediction] = [:]
        predictions.reserveCapacity(ordered.count)

        for start in stride(from: 0, to: ordered.count, by: batchSize) {
            try Task.checkCancellation()
            let end = min(start + batchSize, ordered.count)
            let chunk = Array(ordered[start..<end])
            let paddedLength = chunk.map { $0.input.tokenIDs.count }.max() ?? 0

            var flatTokenIDs: [Int32] = []
            var flatAttentionMask: [Bool] = []
            var flatMarkerPositions: [Int32] = []
            flatTokenIDs.reserveCapacity(chunk.count * paddedLength)
            flatAttentionMask.reserveCapacity(chunk.count * paddedLength)
            flatMarkerPositions.reserveCapacity(chunk.count * 2)

            for item in chunk {
                let inputLength = item.input.tokenIDs.count
                flatTokenIDs.append(contentsOf: item.input.tokenIDs.map(Int32.init))
                flatTokenIDs.append(contentsOf: repeatElement(
                    Int32(tokenizer.paddingTokenID),
                    count: paddedLength - inputLength
                ))
                flatAttentionMask.append(contentsOf: repeatElement(true, count: inputLength))
                flatAttentionMask.append(contentsOf: repeatElement(
                    false,
                    count: paddedLength - inputLength
                ))
                flatMarkerPositions.append(contentsOf: item.input.markerPositions.map(Int32.init))
            }

            let output = model.noulLogits(
                tokenIDs: MLXArray(flatTokenIDs).reshaped(chunk.count, paddedLength),
                attentionMask: MLXArray(flatAttentionMask).reshaped(chunk.count, paddedLength),
                markerPositions: MLXArray(flatMarkerPositions).reshaped(chunk.count, 2),
                markerMask: MLXArray(
                    [Bool](repeating: true, count: chunk.count * 2)
                ).reshaped(chunk.count, 2)
            )
            eval(output)

            for (index, item) in chunk.enumerated() {
                let logits = output[index].asArray(Float.self)
                predictions[item.id] = try Self.makePrediction(
                    logits: logits,
                    inputTokenCount: item.input.tokenIDs.count,
                    calibrationTemperature: calibrationTemperature
                )
            }
        }
        return predictions
    }

    /// 先解析轻量配置/tokenizer，再构造网络和加载大权重；整个过程留在 actor 内。
    private func prepare() async throws {
        let paths = CheckpointPaths(root: modelDirectory)
        for required in paths.requiredFiles where !FileManager.default.fileExists(atPath: required.path) {
            throw LayaMLXDecisionError.incompleteCheckpoint(required.path)
        }

        let encoderFile = try Self.decode(EncoderConfigurationFile.self, from: paths.encoderConfig)
        let encoderConfiguration = try encoderFile.validated()
        let agentFile = try Self.decode(AgentConfigurationFile.self, from: paths.agentConfig)
        let agentConfiguration = try agentFile.validated(
            maximumPositionEmbeddings: encoderConfiguration.maxPositionEmbeddings
        )
        let specialTokens = try Self.decode(
            TokenizerConfigurationFile.self,
            from: paths.tokenizerConfig
        )
        let upstreamTokenizer = try await AutoTokenizer.from(modelFolder: paths.tokenizerDirectory)
        let tokenizer = try LayaTokenizerAdapter(
            tokenizer: upstreamTokenizer,
            configuration: specialTokens
        )

        let model = LayaMLXDecisionModel(
            encoderConfiguration: encoderConfiguration,
            headLayerCount: agentConfiguration.headLayerCount,
            actionCostCount: agentConfiguration.actionCostCount
        )
        let rawWeights = try MLX.loadArrays(url: paths.weights)
        let weights = rawWeights.mapValues { $0.asType(precision.dataType) }
        try model.update(
            parameters: ModuleParameters.unflattened(weights),
            verify: [.all]
        )
        // 严格加载后立即求值，避免首个业务请求同时承担 644 MB 权重 materialize。
        eval(model)

        self.model = model
        self.tokenizer = tokenizer
        promptBuilder = LayaNoulPromptBuilder(
            maximumLength: agentConfiguration.maximumLength,
            headMaximumLength: agentConfiguration.headMaximumLength
        )
        calibrationTemperature = agentConfiguration.noulTemperature
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from url: URL
    ) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private static func roundedToFourPlaces(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    private static func makePrediction(
        logits: [Float],
        inputTokenCount: Int,
        calibrationTemperature: Double
    ) throws -> LayaNoulPrediction {
        guard logits.count == 2, logits.allSatisfy(\.isFinite) else {
            throw LayaMLXDecisionError.invalidOutput(
                "Noul 应返回两个有限 logits，实际为 \(logits)"
            )
        }
        let scaledFalse = Double(logits[0]) / calibrationTemperature
        let scaledTrue = Double(logits[1]) / calibrationTemperature
        let maximum = max(scaledFalse, scaledTrue)
        let falseMass = exp(scaledFalse - maximum)
        let trueMass = exp(scaledTrue - maximum)
        let trueProbability = trueMass / (falseMass + trueMass)
        return LayaNoulPrediction(
            decision: trueProbability >= 0.5,
            trueProbability: roundedToFourPlaces(trueProbability),
            confidence: roundedToFourPlaces(max(trueProbability, 1 - trueProbability)),
            logits: logits,
            inputTokenCount: inputTokenCount
        )
    }
}

private extension LayaTokenizerAdapter {
    init(
        tokenizer: any Tokenizer,
        configuration: TokenizerConfigurationFile
    ) throws {
        func token(_ value: FlexibleToken, named name: String) throws -> (String, Int) {
            guard let id = tokenizer.convertTokenToId(value.content) else {
                throw LayaMLXDecisionError.invalidTokenizer(
                    "tokenizer_config.json 的 \(name)=\(value.content) 不在 tokenizer.json 中"
                )
            }
            return (value.content, id)
        }

        let classToken = try token(configuration.classToken, named: "cls_token")
        let separatorToken = try token(configuration.separatorToken, named: "sep_token")
        let paddingToken = try token(configuration.paddingToken, named: "pad_token")
        let maskToken = try token(configuration.maskToken, named: "mask_token")
        self.init(
            tokenizer: tokenizer,
            classTokenID: classToken.1,
            separatorTokenID: separatorToken.1,
            paddingTokenID: paddingToken.1,
            maskToken: maskToken.0,
            maskTokenID: maskToken.1
        )
    }
}

/// checkpoint 固定目录布局；集中声明可避免 runtime 各处拼接不一致。
private struct CheckpointPaths {
    let root: URL

    var weights: URL { root.appendingPathComponent("model.safetensors") }
    var agentConfig: URL { root.appendingPathComponent("rl_agent_config.json") }
    var encoderConfig: URL { root.appendingPathComponent("encoder/config.json") }
    var tokenizerDirectory: URL { root.appendingPathComponent("tokenizer", isDirectory: true) }
    var tokenizerJSON: URL { tokenizerDirectory.appendingPathComponent("tokenizer.json") }
    var tokenizerConfig: URL { tokenizerDirectory.appendingPathComponent("tokenizer_config.json") }

    var requiredFiles: [URL] {
        [weights, agentConfig, encoderConfig, tokenizerJSON, tokenizerConfig]
    }
}

/// encoder/config.json 的宽松读取模型；兼容字段由 `validated()` 收口。
private struct EncoderConfigurationFile: Decodable {
    struct RopeParameters: Decodable {
        let ropeTheta: Float?
        let ropeType: String?
    }

    let vocabSize: Int
    let hiddenSize: Int
    let intermediateSize: Int
    let numHiddenLayers: Int
    let numAttentionHeads: Int
    let modelType: String?
    let normEps: Float?
    let layerNormEps: Float?
    let normBias: Bool?
    let attentionBias: Bool?
    let mlpBias: Bool?
    let hiddenActivation: String?
    let localAttention: Int?
    let globalAttnEveryNLayers: Int?
    let globalRopeTheta: Float?
    let localRopeTheta: Float?
    let maxPositionEmbeddings: Int?
    let layerTypes: [String]?
    let ropeParameters: [String: RopeParameters]?

    func validated() throws -> LayaEncoderConfiguration {
        guard modelType ?? "modernbert" == "modernbert" else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "仅支持 modernbert encoder，实际为 \(modelType ?? "nil")"
            )
        }
        guard hiddenActivation ?? "gelu" == "gelu" else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "仅支持 gelu encoder activation"
            )
        }
        guard
            vocabSize > 0,
            hiddenSize > 0,
            intermediateSize > 0,
            numHiddenLayers > 0,
            numAttentionHeads > 0,
            hiddenSize.isMultiple(of: numAttentionHeads),
            (hiddenSize / numAttentionHeads).isMultiple(of: 2)
        else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "ModernBERT dimensions/head count 非法"
            )
        }
        let globalEvery = globalAttnEveryNLayers ?? 3
        guard globalEvery > 0 else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "global_attn_every_n_layers 必须大于 0"
            )
        }
        let kinds: [LayaAttentionKind]
        if let layerTypes {
            kinds = try layerTypes.map { raw in
                guard let kind = LayaAttentionKind(rawValue: raw) else {
                    throw LayaMLXDecisionError.invalidConfiguration(
                        "不支持的 layer_type：\(raw)"
                    )
                }
                return kind
            }
        } else {
            kinds = (0..<numHiddenLayers).map {
                $0.isMultiple(of: globalEvery) ? .full : .sliding
            }
        }
        guard kinds.count == numHiddenLayers else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "layer_types 数量与 num_hidden_layers 不一致"
            )
        }

        var ropeBases: [LayaAttentionKind: Float] = [
            .full: globalRopeTheta ?? 160_000,
            .sliding: localRopeTheta ?? 10_000,
        ]
        for kind in [LayaAttentionKind.full, .sliding] {
            if let parameters = ropeParameters?[kind.rawValue] {
                guard parameters.ropeType ?? "default" == "default" else {
                    throw LayaMLXDecisionError.invalidConfiguration(
                        "仅支持 default RoPE，\(kind.rawValue) 使用 \(parameters.ropeType ?? "nil")"
                    )
                }
                if let theta = parameters.ropeTheta {
                    ropeBases[kind] = theta
                }
            }
        }
        let normEpsilon = normEps ?? layerNormEps ?? 1e-5
        let localAttentionWindow = localAttention ?? 128
        let positions = maxPositionEmbeddings ?? 8_192
        guard
            normEpsilon > 0,
            localAttentionWindow > 0,
            positions > 0,
            ropeBases.values.allSatisfy({ $0 > 0 && $0.isFinite })
        else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "norm/local attention/position/RoPE 参数非法"
            )
        }
        return LayaEncoderConfiguration(
            vocabularySize: vocabSize,
            hiddenSize: hiddenSize,
            intermediateSize: intermediateSize,
            layerCount: numHiddenLayers,
            attentionHeadCount: numAttentionHeads,
            normEpsilon: normEpsilon,
            normBias: normBias ?? false,
            attentionBias: attentionBias ?? false,
            mlpBias: mlpBias ?? false,
            localAttentionWindow: localAttentionWindow,
            maxPositionEmbeddings: positions,
            layerKinds: kinds,
            ropeBases: ropeBases
        )
    }
}

/// rl_agent_config.json 的读取模型；当前只消费构网、长度和 Noul calibration 字段。
private struct AgentConfigurationFile: Decodable {
    let encoder: String?
    let headLayers: Int?
    let maxLen: Int?
    let headMaxLen: Int?
    let actCosts: [String: Double]?
    let temperature: [Double]?
    let temperatureByOptions: [String: Double]?

    func validated(maximumPositionEmbeddings: Int) throws -> ValidatedAgentConfiguration {
        guard encoder?.isEmpty == false, let headLayers, headLayers > 0 else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "rl_agent_config.json 必须声明 encoder 和正数 head_layers"
            )
        }
        let maximumLength = maxLen ?? 512
        let headMaximumLength = headMaxLen ?? 192
        guard
            4 < headMaximumLength,
            headMaximumLength < maximumLength,
            maximumLength <= maximumPositionEmbeddings
        else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "应满足 4 < head_max_len < max_len <= max_position_embeddings"
            )
        }

        let temperatures = temperature ?? [1, 1, 1]
        let optionTemperatures = temperatureByOptions ?? [:]
        let allTemperatures = temperatures + Array(optionTemperatures.values)
        guard
            temperatures.count == 3,
            allTemperatures.allSatisfy({ $0.isFinite && $0 > 0 })
        else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "calibration temperature 必须包含三个有限正数"
            )
        }
        // 与社区 runtime 一致，把过度 sharpening/softening 限制在可信区间。
        let rawNoulTemperature = optionTemperatures["noul:2"] ?? temperatures[2]
        let noulTemperature = min(5, max(0.5, rawNoulTemperature))
        return ValidatedAgentConfiguration(
            headLayerCount: headLayers,
            maximumLength: maximumLength,
            headMaximumLength: headMaximumLength,
            actionCostCount: actCosts?.count ?? 0,
            noulTemperature: noulTemperature
        )
    }
}

private struct ValidatedAgentConfiguration: Sendable {
    let headLayerCount: Int
    let maximumLength: Int
    let headMaximumLength: Int
    let actionCostCount: Int
    let noulTemperature: Double
}

/// tokenizer_config 的特殊 token 既可能是字符串，也可能是 `{ "content": ... }`。
private struct FlexibleToken: Decodable {
    let content: String

    private enum CodingKeys: String, CodingKey {
        case content
    }

    init(from decoder: any Swift.Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let string = try? single.decode(String.self) {
            content = string
            return
        }
        let object = try decoder.container(keyedBy: CodingKeys.self)
        content = try object.decode(String.self, forKey: .content)
    }
}

private struct TokenizerConfigurationFile: Decodable {
    let classToken: FlexibleToken
    let separatorToken: FlexibleToken
    let paddingToken: FlexibleToken
    let maskToken: FlexibleToken

    private enum CodingKeys: String, CodingKey {
        case classToken = "clsToken"
        case separatorToken = "sepToken"
        case paddingToken = "padToken"
        case maskToken
    }
}
