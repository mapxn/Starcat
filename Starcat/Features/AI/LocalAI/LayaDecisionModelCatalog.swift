//
//  LayaDecisionModelCatalog.swift
//  Starcat
//
//  Labs 决策引擎使用的固定 Laya checkpoint 描述。
//
//  它刻意不进入通用 Local AI catalog：Laya 不是 Embedding、Reranker 或生成式
//  LLM，也不应该出现在普通 AI Provider / 任务模型选择器中。这里只复用底层下载器、
//  共享目录和跨进程锁。
//

import Foundation

struct LayaDecisionModelDescriptor: Sendable, Equatable {
    let id: String
    let displayName: String
    let source: LocalAIModelSource
    let files: [LocalAIModelFile]
    let estimatedDownloadSize: Int64
    let memoryRecommendation: UInt64
    let contextLength: Int
}

enum LayaDecisionModelCatalog {
    /// 首版只开放已完成 Swift 对拍的多语言 FP16 checkpoint。
    static let multilingual = LayaDecisionModelDescriptor(
        id: "laya-multilingual-mlx",
        displayName: "Laya Multilingual 322M",
        source: LocalAIModelSource(
            kind: .huggingFace,
            repo: "aac6fef/laya-multilingual-mlx",
            revision: nil
        ),
        files: [
            .required("model.safetensors"),
            .required("encoder/config.json"),
            .required("rl_agent_config.json"),
            .required("tokenizer/tokenizer.json"),
            .required("tokenizer/tokenizer_config.json"),
        ],
        estimatedDownloadSize: 678_000_000,
        memoryRecommendation: 750_000_000,
        contextLength: 1_024
    )
}
