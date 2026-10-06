//
//  LocalAISettingsSelection.swift
//  Starcat
//
//  设置、状态面板与普通 AI 任务共用的本地模型选择口径。持久化选择是本地任务真源，
//  安装清单只补充默认值；远程任务及显式会话模型不经过此覆盖路径。
//

import Foundation

/// 状态面板一行对应一个会进 MLX 的模型槽，以及当前绑到它的业务。
/// 生成槽只统计摘要 / 标签 / 对话 / 翻译；知识库问答和 Agent 不用本地对话模型。
struct LocalAIStatusModel: Identifiable, Equatable, Sendable {
    var entry: LocalAIModelCatalogEntry
    var usages: [LocalAIStatusUsage]
    var id: String { entry.id }
}

/// 行上业务标识。文案复用任务页与 Rerank 设置的现成 key，不另造一套。
enum LocalAIStatusUsage: Equatable, Hashable, Sendable {
    case task(AIModelTask)
    case rerank
    case decision
}

extension AppSettings {
    /// 每类只解析一个选中项；未下载的明确选择也必须保留，不能被其它已安装模型顶替。
    func selectedLocalAIModel(
        for type: LocalAIModelType, installedModels: [LocalAIInstalledModel]
    ) -> LocalAIModelCatalogEntry {
        selectedLocalAIModel(for: type, installedIDs: Set(installedModels.map(\.id)))
    }

    /// 请求解析只读取已同步的模型描述，不在主线程逐请求扫描权重目录。
    func selectedLocalAIModel(for type: LocalAIModelType) -> LocalAIModelCatalogEntry {
        let names = Set(aiProviderProfiles.filter { $0.provider == .localAI }.flatMap { $0.models.map(\.name) })
        let installedIDs = Set(LocalAIModelCatalog.entries.filter { names.contains($0.displayName) }.map(\.id))
        return selectedLocalAIModel(for: type, installedIDs: installedIDs)
    }

    private func selectedLocalAIModel(
        for type: LocalAIModelType, installedIDs: Set<String>
    ) -> LocalAIModelCatalogEntry {
        let entries = LocalAIModelCatalog.entries(of: type)
        if let id = localAIModelSelections[type.rawValue],
            let selected = entries.first(where: { $0.id == id })
        {
            return selected
        }
        // 延续设置页原有默认顺序；catalog 保证三类均非空，两处 UI 不再各自猜默认值。
        return entries.first { installedIDs.contains($0.id) }
            ?? entries.first { $0.recommended }
            ?? entries[0]
    }

    /// 保留任务的服务商与 Prompt；本地模型由类别选择决定，不能沿用历史 task.modelID。
    /// 返回值同时冻结参数，调用方须在第一次 await 前保存，之后不再重新解析设置。
    func resolvedAITask(
        _ task: AIModelTaskConfiguration, type: LocalAIModelType = .llm
    ) -> AIModelTaskConfiguration {
        var resolved = task
        if aiProviderProfiles.first(where: { $0.id == task.providerID })?.provider == .localAI {
            let entry = selectedLocalAIModel(for: type)
            resolved.modelID = entry.displayName
            resolved.customModelName = entry.displayName
            resolved.useCustomModel = false
        }
        resolved.parameters = effectiveParameters(for: resolved)
        return resolved
    }

    /// 各任务设置中的本地模型菜单也写同一个类别选择，避免产生第二个可见真源。
    func selectLocalAIModel(named name: String, providerID: String) {
        guard aiProviderProfiles.first(where: { $0.id == providerID })?.provider == .localAI,
              let entry = LocalAIModelCatalog.entries.first(where: { $0.displayName == name }) else { return }
        localAIModelSelections[entry.type.rawValue] = entry.id
    }

    /// 只用到的模型槽才出现：向量化任务、本地 Rerank、以及四个生成类任务。
    /// 知识库工作台选中的对话模型不单独出生成行。设置页当前编辑的服务商不参与门控。
    func localAIStatusModels(installedModels: [LocalAIInstalledModel]) -> [LocalAIStatusModel] {
        LocalAIModelType.allCases.compactMap { type in
            let usages = localAIStatusUsages(for: type)
            guard !usages.isEmpty else { return nil }
            return LocalAIStatusModel(
                entry: selectedLocalAIModel(for: type, installedModels: installedModels),
                usages: usages
            )
        }
    }

    /// 生成类任务顺序与设置页一致，翻译跟在对话后面；embedding / rerank 各自独立。
    private func localAIStatusUsages(for type: LocalAIModelType) -> [LocalAIStatusUsage] {
        switch type {
        case .embedding:
            return isEmbeddingTaskResolvedToLocalAI ? [.task(.embedding)] : []
        case .reranker:
            return usesLocalAIRerank ? [.rerank] : []
        case .llm:
            let generationTasks: [AIModelTask] = [.summary, .tags, .chat, .translation]
            return generationTasks.compactMap { task in
                guard isTaskResolvedToLocalAI(localAITaskConfiguration(task)) else { return nil }
                return LocalAIStatusUsage.task(task)
            }
        }
    }

    private func localAITaskConfiguration(_ task: AIModelTask) -> AIModelTaskConfiguration {
        switch task {
        case .summary: return aiSummaryTask
        case .tags: return aiTagsTask
        case .embedding: return aiEmbeddingTask
        case .translation: return aiTranslationTask
        case .chat: return aiChatTask
        }
    }
}
