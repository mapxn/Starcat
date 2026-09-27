//
//  BatchAIInsightProviding.swift
//  Starcat
//
//  批量 AI 队列与单仓洞察服务之间的窄依赖边界。
//
//  关键约束：
//  - 批量启动必须在创建任何 job 前完成 Provider、API Key 与模型预检；
//  - 手动批量入口显式传递本次代码上下文与外部搜索选择；未传覆盖值的后台整理仍关闭
//    External Context，避免数千仓库整理隐式放大外部检索流量；
//  - 协议保持 MainActor 隔离，让队列状态与洞察服务遵循同一并发模型，并允许单测
//    注入可控的阻塞实现验证 in-flight 取消传播。
//

import Foundation

@MainActor
protocol BatchAIInsightProviding: AnyObject {
    func ensureGenerationClientsReady(includeSummary: Bool, includeTags: Bool) throws

    /// 带调用来源的预检入口。其他 Provider 通过默认实现保持既有行为。
    func ensureGenerationClientsReady(
        includeSummary: Bool,
        includeTags: Bool,
        invocationMode: BatchAIInvocationMode
    ) throws

    /// 带标签生成策略的预检入口。Jev 生效时允许把 LLM 校验延迟到真正需要新增标签时。
    func ensureGenerationClientsReady(
        includeSummary: Bool,
        includeTags: Bool,
        invocationMode: BatchAIInvocationMode,
        tagGenerationPolicy: AITagGenerationPolicy
    ) throws

    /// 标签专用批量入口。一个请求承载多个仓库，返回值必须包含每个 repo id。
    /// `purpose == .newOnly` 时，Provider 必须拒绝 repo 已有标签和全库词表中的名称。
    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints],
        purpose: AITagSuggestionPurpose
    ) async throws -> [Int64: [AITagSuggestion]]

    /// 带调用来源的标签入口，避免自动整理误入只面向人工审核的实验 Provider。
    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints],
        invocationMode: BatchAIInvocationMode
    ) async throws -> [Int64: [AITagSuggestion]]

    /// 批量入口显式携带“是否允许新增”和自动应用阈值，供统一 Jev-first 路由判断兜底。
    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints],
        invocationMode: BatchAIInvocationMode,
        tagGenerationPolicy: AITagGenerationPolicy
    ) async throws -> [Int64: [AITagSuggestion]]

    func generateBatchInsight(
        for repo: Repo,
        existingTagHints: AITagHints,
        includeSummary: Bool,
        includeTags: Bool,
        codeContextEnabledOverride: Bool?,
        externalContextEnabledOverride: Bool?
    ) async throws -> RepoAIInsightGeneration

    /// 摘要与标签混合任务仍保持并行，但标签子分支必须使用同一套 Jev-first 策略。
    func generateBatchInsight(
        for repo: Repo,
        existingTagHints: AITagHints,
        includeSummary: Bool,
        includeTags: Bool,
        codeContextEnabledOverride: Bool?,
        externalContextEnabledOverride: Bool?,
        tagGenerationPolicy: AITagGenerationPolicy
    ) async throws -> RepoAIInsightGeneration
}

extension BatchAIInsightProviding {
    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints]
    ) async throws -> [Int64: [AITagSuggestion]] {
        try await generateBatchTagSuggestions(
            for: repos,
            tagHintsByRepoID: tagHintsByRepoID,
            purpose: .reuseFirst
        )
    }

    func ensureGenerationClientsReady(
        includeSummary: Bool,
        includeTags: Bool,
        invocationMode: BatchAIInvocationMode
    ) throws {
        try ensureGenerationClientsReady(includeSummary: includeSummary, includeTags: includeTags)
    }

    func ensureGenerationClientsReady(
        includeSummary: Bool,
        includeTags: Bool,
        invocationMode: BatchAIInvocationMode,
        tagGenerationPolicy: AITagGenerationPolicy
    ) throws {
        try ensureGenerationClientsReady(
            includeSummary: includeSummary,
            includeTags: includeTags,
            invocationMode: invocationMode
        )
    }

    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints],
        invocationMode: BatchAIInvocationMode
    ) async throws -> [Int64: [AITagSuggestion]] {
        try await generateBatchTagSuggestions(
            for: repos,
            tagHintsByRepoID: tagHintsByRepoID,
            purpose: .reuseFirst
        )
    }

    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints],
        invocationMode: BatchAIInvocationMode,
        tagGenerationPolicy: AITagGenerationPolicy
    ) async throws -> [Int64: [AITagSuggestion]] {
        try await generateBatchTagSuggestions(
            for: repos,
            tagHintsByRepoID: tagHintsByRepoID,
            invocationMode: invocationMode
        )
    }

    func generateBatchInsight(
        for repo: Repo,
        existingTagHints: AITagHints,
        includeSummary: Bool,
        includeTags: Bool,
        codeContextEnabledOverride: Bool?,
        externalContextEnabledOverride: Bool?,
        tagGenerationPolicy: AITagGenerationPolicy
    ) async throws -> RepoAIInsightGeneration {
        try await generateBatchInsight(
            for: repo,
            existingTagHints: existingTagHints,
            includeSummary: includeSummary,
            includeTags: includeTags,
            codeContextEnabledOverride: codeContextEnabledOverride,
            externalContextEnabledOverride: externalContextEnabledOverride
        )
    }
}

extension RepoAIInsightService: BatchAIInsightProviding {
    func ensureGenerationClientsReady(
        includeSummary: Bool,
        includeTags: Bool,
        invocationMode: BatchAIInvocationMode,
        tagGenerationPolicy: AITagGenerationPolicy
    ) throws {
        if includeTags, tagGenerationPolicy.allowNewTags, invocationMode == .manual {
            // 人工批次允许扩词时，LLM 会在 Jev 闭集首轮完成后承担一次整批概念发现。
            // 启动前就校验配置，避免处理完数千仓库才发现无法进入第二阶段。
            try ensureGenerationClientsReady(includeSummary: includeSummary, includeTags: true)
        } else {
            try ensureGenerationClientsReady(
                includeSummary: includeSummary,
                includeTags: includeTags,
                tagGenerationPolicy: tagGenerationPolicy
            )
        }
    }

    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints],
        purpose: AITagSuggestionPurpose
    ) async throws -> [Int64: [AITagSuggestion]] {
        try await generateTagSuggestions(
            for: repos,
            tagHintsByRepoID: tagHintsByRepoID,
            purpose: purpose
        )
    }

    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints],
        invocationMode: BatchAIInvocationMode,
        tagGenerationPolicy: AITagGenerationPolicy
    ) async throws -> [Int64: [AITagSuggestion]] {
        try await generateTagSuggestions(
            for: repos,
            tagHintsByRepoID: tagHintsByRepoID,
            policy: tagGenerationPolicy
        )
    }

    func generateBatchInsight(
        for repo: Repo,
        existingTagHints: AITagHints,
        includeSummary: Bool,
        includeTags: Bool,
        codeContextEnabledOverride: Bool?,
        externalContextEnabledOverride: Bool?
    ) async throws -> RepoAIInsightGeneration {
        try await generateInsight(
            for: repo,
            existingTagHints: existingTagHints,
            includeSummary: includeSummary,
            includeTags: includeTags,
            // nil 代表自动整理等旧调用方：继续禁止批量外部搜索；手动入口传入明确值后，
            // 再由 RepoAIInsightService 按 Provider 可用性与私有仓库策略逐仓判断。
            allowExternalContext: externalContextEnabledOverride != nil,
            codeContextEnabledOverride: codeContextEnabledOverride,
            externalContextEnabledOverride: externalContextEnabledOverride
        )
    }

    func generateBatchInsight(
        for repo: Repo,
        existingTagHints: AITagHints,
        includeSummary: Bool,
        includeTags: Bool,
        codeContextEnabledOverride: Bool?,
        externalContextEnabledOverride: Bool?,
        tagGenerationPolicy: AITagGenerationPolicy
    ) async throws -> RepoAIInsightGeneration {
        try await generateInsight(
            for: repo,
            existingTagHints: existingTagHints,
            includeSummary: includeSummary,
            includeTags: includeTags,
            tagGenerationPolicy: tagGenerationPolicy,
            allowExternalContext: externalContextEnabledOverride != nil,
            codeContextEnabledOverride: codeContextEnabledOverride,
            externalContextEnabledOverride: externalContextEnabledOverride
        )
    }
}
