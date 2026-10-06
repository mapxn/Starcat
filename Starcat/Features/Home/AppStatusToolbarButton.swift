//
//  AppStatusToolbarButton.swift
//  Starcat
//
//  主窗口 toolbar 的全局状态入口。
//
//  设计约束：
//  - 只展示“同步 / 后台任务 / 服务可用性 / MCP / 浏览器插件 / 诊断问题”的轻量概览；
//  - 知识库向量化与 README 预拉一样计入后台任务，避免只能在设置页看到进度；
//  - 诊断问题从本机 JSONL 摘要读取，避免把状态面板变成新的错误来源；
//  - 服务可用性走四个自建 API 的 `/healthz`，打开面板时实时刷新，后台每 10 分钟巡检；
//  - 跳转复用 SettingsView 已有的 Notification 路由，不新增主窗口路由状态。
//

import AppKit
import SwiftUI

/// toolbar 状态按钮：点击后展示应用状态 popover。
struct AppStatusToolbarButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings
    @Environment(SyncManager.self) private var syncManager
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let lastSyncedAt: Date?
    let onShowBatchAIPanel: (() -> Void)?

    @State private var isPresented = false
    @State private var diagnosticSummary: DiagnosticLogSummary = .empty
    /// Toolbar 与设置页必须观察同一个配置实例，端口冲突才能即时反映到全局状态。
    @State private var pluginConfiguration = CompanionConfiguration.shared

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: overallStatusIcon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(overallStatusColor)
                    .font(.system(size: ToolbarIconMetrics.defaultFontSize, weight: .regular))
                    .frame(
                        width: ToolbarIconMetrics.frameSize,
                        height: ToolbarIconMetrics.frameSize,
                        alignment: .center
                    )
                if activeTaskCount > 0 {
                    Text("\(activeTaskCount)")
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.16), in: Capsule())
                }
            }
            .accessibilityLabel(Text("toolbar.status.label"))
            .accessibilityValue(Text(statusCaption))
        }
        .help("toolbar.status.help")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ScrollView {
                AppStatusPanel(
                    lastSyncedAt: lastSyncedAt,
                    syncState: syncManager.state,
                    syncProgress: syncManager.progress,
                    readmePrefetchService: dependencies.readmePrefetchService,
                    readmePrefetchEnabled: settings.readmePrefetchEnabled,
                    readmePrefetchPoller: dependencies.readmePrefetchPoller,
                    initialWarmupCoordinator: dependencies.initialWarmupCoordinator,
                    openSSFScorePoller: dependencies.openSSFScorePoller,
                    repoHealthPoller: dependencies.repoHealthPoller,
                    undoStarCleanup: dependencies.undoStarCleanupScheduler,
                    batchService: dependencies.batchAIQueueService,
                    ragIndexBuilder: dependencies.knowledgeRAGIndexBuilder,
                    mcpState: dependencies.mcpService.state,
                    mcpEnabled: settings.mcpServiceEnabled,
                    browserPluginState: pluginConfiguration.serverStatus,
                    browserPluginEnabled: pluginConfiguration.isEnabled,
                    githubStatusMonitor: dependencies.githubStatusMonitor,
                    serviceSummary: dependencies.serviceAvailabilityMonitor.summary,
                    diagnosticSummary: diagnosticSummary,
                    aiUsageRepository: dependencies.aiUsageRepository,
                    relativePastDate: relativePastDate,
                    relativeFutureDate: relativeFutureDate,
                    onOpenDiagnostics: { openSettings(tab: "diagnostics") },
                    onClearDiagnostics: {
                        Task { await clearDiagnostics() }
                    },
                    onOpenServices: { openSettings(tab: "services") },
                    onOpenMCP: { openSettings(tab: "mcp") },
                    onOpenBrowserPlugin: { openSettings(tab: "integrations.browserPlugin") },
                    onOpenAIUsage: { AIUsageWindowController.show(dependencies: dependencies) },
                    onShowBatchAIPanel: onShowBatchAIPanel,
                    onOpenGeneralSettings: { openSettings(tab: "general") },
                    onOpenAbout: { AboutWindowController.show() },
                    onOpenStorage: { openSettings(tab: "storage") },
                    onOpenLocalAI: { openSettings(tab: "ai") },
                    onOpenLabs: { openSettings(tab: "labs") },
                    onOpenLocalAILogs: { modelID in
                        LocalAILogWindowSelection.shared.select(modelID)
                        isPresented = false
                        openWindow(id: LocalAILogWindowSelection.sceneID)
                    }
                )
                .frame(width: AppStatusPanelMetrics.width)
                .padding(14)
            }
            .frame(maxHeight: 640)
            .appLocaleEnvironment()
            .task {
                await refreshDiagnostics()
                await dependencies.serviceAvailabilityMonitor.refreshNow()
                await dependencies.githubStatusMonitor.refreshNow()
            }
        }
        .task {
            await refreshDiagnostics()
        }
        .onReceive(NotificationCenter.default.publisher(for: .diagnosticIssuesDidChange)) { _ in
            Task { await refreshDiagnostics() }
        }
        .onChange(of: isPresented) { _, newValue in
            guard newValue else { return }
            Task {
                await refreshDiagnostics()
                await dependencies.serviceAvailabilityMonitor.refreshNow()
                await dependencies.githubStatusMonitor.refreshNow()
            }
        }
    }

    private var activeTaskCount: Int {
        let batch = dependencies.batchAIQueueService
        let batchRemaining = (batch.isRunning || batch.isPaused) ? max(0, batch.totalCount - batch.finishedCount) : 0
        let readme = dependencies.readmePrefetchService
        let readmeRemaining = readme.isRunning
            ? max(0, readme.total - readme.processed)
            : (dependencies.readmePrefetchPoller.isDraining ? 1 : 0)
        let warmup = dependencies.initialWarmupCoordinator
        let warmupRemaining: Int
        if warmup.isActive, let job = warmup.job {
            warmupRemaining = max(0, job.readmeTotal - job.readmeCovered)
                + max(0, warmup.openSSFTotal - warmup.openSSFCovered)
                + max(0, job.healthTotal - job.healthCovered)
        } else {
            warmupRemaining = warmup.isRunning ? 1 : 0
        }
        let openSSF = dependencies.openSSFScorePoller
        let openSSFRemaining = openSSF.isRefreshing
            ? max(1, openSSF.refreshTotal - openSSF.refreshProcessed)
            : 0
        let health = dependencies.repoHealthPoller
        let healthRemaining = health.isRefreshing
            ? max(1, health.refreshTotal - health.refreshProcessed)
            : 0
        let rag = dependencies.knowledgeRAGIndexBuilder.status
        let ragRemaining: Int
        if case let .embedding(processed, total) = rag {
            ragRemaining = max(0, total - processed)
        } else if rag.isActivelyIndexing {
            ragRemaining = 1
        } else {
            ragRemaining = 0
        }
        return batchRemaining + readmeRemaining + warmupRemaining + openSSFRemaining + healthRemaining + ragRemaining
    }

    private var hasIssue: Bool {
        diagnosticSummary.issueCount > 0
            || isMCPFailed
            || isBrowserPluginFailed
            || dependencies.githubStatusMonitor.hasRelevantIssue
            || dependencies.serviceAvailabilityMonitor.summary.hasIssue
            || dependencies.initialWarmupCoordinator.job?.phase == .paused
    }

    private var isMCPFailed: Bool {
        if case .failed = dependencies.mcpService.state { return true }
        return false
    }

    private var isBrowserPluginFailed: Bool {
        if case .failed = pluginConfiguration.serverStatus { return true }
        return false
    }

    private var overallStatusIcon: String {
        if hasIssue { return "exclamationmark.circle.fill" }
        if syncManager.isSyncing || activeTaskCount > 0 { return "arrow.triangle.2.circlepath.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var overallStatusColor: Color {
        if hasIssue { return .orange }
        if syncManager.isSyncing || activeTaskCount > 0 { return .accentColor }
        return .green
    }

    private var statusCaption: LocalizedStringKey {
        if hasIssue { return "toolbar.status.caption.issue" }
        if syncManager.isSyncing { return "toolbar.status.caption.syncing" }
        if activeTaskCount > 0 { return "toolbar.status.caption.tasks" }
        return "toolbar.status.caption.ok"
    }

    private func refreshDiagnostics() async {
        diagnosticSummary = await DiagnosticLogStore.shared.issueSummary()
    }

    private func clearDiagnostics() async {
        await DiagnosticLogStore.shared.markIssuesAcknowledged()
        await refreshDiagnostics()
    }

    private func relativePastDate(_ date: Date) -> String {
        RelativeTimeText.pastEvent(date, locale: locale)
    }

    private func relativeFutureDate(_ date: Date) -> String {
        RelativeTimeText.futureDeadline(date, locale: locale)
    }

    private func openSettings(tab: String) {
        AppDelegate.openSettingsWindow(target: tab)
    }
}

/// 状态 popover 内容。
private struct AppStatusPanel: View {
    let lastSyncedAt: Date?
    let syncState: SyncState
    let syncProgress: SyncProgress?
    let readmePrefetchService: ReadmePrefetchService
    let readmePrefetchEnabled: Bool
    let readmePrefetchPoller: ReadmePrefetchPoller
    let initialWarmupCoordinator: InitialRepoWarmupCoordinator
    let openSSFScorePoller: OpenSSFScorePoller
    let repoHealthPoller: RepoHealthPoller
    let undoStarCleanup: UndoStarCleanupScheduler
    let batchService: BatchAIQueueService
    let ragIndexBuilder: KnowledgeRAGIndexBuilder
    let mcpState: StarcatMCPService.State
    let mcpEnabled: Bool
    let browserPluginState: CompanionConfiguration.ServerStatus
    let browserPluginEnabled: Bool
    let githubStatusMonitor: GitHubStatusMonitor
    let serviceSummary: ServiceAvailabilitySummary
    let diagnosticSummary: DiagnosticLogSummary
    let aiUsageRepository: any AIUsageRepositoryProtocol
    let relativePastDate: (Date) -> String
    let relativeFutureDate: (Date) -> String
    let onOpenDiagnostics: () -> Void
    let onClearDiagnostics: () -> Void
    let onOpenServices: () -> Void
    let onOpenMCP: () -> Void
    let onOpenBrowserPlugin: () -> Void
    let onOpenAIUsage: () -> Void
    let onShowBatchAIPanel: (() -> Void)?
    let onOpenGeneralSettings: () -> Void
    let onOpenAbout: () -> Void
    let onOpenStorage: () -> Void
    let onOpenLocalAI: () -> Void
    let onOpenLabs: () -> Void
    let onOpenLocalAILogs: (String) -> Void

    @State private var isTaskCancelHovered = false
    @State private var aiUsageSummary = AIUsageSummary.empty
    @State private var aiUsagePeakTokens = 0
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            overviewGrid
            aiUsageCard
            LocalAIStatusSection(
                onOpenSettings: onOpenLocalAI,
                onOpenLayaSettings: onOpenLabs,
                onOpenLogs: onOpenLocalAILogs
            )
            integrationGrid
            diagnosticsRow
            undoStarRow
            footer
        }
        .task { await loadAIUsageSummary() }
    }

    private func loadAIUsageSummary() async {
        var calendar = Calendar.current
        calendar.locale = locale
        let now = Date()
        do {
            aiUsageSummary = try await aiUsageRepository.summary(
                filter: AIUsageFilter(timeRange: .today),
                now: now,
                calendar: calendar
            )
            // 没有日限额，进度条用「今日 / 近 7 天单日峰值」做相对值，避免画一个假的 40%。
            let week = try await aiUsageRepository.statistics(
                filter: AIUsageFilter(timeRange: .sevenDays),
                now: now,
                calendar: calendar,
                recentLimit: 1
            )
            aiUsagePeakTokens = max(
                week.daily.map(\.totalTokens).max() ?? 0,
                aiUsageSummary.totalTokens
            )
        } catch {
            // 状态 popover 是轻量入口；查询失败不应该再制造一个全局诊断问题。
            aiUsageSummary = .empty
            aiUsagePeakTokens = 0
        }
    }

    @ViewBuilder
    private var diagnosticAccessory: some View {
        HStack(spacing: 6) {
            if diagnosticSummary.issueCount > 0 {
                Button("toolbar.status.diagnostics.clear") {
                    onClearDiagnostics()
                }
                .controlSize(.small)
                .focusEffectDisabled()
            }
            Button("toolbar.status.diagnostics.open") {
                onOpenDiagnostics()
            }
            .controlSize(.small)
            .focusEffectDisabled()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(verbatim: "Starcat")
                        .font(interfaceScale.font(.panelTitle, weight: .semibold))
                    brandStatusPill
                }
                Text("toolbar.status.brand.subtitle")
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            AppStatusHeaderIconButton(helpKey: "toolbar.status.settings", action: onOpenGeneralSettings) {
                Image(systemName: "gearshape")
                    .font(interfaceScale.font(.iconMedium, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(width: 1, height: 16)

            Menu {
                Button("toolbar.status.more.about", action: onOpenAbout)
            } label: {
                Image(systemName: "ellipsis")
                    .font(interfaceScale.font(.iconMedium, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Color.secondary.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .focusEffectDisabled()
            .help("toolbar.status.more.about")
        }
    }

    private var brandStatusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(brandStatusTint)
                .frame(width: 6, height: 6)
            Text(brandStatusKey)
                .font(interfaceScale.font(.captionSmall, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var overviewGrid: some View {
        HStack(alignment: .top, spacing: AppStatusPanelMetrics.gridSpacing) {
            AppStatusOverviewCard(
                title: "toolbar.status.sync.title",
                value: syncCardValue,
                caption: syncCardCaption,
                tint: syncTint
            ) {
                statusGlyph(syncIcon, tint: syncTint)
            }

            AppStatusOverviewCard(
                title: "toolbar.status.github.cardTitle",
                value: githubCardValue,
                caption: githubCardCaption,
                tint: githubStatusTint,
                action: { NSWorkspace.shared.open(GitHubStatusClient.statusPageURL) }
            ) {
                Image("github")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(githubStatusTint)
                    .accessibilityHidden(true)
            }

            AppStatusOverviewCard(
                title: "toolbar.status.tasks.title",
                value: taskCardValue,
                caption: taskCardCaption,
                tint: taskTint,
                showsChevron: true,
                action: { onShowBatchAIPanel?() },
                icon: { statusGlyph(taskIcon, tint: taskTint) },
                accessory: {
                    if hasCancellableBackgroundTask {
                        cancellableTaskIndicator
                    }
                }
            )
        }
    }

    private var aiUsageCard: some View {
        AppStatusGroupCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(interfaceScale.font(.iconMedium, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("ai.usage.popover.title")
                        .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
                    Spacer(minLength: 8)
                    Button(action: onOpenAIUsage) {
                        HStack(spacing: 4) {
                            Text("ai.usage.open")
                            Image(systemName: "chevron.right")
                                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                        }
                        .font(interfaceScale.font(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }

                Text(verbatim: aiUsageSummaryLine)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ProgressView(value: aiUsageFraction)
                        .progressViewStyle(.linear)
                    if let percent = aiUsagePercentLabel {
                        Text(verbatim: percent)
                            .font(interfaceScale.font(.captionSmall, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var integrationGrid: some View {
        HStack(alignment: .top, spacing: AppStatusPanelMetrics.gridSpacing) {
            AppStatusOverviewCard(
                title: "toolbar.status.services.title",
                value: serviceCardValue,
                caption: "",
                tint: serviceTint,
                showsChevron: true,
                action: onOpenServices
            ) {
                statusGlyph(serviceIcon, tint: serviceTint)
            }
            AppStatusOverviewCard(
                title: "toolbar.status.mcp.title",
                value: mcpCardValue,
                caption: "",
                tint: mcpTint,
                showsChevron: true,
                action: onOpenMCP
            ) {
                statusGlyph(mcpIcon, tint: mcpTint)
            }
            AppStatusOverviewCard(
                title: "toolbar.status.browserPlugin.title",
                value: browserPluginCardValue,
                caption: "",
                tint: browserPluginTint,
                showsChevron: true,
                action: onOpenBrowserPlugin
            ) {
                statusGlyph(browserPluginIcon, tint: browserPluginTint)
            }
        }
    }

    private var diagnosticsRow: some View {
        AppStatusActionRow(
            title: "toolbar.status.diagnostics.title",
            subtitle: diagnosticSubtitle,
            systemImage: diagnosticIcon,
            tint: diagnosticTint,
            showsChevron: false
        ) {
            diagnosticAccessory
        }
    }

    private var undoStarRow: some View {
        AppStatusActionRow(
            title: "toolbar.status.undoStar.title",
            subtitle: undoStarSubtitle,
            systemImage: "arrow.uturn.backward.circle",
            tint: .orange,
            action: onOpenStorage
        ) {
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: String(
                format: String.l10n("toolbar.status.footer.versionFormat"),
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
            ))
            Spacer(minLength: 8)
            Text("toolbar.status.footer.tagline")
        }
        .font(interfaceScale.font(.captionSmall))
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func statusGlyph(_ systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(interfaceScale.font(.iconSmall, weight: .semibold))
            .foregroundStyle(tint)
            .symbolRenderingMode(.hierarchical)
    }

    private var brandStatusKey: LocalizedStringKey {
        if panelHasIssue { return "toolbar.status.brand.issue" }
        if panelIsBusy { return "toolbar.status.brand.busy" }
        return "toolbar.status.brand.running"
    }

    private var brandStatusTint: Color {
        if panelHasIssue { return .orange }
        if panelIsBusy { return .accentColor }
        return .green
    }

    private var panelHasIssue: Bool {
        if diagnosticSummary.issueCount > 0 { return true }
        if githubStatusMonitor.hasRelevantIssue { return true }
        if serviceSummary.hasIssue { return true }
        if initialWarmupCoordinator.job?.phase == .paused { return true }
        if case .failed = mcpState { return true }
        if case .failed = browserPluginState { return true }
        if case .failed = syncState { return true }
        if case .rateLimited = syncState { return true }
        return false
    }

    private var panelIsBusy: Bool {
        if case .syncing = syncState { return true }
        if runningTaskCount > 0 { return true }
        return batchService.isPaused
    }

    private var syncCardValue: String {
        switch syncState {
        case .syncing:
            return String.l10n("toolbar.status.sync.syncingShort")
        case .completed(let at):
            return relativePastDate(at)
        case .failed(let message):
            return message
        case .rateLimited(let retryAt):
            if RelativeTimeText.isImmediateDeadline(retryAt) {
                return String.l10n("toolbar.status.sync.rateLimitedRetryNow")
            }
            return String(format: String.l10n("toolbar.status.sync.rateLimitedFormat"), relativeFutureDate(retryAt))
        case .idle:
            if let lastSyncedAt {
                return relativePastDate(lastSyncedAt)
            }
            return String.l10n("toolbar.status.sync.notYet")
        }
    }

    private var syncCardCaption: String {
        switch syncState {
        case .syncing:
            if let progress = syncProgress, let total = progress.total {
                return String(format: String.l10n("toolbar.status.sync.progressFormat"), progress.current, total)
            }
            return String.l10n("toolbar.status.sync.running")
        case .completed:
            return String.l10n("toolbar.status.sync.upToDate")
        case .idle:
            return lastSyncedAt != nil ? String.l10n("toolbar.status.sync.upToDate") : ""
        case .failed, .rateLimited:
            return ""
        }
    }

    private var githubCardValue: String {
        if githubStatusMonitor.isChecking && githubStatusMonitor.snapshot == nil {
            return String.l10n("toolbar.status.github.checking")
        }
        guard let snapshot = githubStatusMonitor.snapshot else {
            return String.l10n("toolbar.status.github.unavailable")
        }
        // 卡片宽度放不下 "API Requests 正常"；短状态词才能和另外两张保持同一 14pt，避免再压字号。
        switch snapshot.apiRequestsStatus {
        case .operational: return String.l10n("toolbar.status.github.cardState.operational")
        case .degradedPerformance: return String.l10n("toolbar.status.github.cardState.degraded")
        case .partialOutage: return String.l10n("toolbar.status.github.cardState.partialOutage")
        case .majorOutage: return String.l10n("toolbar.status.github.cardState.majorOutage")
        case .underMaintenance: return String.l10n("toolbar.status.github.cardState.maintenance")
        case .unknown: return String.l10n("toolbar.status.github.cardState.unknown")
        }
    }

    private var githubCardCaption: String {
        guard let snapshot = githubStatusMonitor.snapshot else { return "" }
        return relativePastDate(snapshot.fetchedAt)
    }

    private var taskCardValue: String {
        let count = runningTaskCount
        if count == 0 {
            return String.l10n("toolbar.status.tasks.emptyShort")
        }
        return String(format: String.l10n("toolbar.status.tasks.countFormat"), count)
    }

    private var taskCardCaption: String {
        if hasCancellableBackgroundTask {
            return String.l10n("toolbar.status.tasks.runningCaption")
        }
        return String.l10n("toolbar.status.tasks.idleCaption")
    }

    private var runningTaskCount: Int {
        let batchRemaining = (batchService.isRunning || batchService.isPaused)
            ? max(0, batchService.totalCount - batchService.finishedCount)
            : 0
        let readmeRemaining = readmePrefetchService.isRunning
            ? max(0, readmePrefetchService.total - readmePrefetchService.processed)
            : (readmePrefetchPoller.isDraining ? 1 : 0)
        let warmupRemaining: Int
        if initialWarmupCoordinator.isActive, let job = initialWarmupCoordinator.job {
            warmupRemaining = max(0, job.readmeTotal - job.readmeCovered)
                + max(0, initialWarmupCoordinator.openSSFTotal - initialWarmupCoordinator.openSSFCovered)
                + max(0, job.healthTotal - job.healthCovered)
        } else {
            warmupRemaining = initialWarmupCoordinator.isRunning ? 1 : 0
        }
        let openSSFRemaining = openSSFScorePoller.isRefreshing
            ? max(1, openSSFScorePoller.refreshTotal - openSSFScorePoller.refreshProcessed)
            : 0
        let healthRemaining = repoHealthPoller.isRefreshing
            ? max(1, repoHealthPoller.refreshTotal - repoHealthPoller.refreshProcessed)
            : 0
        let ragRemaining: Int
        if case let .embedding(processed, total) = ragIndexBuilder.status {
            ragRemaining = max(0, total - processed)
        } else if ragIndexBuilder.status.isActivelyIndexing {
            ragRemaining = 1
        } else {
            ragRemaining = 0
        }
        return batchRemaining + readmeRemaining + warmupRemaining
            + openSSFRemaining + healthRemaining + ragRemaining
    }

    private var aiUsageSummaryLine: String {
        String(
            format: String.l10n("ai.usage.popover.summaryFormat"),
            aiUsageSummary.totalTokens.formatted(.number.notation(.compactName).locale(locale)),
            aiUsageSummary.callCount
        )
    }

    private var aiUsageFraction: Double {
        guard aiUsagePeakTokens > 0 else { return 0 }
        return min(1, Double(aiUsageSummary.totalTokens) / Double(aiUsagePeakTokens))
    }

    private var aiUsagePercentLabel: String? {
        guard aiUsagePeakTokens > 0, aiUsageSummary.totalTokens > 0 else { return nil }
        let percent = Int((aiUsageFraction * 100).rounded())
        return String(format: String.l10n("toolbar.status.aiUsage.percentFormat"), percent)
    }

    private var serviceCardValue: String {
        if serviceSummary.hasChecked {
            return String(
                format: String.l10n("toolbar.status.services.cardCountFormat"),
                serviceSummary.availableCount,
                serviceSummary.totalCount
            )
        }
        return serviceSubtitle
    }

    private var mcpCardValue: String {
        switch mcpState {
        case .running:
            return String.l10n("toolbar.status.mcp.running")
        case .failed(let message):
            return String(format: String.l10n("toolbar.status.mcp.failedFormat"), message)
        case .stopped:
            return mcpEnabled
                ? String.l10n("toolbar.status.mcp.stopped")
                : String.l10n("toolbar.status.mcp.disabled")
        }
    }

    private var browserPluginCardValue: String {
        switch browserPluginState {
        case .running:
            return String.l10n("settings.integration.browserPlugin.status.running")
        case .starting:
            return String.l10n("settings.integration.browserPlugin.status.starting")
        case .failed(let failure):
            return failure.localizedDescription
        case .stopped:
            return browserPluginEnabled
                ? String.l10n("settings.integration.browserPlugin.status.stopped")
                : String.l10n("toolbar.status.browserPlugin.disabled")
        }
    }

    private var undoStarSubtitle: String {
        guard let lastCleanup = undoStarCleanup.lastCleanupAt else {
            return String.l10n("toolbar.status.undoStar.empty")
        }
        let count = undoStarCleanup.lastCleanupCount
        if count > 0 {
            return String(
                format: String.l10n("toolbar.status.undoStar.lastCleanupWithCount"),
                count,
                relativePastDate(lastCleanup)
            )
        }
        return String(
            format: String.l10n("toolbar.status.undoStar.lastCleanup"),
            relativePastDate(lastCleanup)
        )
    }

    private var syncIcon: String {
        switch syncState {
        case .syncing: return "arrow.triangle.2.circlepath"
        case .failed, .rateLimited: return "exclamationmark.triangle.fill"
        case .idle, .completed: return "checkmark.circle.fill"
        }
    }

    private var syncTint: Color {
        switch syncState {
        case .failed, .rateLimited: return .orange
        case .syncing: return .accentColor
        case .idle, .completed: return .green
        }
    }

    private var taskIcon: String {
        if isInitialWarmupPaused || isReadmePrefetchWaitingForRetry || batchService.failedCount > 0 { return "exclamationmark.triangle.fill" }
        if initialWarmupCoordinator.isRunning || openSSFScorePoller.isRefreshing || repoHealthPoller.isRefreshing || readmePrefetchService.isRunning || readmePrefetchPoller.isDraining || batchService.isRunning || ragIndexBuilder.status.isActivelyIndexing {
            return "clock.arrow.circlepath"
        }
        if batchService.isPaused { return "pause.circle.fill" }
        return "tray"
    }

    private var taskTint: Color {
        if isInitialWarmupPaused || isReadmePrefetchWaitingForRetry || readmePrefetchService.failures > 0 || batchService.failedCount > 0 { return .orange }
        if initialWarmupCoordinator.isRunning || openSSFScorePoller.isRefreshing || repoHealthPoller.isRefreshing || readmePrefetchService.isRunning || readmePrefetchPoller.isDraining || isReadmePrefetchCoolingDown || batchService.isRunning || batchService.isPaused || ragIndexBuilder.status.isActivelyIndexing {
            return .accentColor
        }
        if initialWarmupCoordinator.isCompleted || isReadmePrefetchAllFetched { return .green }
        return .secondary
    }

    /// 状态面板只暴露“终止当前这一轮”的能力：
    /// - 不关闭 README / OpenSSF / Health 的周期调度开关；
    /// - 不回滚已经写入的缓存或 AI 结果；
    /// - 对批量 AI 沿用现有 cancel 语义，当前 in-flight job 结束后停止继续取队列。
    private var hasCancellableBackgroundTask: Bool {
        initialWarmupCoordinator.isRunning
            || openSSFScorePoller.isRefreshing
            || repoHealthPoller.isRefreshing
            || readmePrefetchService.isRunning
            || readmePrefetchPoller.isDraining
            || batchService.isRunning
            || ragIndexBuilder.status.isActivelyIndexing
    }

    private var cancellableTaskIndicator: some View {
        Button {
            cancelCurrentBackgroundTask()
        } label: {
            ZStack {
                ProgressView()
                    .controlSize(.mini)
                    .opacity(isTaskCancelHovered ? 0 : 1)
                Image(systemName: "xmark.circle.fill")
                    .font(interfaceScale.font(.caption, weight: .semibold))
                    .foregroundStyle(.red)
                    .opacity(isTaskCancelHovered ? 1 : 0)
            }
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text("common.cancel"))
        .onHover { isTaskCancelHovered = $0 }
    }

    private func cancelCurrentBackgroundTask() {
        if initialWarmupCoordinator.isRunning {
            initialWarmupCoordinator.cancel()
        }
        if openSSFScorePoller.isRefreshing {
            openSSFScorePoller.cancelCurrentRefresh()
        }
        if repoHealthPoller.isRefreshing {
            repoHealthPoller.cancelCurrentRefresh()
        }
        if readmePrefetchService.isRunning || readmePrefetchPoller.isDraining {
            readmePrefetchPoller.cancelCurrentRun()
        }
        if batchService.isRunning {
            batchService.cancel()
        }
        if ragIndexBuilder.status.isActivelyIndexing {
            ragIndexBuilder.cancel()
        }
    }

    private var isReadmePrefetchCoolingDown: Bool {
        if case .coolingDown = readmePrefetchService.status { return true }
        return false
    }

    private var isReadmePrefetchWaitingForRetry: Bool {
        if case .waitingForRetry = readmePrefetchService.status { return true }
        return false
    }

    private var isReadmePrefetchAllFetched: Bool {
        if case .allPrefetched = readmePrefetchService.status { return true }
        return false
    }

    private var isInitialWarmupPaused: Bool {
        initialWarmupCoordinator.job?.phase == .paused
    }

    private var serviceIcon: String {
        if serviceSummary.isChecking { return "arrow.triangle.2.circlepath" }
        if serviceSummary.hasIssue { return "exclamationmark.triangle.fill" }
        if serviceSummary.isAllAvailable { return "checkmark.circle.fill" }
        return "globe"
    }

    private var githubStatusTint: Color {
        if githubStatusMonitor.isChecking { return .accentColor }
        guard let status = githubStatusMonitor.snapshot?.apiRequestsStatus else { return .secondary }
        switch status {
        case .operational: return .green
        case .degradedPerformance, .partialOutage: return .orange
        case .majorOutage: return .red
        case .underMaintenance: return .accentColor
        case .unknown: return .secondary
        }
    }

    private var serviceTint: Color {
        if serviceSummary.hasIssue { return .orange }
        if serviceSummary.isAllAvailable { return .green }
        if serviceSummary.isChecking { return .accentColor }
        return .secondary
    }

    private var serviceSubtitle: String {
        if serviceSummary.isChecking && !serviceSummary.hasChecked {
            return String.l10n("toolbar.status.services.checking")
        }
        guard serviceSummary.hasChecked else {
            return String.l10n("toolbar.status.services.notChecked")
        }
        if serviceSummary.failedServices.isEmpty {
            return String(
                format: String.l10n("toolbar.status.services.availableFormat"),
                serviceSummary.availableCount,
                serviceSummary.totalCount
            )
        }
        let failed = serviceSummary.failedServices.map(\.rawValue).joined(separator: ", ")
        return String(
            format: String.l10n("toolbar.status.services.failedFormat"),
            serviceSummary.availableCount,
            serviceSummary.totalCount,
            failed
        )
    }

    private var mcpIcon: String {
        if case .failed = mcpState { return "exclamationmark.triangle.fill" }
        if case .running = mcpState { return "network" }
        return "network.slash"
    }

    private var mcpTint: Color {
        if case .failed = mcpState { return .orange }
        if case .running = mcpState { return .green }
        return .secondary
    }

    private var browserPluginIcon: String {
        if case .failed = browserPluginState { return "exclamationmark.triangle.fill" }
        if case .running = browserPluginState { return "puzzlepiece.extension.fill" }
        return "puzzlepiece.extension"
    }

    private var browserPluginTint: Color {
        if case .failed = browserPluginState { return .orange }
        if case .running = browserPluginState { return .green }
        if case .starting = browserPluginState { return .accentColor }
        return .secondary
    }

    private var diagnosticIcon: String {
        diagnosticSummary.issueCount > 0 ? "stethoscope" : "checkmark.seal.fill"
    }

    private var diagnosticTint: Color {
        diagnosticSummary.issueCount > 0 ? .orange : .green
    }

    private var diagnosticSubtitle: String {
        guard diagnosticSummary.issueCount > 0 else {
            return String.l10n("toolbar.status.diagnostics.clean")
        }
        if let latest = diagnosticSummary.latestIssue {
            return String(format: String.l10n("toolbar.status.diagnostics.issueFormat"), diagnosticSummary.issueCount, latest.message)
        }
        return String(format: String.l10n("toolbar.status.diagnostics.countFormat"), diagnosticSummary.issueCount)
    }
}
