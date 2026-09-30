//
//  LabsSettingsView.swift
//  Starcat
//
//  设置页 → 实验性功能(Labs)Tab。
//
//  定位:
//  - 实验性能力的统一开关入口：用户在 Jev 与 Laya 中显式选择一个决策引擎，
//    后续实现继续通过同一抽象注册，不把业务开关复制成多套;
//  - 本页只做「配置 + 探测」,不持有任何业务装配(路由器在 AppDependencies);
//  - 「测试连接」同时是 POC 的速度验证入口:发一次真实 Noul 决策,
//    显示往返延迟与返回概率,让 dong4j 无需跑整理流程就能感知 Jev 速度。
//
//  关键约束:
//  - API Key 走 `KeychainManager` service key 机制(serviceID = typesafe-ai),
//    草稿编辑不落盘,「测试连接」成功才持久化(与 ServicesSettings 的
//    「保存合并进测试」约定一致);清空输入框立即删除已存 Key;
//  - 原生 TypeSafe Key 为空或最近一次显式测试失败时，可复用已验证的 OpenRouter
//    profile；fallback 只读取已有 Key，不复制、不改写 provider 配置，也不使用其
//    可编辑 Base URL；
//  - 原生测试失败只记录路由状态，不删除 Key、不自动开启任何开关；普通业务请求失败
//    也不会触发双跑，避免瞬时故障产生双份费用与延迟。
//

import SwiftUI

struct LabsSettingsTab: View {

    @Environment(AppSettings.self) private var settings

    @State private var draftAPIKey = ""
    @State private var hasStoredNativeAPIKey = false
    @State private var revealAPIKey = false
    @State private var testState: TestState = .idle
    @State private var openRouterFallback: JevDecisionAccess?
    @State private var layaManager = LayaDecisionModelManager.shared
    @State private var layaTestState: LayaTestState = .idle

    /// 测试结果本身只在会话内展示；原生 Key 是否应被 fallback 跳过由 AppSettings 持久化。
    private enum TestState: Equatable {
        case idle
        case testing
        case succeeded(source: TestSource, elapsedMilliseconds: Int, noul: Double)
        case failed(String)
    }

    private enum TestSource: Equatable {
        case typeSafe
        case openRouter(profileName: String)
    }

    private struct ConnectionProbeResult {
        let elapsedMilliseconds: Int
        let noul: Double
    }

    private enum ConnectionProbeError: LocalizedError {
        case missingAnswer

        var errorDescription: String? {
            String.l10n("settings.labs.typesafe.test.missingAnswer")
        }
    }

    private enum LayaTestState: Equatable {
        case idle
        case testing
        case succeeded(elapsedMilliseconds: Int, noul: Double)
        case failed(String)
    }

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Text("settings.labs.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            decisionEngineSection

            if settings.decisionEngineEnabled {
                switch settings.decisionEngineID {
                case .jev:
                    jevSection
                case .laya:
                    layaSection
                }
            }
        }
        .formStyle(.grouped)
        .task {
            loadConfiguration()
            layaManager.refreshFromSharedStorage()
        }
        .onChange(of: draftAPIKey) { _, newValue in
            testState = .idle
            // 清空草稿 = 删除已存 Key(与 ExternalSearch 的编辑语义一致);
            // 非空编辑只停留在草稿,等「测试连接」成功才落盘。
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? KeychainManager.shared.deleteServiceAPIKey(
                    forService: JevDecisionEngine.keychainServiceID
                )
                hasStoredNativeAPIKey = false
                // 已无原生 Key 时失败标记没有意义；fallback 原因回到「未配置」。
                settings.typesafeNativeKeyTestFailed = false
            }
        }
        .onChange(of: openRouterProfileRevision) { _, _ in
            refreshOpenRouterFallback()
        }
    }

    // MARK: - 决策引擎通用配置

    private var decisionEngineSection: some View {
        @Bindable var settings = settings
        return Section {
            Toggle("settings.labs.decision.enable", isOn: $settings.decisionEngineEnabled)
            Text("settings.labs.decision.enable.description")
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.decisionEngineEnabled {
                Picker("settings.labs.decision.engine", selection: $settings.decisionEngineID) {
                    ForEach(DecisionEngineID.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }

                Toggle(
                    "settings.labs.decision.grouping",
                    isOn: $settings.decisionGroupingSuggestionsEnabled
                )
                Text("settings.labs.decision.grouping.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    "settings.labs.decision.tags",
                    isOn: $settings.decisionTagSuggestionsEnabled
                )
                Text("settings.labs.decision.tags.pooled.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("settings.labs.decision.scope.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SettingsSectionHeader(
                "settings.labs.decision.section",
                systemImage: "point.3.connected.trianglepath.dotted"
            )
        }
    }

    // MARK: - TypeSafe Jev 配置

    private var jevSection: some View {
        Section {
            openRouterFallbackRow

            // 两条 Jev 凭据路径都不可用时，明确告知业务会回退原 AI Provider。
            if !hasUsableCredential {
                Label("settings.labs.typesafe.noAvailableRoute", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            apiKeyRows
            modelRow
            testConnectionRow
        } header: {
            SettingsSectionHeader(
                "settings.labs.typesafe.section",
                systemImage: "network"
            )
        }
    }

    // MARK: - Laya 本地模型配置

    private var layaSection: some View {
        let descriptor = LayaDecisionModelCatalog.multilingual
        return Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(descriptor.displayName)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(ByteCountFormatter.string(
                        fromByteCount: descriptor.estimatedDownloadSize,
                        countStyle: .file
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Text("settings.labs.laya.model.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(descriptor.source.repo)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            layaInstallStatus

            HStack(spacing: 8) {
                layaTestFeedback
                Spacer(minLength: 8)
                layaInstallAction

                Button("settings.labs.laya.test") {
                    testLayaModel()
                }
                .buttonStyle(.bordered)
                .disabled(layaManager.installedDirectoryURL == nil || layaTestState == .testing)
            }

            Text("settings.labs.laya.localOnly.note")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            SettingsSectionHeader("settings.labs.laya.section", systemImage: "cpu")
        }
    }

    @ViewBuilder
    private var layaInstallStatus: some View {
        switch layaManager.installState {
        case .idle:
            Label("settings.labs.laya.status.notInstalled", systemImage: "square.and.arrow.down")
                .foregroundStyle(.secondary)
        case .preparing:
            Label("settings.localai.model.status.preparing", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case let .downloading(progress, completedBytes, totalBytes, _):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text(
                    "\(ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)) / "
                        + ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        case let .failed(message), let .loadFailed(message), let .deleteFailed(message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("settings.labs.laya.status.loading")
                    .foregroundStyle(.secondary)
            }
        case .deleting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("settings.labs.laya.status.deleting")
                    .foregroundStyle(.secondary)
            }
        case .installed:
            Label("settings.labs.laya.status.ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var layaInstallAction: some View {
        switch layaManager.installState {
        case .idle, .failed:
            Button("settings.labs.laya.install") {
                layaTestState = .idle
                layaManager.install()
            }
            .buttonStyle(.bordered)
        case .preparing, .downloading:
            Button("settings.localai.model.action.pause") {
                layaManager.pause()
            }
            .buttonStyle(.bordered)
        case .loadFailed:
            Button("settings.localai.model.action.retryLoad") {
                layaManager.retryLoad()
            }
            .buttonStyle(.bordered)
        case .installed, .deleteFailed:
            Button("settings.labs.laya.delete", role: .destructive) {
                layaTestState = .idle
                layaManager.delete()
            }
            .buttonStyle(.bordered)
        case .loading, .deleting:
            EmptyView()
        }
    }

    @ViewBuilder
    private var layaTestFeedback: some View {
        switch layaTestState {
        case .idle, .testing:
            EmptyView()
        case let .succeeded(milliseconds, noul):
            Label(
                String(
                    format: String.l10n("settings.labs.laya.test.successFormat"),
                    NSNumber(value: milliseconds),
                    String(format: "%.2f", noul)
                ),
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - OpenRouter fallback 状态

    @ViewBuilder
    private var openRouterFallbackRow: some View {
        if let fallback = openRouterFallback,
           let profileName = fallback.openRouterProfileDisplayName {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: openRouterStatusImage)
                    .foregroundStyle(openRouterStatusColor)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(openRouterStatusTitle(profileName: profileName))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("settings.labs.typesafe.openRouter.available.description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "network.slash")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.labs.typesafe.openRouter.unavailable")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("settings.labs.typesafe.openRouter.unavailable.description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - API Key 行

    @ViewBuilder
    private var apiKeyRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("settings.labs.typesafe.apiKey.optional")
                    .font(.callout.weight(.medium))
                Spacer()
                Link("settings.labs.typesafe.apiKey.get", destination: Self.consoleKeysURL)
                    .font(.caption.weight(.medium))
            }

            HStack(spacing: 8) {
                Group {
                    if revealAPIKey {
                        TextField("", text: $draftAPIKey, prompt: Text("settings.labs.typesafe.apiKey.placeholder"))
                    } else {
                        SecureField("", text: $draftAPIKey, prompt: Text("settings.labs.typesafe.apiKey.placeholder"))
                    }
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .id(revealAPIKey)

                Button {
                    revealAPIKey.toggle()
                } label: {
                    Image(systemName: revealAPIKey ? "eye.slash" : "eye")
                        .font(SettingsIconMetrics.standardGlyph)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(revealAPIKey ? "settings.labs.typesafe.apiKey.hide" : "settings.labs.typesafe.apiKey.reveal")
            }
        }
    }

    // MARK: - 模型行

    private var modelRow: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 4) {
            Text("settings.labs.typesafe.model")
                .font(.callout.weight(.medium))
            if let fallback = activeOpenRouterFallback {
                Text(fallback.modelID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let profileName = fallback.openRouterProfileDisplayName {
                    Text(
                        String(
                            format: String.l10n("settings.labs.typesafe.model.openRouterFormat"),
                            profileName
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField(
                    "",
                    text: $settings.typesafeModelID,
                    prompt: Text(JevDecisionEngine.defaultModelID)
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }
            if activeOpenRouterFallback != nil {
                Text("settings.labs.typesafe.model.openRouterDescription")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("settings.labs.typesafe.model.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 测试连接

    /// 独立操作按钮按设置页规范右对齐;结果与错误留在同行左侧。
    private var testConnectionRow: some View {
        HStack(alignment: .center, spacing: 8) {
            testFeedback
            Spacer(minLength: 8)

            Button {
                testConnection()
            } label: {
                if testState == .testing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("settings.labs.typesafe.test")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .fixedSize()
            .disabled(!canTest)
        }
    }

    @ViewBuilder
    private var testFeedback: some View {
        switch testState {
        case .idle, .testing:
            EmptyView()
        case let .succeeded(source, milliseconds, noul):
            Label(
                title: {
                    successFeedback(source: source, milliseconds: milliseconds, noul: noul)
                },
                icon: { Image(systemName: "checkmark.circle.fill") }
            )
            .font(.caption)
            .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func successFeedback(source: TestSource, milliseconds: Int, noul: Double) -> Text {
        let probability = String(format: "%.2f", noul)
        switch source {
        case .typeSafe:
            return Text(
                String(
                    format: String.l10n("settings.labs.typesafe.test.successFormat"),
                    NSNumber(value: milliseconds),
                    probability
                )
            )
        case let .openRouter(profileName):
            return Text(
                String(
                    format: String.l10n("settings.labs.typesafe.test.openRouterSuccessFormat"),
                    profileName,
                    NSNumber(value: milliseconds),
                    probability
                )
            )
        }
    }

    // MARK: - 动作

    private static let consoleKeysURL = URL(string: "https://console.typesafe.ai/settings/keys")!

    private var nativeCredentialIsUsable: Bool {
        hasStoredNativeAPIKey && !settings.typesafeNativeKeyTestFailed
    }

    private var hasUsableCredential: Bool {
        nativeCredentialIsUsable || openRouterFallback != nil
    }

    private var activeOpenRouterFallback: JevDecisionAccess? {
        nativeCredentialIsUsable ? nil : openRouterFallback
    }

    private var trimmedDraftKey: String {
        draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canTest: Bool {
        testState != .testing && (!trimmedDraftKey.isEmpty || openRouterFallback != nil)
    }

    private var openRouterStatusImage: String {
        settings.typesafeNativeKeyTestFailed && hasStoredNativeAPIKey
            ? "exclamationmark.triangle.fill"
            : "checkmark.circle.fill"
    }

    private var openRouterStatusColor: Color {
        settings.typesafeNativeKeyTestFailed && hasStoredNativeAPIKey ? .orange : .green
    }

    private func openRouterStatusTitle(profileName: String) -> String {
        let key: String
        if settings.typesafeNativeKeyTestFailed && hasStoredNativeAPIKey {
            key = "settings.labs.typesafe.openRouter.activeFailedFormat"
        } else if !hasStoredNativeAPIKey {
            key = "settings.labs.typesafe.openRouter.activeMissingKeyFormat"
        } else {
            key = "settings.labs.typesafe.openRouter.readyFormat"
        }
        return String(format: String.l10n(key), profileName)
    }

    /// 只追踪会影响 fallback 资格与展示的字段，避免比较 profile 内最多 300 个模型。
    private var openRouterProfileRevision: [String] {
        settings.aiProviderProfiles
            .filter { $0.provider == .openRouter }
            .map {
                [
                    $0.id,
                    $0.displayName,
                    String($0.isEnabled),
                    String($0.lastTestStatus.isSuccess),
                    $0.lastTestedAt ?? ""
                ].joined(separator: "|")
            }
    }

    private func loadConfiguration() {
        let storedAPIKey = (try? KeychainManager.shared.loadServiceAPIKey(
            forService: JevDecisionEngine.keychainServiceID
        )) ?? ""
        draftAPIKey = storedAPIKey
        hasStoredNativeAPIKey = !storedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasStoredNativeAPIKey {
            settings.typesafeNativeKeyTestFailed = false
        }
        refreshOpenRouterFallback()
    }

    private func refreshOpenRouterFallback() {
        openRouterFallback = JevDecisionEngine.resolveOpenRouterFallback(
            settings: settings,
            keychain: KeychainManager.shared
        )
    }

    /// 优先测试输入框里的原生 TypeSafe Key；失败且有 OpenRouter fallback 时，在同一次
    /// 用户操作内验证 fallback。原生失败状态会持久化，但 Key 本身保留供后续修正重试。
    private func testConnection() {
        let candidate = trimmedDraftKey
        guard let access = JevDecisionEngine.resolveAccess(
            settings: settings,
            keychain: KeychainManager.shared,
            nativeAPIKeyOverride: candidate
        ) else { return }
        let fallbackAccess = openRouterFallback
        testState = .testing

        Task {
            do {
                let result = try await probeConnection(using: access)
                recordSuccessfulConnection(access: access, result: result)
            } catch is CancellationError {
                testState = .idle
            } catch {
                guard access.api == .typeSafe else {
                    testState = .failed(error.localizedDescription)
                    return
                }

                let nativeError = error
                settings.typesafeNativeKeyTestFailed = true
                guard let fallbackAccess else {
                    testState = .failed(nativeError.localizedDescription)
                    return
                }

                do {
                    let result = try await probeConnection(using: fallbackAccess)
                    recordSuccessfulConnection(access: fallbackAccess, result: result)
                } catch is CancellationError {
                    testState = .idle
                } catch {
                    testState = .failed(
                        String(
                            format: String.l10n("settings.labs.typesafe.test.bothFailedFormat"),
                            nativeError.localizedDescription,
                            error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    /// 一次探测只验证一个明确的凭据来源；是否继续 fallback 由调用者决定，避免业务请求
    /// 复用这里的双探测语义。
    private func probeConnection(using access: JevDecisionAccess) async throws -> ConnectionProbeResult {
        // 一次性 client 不依赖 AppDependencies 装配，设置页可以独立验证两条固定 API 路径。
        let client = TypeSafeClient()
        let clock = ContinuousClock()
        let start = clock.now
        let response = try await client.evaluate(
            state: "Starcat is a native macOS application for managing GitHub stars.",
            model: access.modelID,
            questions: [
                "demo": .noul(
                    instructions: "Does this text describe a software product?",
                    criteria: nil
                )
            ],
            apiKey: access.apiKey,
            api: access.api,
            operation: .connectionTest
        )
        let elapsed = clock.now - start
        let milliseconds = Int(elapsed.components.seconds) * 1_000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

        guard let noul = response.answers["demo"]?.noul, noul.isFinite else {
            throw ConnectionProbeError.missingAnswer
        }
        return ConnectionProbeResult(elapsedMilliseconds: milliseconds, noul: noul)
    }

    private func recordSuccessfulConnection(
        access: JevDecisionAccess,
        result: ConnectionProbeResult
    ) {
        let source: TestSource
        switch access.source {
        case .typeSafe:
            try? KeychainManager.shared.storeServiceAPIKey(
                access.apiKey,
                forService: JevDecisionEngine.keychainServiceID
            )
            hasStoredNativeAPIKey = true
            settings.typesafeNativeKeyTestFailed = false
            source = .typeSafe
        case let .openRouter(_, displayName):
            source = .openRouter(profileName: displayName)
        }
        testState = .succeeded(
            source: source,
            elapsedMilliseconds: result.elapsedMilliseconds,
            noul: result.noul
        )
    }

    /// 直接走与业务相同的 Laya 引擎抽象；测试成功代表安装清单、tokenizer、权重加载
    /// 和一次真实 batch forward 都可用，不以“文件存在”冒充 runtime 验证。
    private func testLayaModel() {
        guard layaManager.installedDirectoryURL != nil else { return }
        layaTestState = .testing
        Task {
            do {
                let engine = LayaDecisionEngine(modelManager: layaManager)
                let clock = ContinuousClock()
                let startedAt = clock.now
                let response = try await engine.evaluate(DecisionEvaluationRequest(
                    state: .text("Starcat is a native macOS application for managing GitHub stars."),
                    questions: [
                        "demo": DecisionNoulQuestion(
                            instructions: "Does this text describe a software product?",
                            criteria: nil
                        )
                    ],
                    operation: .connectionTest
                ))
                let elapsed = startedAt.duration(to: clock.now)
                let milliseconds = Int(elapsed.components.seconds) * 1_000
                    + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
                guard let noul = response.answers["demo"]?.probability else {
                    throw ConnectionProbeError.missingAnswer
                }
                layaTestState = .succeeded(
                    elapsedMilliseconds: milliseconds,
                    noul: noul
                )
            } catch is CancellationError {
                layaTestState = .idle
            } catch {
                layaTestState = .failed(error.localizedDescription)
            }
        }
    }
}
