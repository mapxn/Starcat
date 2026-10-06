//
//  LocalAILogViewModel.swift
//  Starcat
//
//  实时日志窗口的展示状态。暂停/清屏只影响视图；真正清空通过日志队列屏障完成。
//

import Foundation
import Observation

/// 窗口数据有界，关闭窗口即取消订阅并释放快照；不持有模型或推理任务。
@MainActor @Observable
final class LocalAILogViewModel {
    var modelID: String? { didSet { rebuild() } }
    var level: LocalAILogEvent.Level? { didSet { rebuild() } }
    var search = "" { didSet { rebuild() } }
    var isPaused = false { didSet { if !isPaused { applyLatest() } } }
    var followsTail = true { didSet { if followsTail { markSeen() } } }
    private(set) var rows: [LocalAILogEvent] = []
    private(set) var models: [String: String] = [:]
    private(set) var unreadCount = 0
    private(set) var isClearing = false
    private(set) var isExporting = false
    private(set) var storageError: String?
    var actionError: String?

    @ObservationIgnored private let store: LocalAILogStore
    @ObservationIgnored private var latest = LocalAILogSnapshot()
    @ObservationIgnored private var displayed: [LocalAILogEvent] = []
    @ObservationIgnored private var clearFloor: UInt64 = 0
    @ObservationIgnored private var lastSeen: UInt64 = 0
    @ObservationIgnored private var selectedModels: [String: String] = [:]

    init(store: LocalAILogStore = .shared) { self.store = store }

    /// 注册即获得快照，随后每 200ms 最多更新一次；stream 的 newest(1) 合并中间帧。
    func observe() async {
        let subscription = store.updates()
        defer { subscription.cancel() }
        for await snapshot in subscription.stream {
            guard !Task.isCancelled else { return }
            receive(snapshot)
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
    }

    func receive(_ snapshot: LocalAILogSnapshot) {
        // clearAll 的主动刷新可能比旧订阅帧先回到 MainActor；旧帧绝不能撤销清空屏障。
        guard snapshot.clearGeneration >= latest.clearGeneration,
              snapshot.clearGeneration != latest.clearGeneration || snapshot.revision >= latest.revision else { return }
        // 即使正在暂停显示，也必须响应清空，不能在恢复时把旧快照重新显示出来。
        if snapshot.clearGeneration != latest.clearGeneration {
            displayed.removeAll()
            clearFloor = 0
            lastSeen = snapshot.lastSequence
        }
        latest = snapshot
        storageError = snapshot.storageError
        if !isPaused { displayed = snapshot.events }
        rebuild()
    }

    /// 日志窗口接收稳定 ID 到显示名的轻量映射；Laya 刻意不属于通用模型目录，
    /// 因此这里不能再把筛选来源限制为 `LocalAIModelCatalogEntry`。
    func setSelectedModels(_ models: [String: String]) {
        selectedModels = models
        rebuild()
    }

    func selectModel(_ id: String) {
        clearFloor = 0
        modelID = id
        isPaused = false
        followsTail = true
    }

    /// 清屏建立序号下界，后续筛选或暂停恢复不会把已清屏的内容重新带回来。
    func clearView() {
        clearFloor = latest.lastSequence
        lastSeen = latest.lastSequence
        rebuild()
    }

    func clearAll() async {
        guard !isClearing else { return }
        isClearing = true
        actionError = nil
        defer { isClearing = false }
        do {
            try await store.clearAll()
            receive(await store.snapshot())
        } catch {
            actionError = String.l10n("localai.logs.clearFailed")
        }
    }

    func export(to url: URL) async {
        isExporting = true
        actionError = nil
        defer { isExporting = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do { try await store.export(to: url) }
        catch { actionError = String.l10n("localai.logs.exportFailed") }
    }

    func releaseDisplay() {
        displayed.removeAll()
        rows.removeAll()
        latest = .init()
        models = selectedModels
        unreadCount = 0
    }

    var copyText: String { rows.map(\.line).joined(separator: "\n") }

    private func applyLatest() {
        displayed = latest.events
        rebuild()
    }

    private func markSeen() {
        lastSeen = rows.last?.sequence ?? latest.lastSequence
        unreadCount = 0
    }

    private func rebuild() {
        models = selectedModels
        for event in latest.events {
            if let id = event.modelID, let name = event.modelName { models[id] = name }
        }
        // 从某个模型入口打开后即使刚好清空日志，也保留它的筛选，不切换成全模型。
        if let modelID, models[modelID] == nil {
            if let entry = LocalAIModelCatalog.entry(id: modelID) {
                models[modelID] = entry.displayName
            } else if modelID == LayaDecisionModelCatalog.multilingual.id {
                models[modelID] = LayaDecisionModelCatalog.multilingual.displayName
            }
        }
        rows = displayed.filter(matches)
        if followsTail && !isPaused { markSeen() }
        else { unreadCount = latest.events.filter { $0.sequence > lastSeen && matches($0) }.count }
    }

    private func matches(_ event: LocalAILogEvent) -> Bool {
        guard event.sequence > clearFloor else { return false }
        // 全局内存压力/日志丢弃也影响选中模型，所以无模型归属的事件仍显示。
        if let modelID, let eventModel = event.modelID, modelID != eventModel { return false }
        if let level, event.level != level { return false }
        // 屏幕行只显示短 ID；导出文件中的完整请求 ID 也必须能用于定位同一次调用。
        return search.isEmpty || event.line.localizedCaseInsensitiveContains(search)
            || event.requestID?.localizedCaseInsensitiveContains(search) == true
    }
}
