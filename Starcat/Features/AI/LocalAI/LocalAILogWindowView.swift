//
//  LocalAILogWindowView.swift
//  Starcat
//
//  本地 AI 单例日志窗口。控件跟随应用语言，日志正文始终为英文。
//  只提供查看/复制/导出/清空，不控制推理，也不读取用户输入或模型输出。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LocalAILogWindowView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var viewModel = LocalAILogViewModel()
    @State private var selection = LocalAILogWindowSelection.shared
    @State private var manager = LocalAIModelManager.shared
    @State private var layaManager = LayaDecisionModelManager.shared
    @State private var confirmsClearAll = false

    var body: some View {
        VStack(spacing: 0) {
            filters.padding(12)
            actions.padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            LocalAILogTextView(rows: viewModel.rows, fontSize: 12 * interfaceScale.multiplier,
                               followsTail: $viewModel.followsTail)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if viewModel.rows.isEmpty {
                        Text("localai.logs.empty")
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
            Divider()
            HStack {
                Text(viewModel.isPaused ? "localai.logs.paused" : "localai.logs.live")
                Text(verbatim: "\(viewModel.rows.count)")
                    .monospacedDigit()
                Text("localai.logs.entries")
                Spacer()
                Text("localai.logs.retention")
            }
            .font(interfaceScale.font(.captionSmall))
            .foregroundStyle(.secondary)
            .padding(10)
            if let error = viewModel.actionError ?? viewModel.storageError {
                Text(verbatim: error).font(interfaceScale.font(.caption)).foregroundStyle(.secondary).padding(8)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task { await viewModel.observe() }
        .onDisappear { viewModel.releaseDisplay() }
        .onChange(of: selection.revision, initial: true) { _, _ in
            if let id = selection.modelID { viewModel.selectModel(id) }
        }
        .onChange(of: selectedLogModels, initial: true) { _, models in
            viewModel.setSelectedModels(models)
        }
        .alert("localai.logs.clearAll.title", isPresented: $confirmsClearAll) {
            Button("common.cancel", role: .cancel) {}
            Button("localai.logs.clearAll", role: .destructive) { Task { await viewModel.clearAll() } }
        } message: {
            Text("localai.logs.clearAll.message")
        }
    }

    /// 当前状态面板可见模型始终出现在筛选器里；有历史事件的旧模型由 ViewModel
    /// 另外合并。读取 Laya manager 是为了让共享存储刷新也能驱动窗口更新。
    private var selectedLogModels: [String: String] {
        let rows = settings.localAIStatusModels(installedModels: manager.installedModels)
        var models = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.entry.displayName) })
        if settings.decisionEngineEnabled, settings.decisionEngineID == .laya {
            let descriptor = LayaDecisionModelCatalog.multilingual
            models[descriptor.id] = layaManager.installedManifest?.displayName ?? descriptor.displayName
        }
        return models
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("localai.logs.model", selection: $viewModel.modelID) {
                Text("localai.logs.allModels").tag(nil as String?)
                ForEach(viewModel.models.keys.sorted(), id: \.self) { id in
                    Text(verbatim: viewModel.models[id] ?? id).tag(Optional(id))
                }
            }
            .frame(width: 280)
            Picker("localai.logs.level", selection: $viewModel.level) {
                Text("localai.logs.allLevels").tag(nil as LocalAILogEvent.Level?)
                ForEach(LocalAILogEvent.Level.allCases, id: \.self) { level in
                    Text(verbatim: level.rawValue).tag(Optional(level))
                }
            }
            .frame(width: 130)
            TextField("localai.logs.search", text: $viewModel.search)
                .textFieldStyle(.roundedBorder)
        }
        .controlSize(.small)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Toggle("localai.logs.follow", isOn: $viewModel.followsTail)
                .toggleStyle(.checkbox)
            Button { viewModel.isPaused.toggle() } label: {
                Label(viewModel.isPaused ? "localai.logs.resume" : "localai.logs.pause",
                      systemImage: viewModel.isPaused ? "play.fill" : "pause.fill")
            }
            if viewModel.unreadCount > 0 {
                Button("localai.logs.newEntries") {
                    viewModel.isPaused = false
                    viewModel.followsTail = true
                }
            }
            Spacer(minLength: 0)
            CopyFeedbackButton(providesContent: { viewModel.copyText }, tooltip: "localai.logs.copy", style: .bordered) { copied in
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : .secondary)
            }
            .disabled(viewModel.rows.isEmpty)
            Button(action: exportLogs) { Image(systemName: "square.and.arrow.up") }
                .help("localai.logs.export")
                .accessibilityLabel("localai.logs.export")
                .disabled(viewModel.isExporting || viewModel.isClearing)
            Button { viewModel.clearView() } label: { Image(systemName: "clear") }
                .help("localai.logs.clearView")
                .accessibilityLabel("localai.logs.clearView")
            Button("localai.logs.clearAll") { confirmsClearAll = true }
                .disabled(viewModel.isClearing || viewModel.isExporting)
        }
        .controlSize(.small)
    }

    /// NSSavePanel 的用户确认只授权导出选定文件；不扫描用户目录，不主动打开 Finder。
    private func exportLogs() {
        let panel = NSSavePanel()
        panel.title = String.l10n("localai.logs.export")
        panel.nameFieldStringValue = "local-ai-logs.jsonl"
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await viewModel.export(to: url) }
        }
    }
}
