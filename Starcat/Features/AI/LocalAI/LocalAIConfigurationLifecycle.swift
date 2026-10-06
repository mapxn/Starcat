//
//  LocalAIConfigurationLifecycle.swift
//  Starcat
//
//  设置变更与本地模型驻留的衔接。按所有功能的选择求并集，避免对话换 API 时误卸载
//  仍被摘要、翻译、RAG 或向量化使用的本地模型。配置不是自动加载指令。
//

import Foundation

extension AppSettings {
    var configuredLocalAIModelNames: Set<String> {
        let tasks = [aiChatTask, aiSummaryTask, aiTagsTask, aiTranslationTask].map { resolvedAITask($0) }
            + [resolvedAITask(aiEmbeddingTask, type: .embedding)]
        // 卸载与请求必须使用同一选择结果，不能因 task 中遗留 Qwen3 就保留错的权重。
        var names = Set(tasks.filter { isTaskResolvedToLocalAI($0) }.map(\.resolvedModelName))
        for profile in aiProviderProfiles where profile.provider == .localAI {
            if let selected = profile.models.first(where: { $0.id == ragWorkspaceSelectedModelID }) {
                names.insert(selected.name)
            }
        }
        if ragRerankConfiguration.isEnabled, ragRerankConfiguration.provider == .localMLX {
            names.insert(selectedLocalAIModel(for: .reranker).displayName)
        }
        return names
    }

    /// 同一 MainActor 上的 Task 读取最新完整配置，避免多个 didSet 发送过时快照。
    func localAIConfigurationDidChange() {
        guard !TestEnvironment.isRunning, LocalAIHardwareSupport.isLocalAIAvailable else { return }
        Task { [weak self] in
            guard let self else { return }
            await LocalMLXRuntime.shared.releaseUnusedModels(keeping: self.configuredLocalAIModelNames)
        }
    }

    /// Laya 不是普通 Provider 模型，不能混入 `configuredLocalAIModelNames`；关闭总开关
    /// 或切到 Jev 时单独回收，避免状态面板隐藏后仍有决策权重驻留。
    func decisionEngineConfigurationDidChange() {
        guard !TestEnvironment.isRunning, LocalAIHardwareSupport.isLocalAIAvailable else { return }
        Task { [weak self] in
            // 和普通 Local AI 配置一样，在任务真正执行时读取最新完整配置，避免用户
            // 快速切回 Laya 后，旧 didSet 任务仍把刚要使用的模型卸载。
            guard let self,
                  !self.decisionEngineEnabled || self.decisionEngineID != .laya
            else { return }
            do {
                try await LayaDecisionModelManager.shared.unloadFromMemory(
                    reason: "configuration_changed"
                )
            } catch is CancellationError {
                // App shutdown or a superseding lifecycle task can cancel a queued unload.
            } catch {
                AppLog.ai.error(
                    "Unload Laya after configuration change failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
