//
//  AppStoreToDirectImportCopyService.swift
//  Starcat
//
//  把 App Store 正式容器里的文件树拷到 Direct 对应位置。
//
//  为什么先整树进 staging 再替换：中途失败必须让 Direct 目录保持原样，
//  否则下次启动会因为「已经有残缺库」而不再弹出导入。
//

import Foundation

enum AppStoreToDirectImportError: Error, Equatable, LocalizedError {
    case storeAppRunning
    case storeDataUnreadable
    case copyFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .storeAppRunning:
            return String.l10n("launch.directImport.error.storeRunning")
        case .storeDataUnreadable:
            return String.l10n("launch.directImport.error.storeUnreadable")
        case .copyFailed(let message):
            return String(format: String.l10n("launch.directImport.error.failedFormat"), message)
        }
    }
}

struct AppStoreToDirectImportCopyService {
    var layout: AppStoreToDirectImportLayout
    var fileManager: FileManager
    var processInspector: any AppStoreToDirectImportProcessInspecting
    var destinationDefaults: UserDefaults

    init(
        layout: AppStoreToDirectImportLayout,
        fileManager: FileManager = .default,
        processInspector: any AppStoreToDirectImportProcessInspecting = LaunchServicesAppStoreProcessInspector(),
        destinationDefaults: UserDefaults = .standard
    ) {
        self.layout = layout
        self.fileManager = fileManager
        self.processInspector = processInspector
        self.destinationDefaults = destinationDefaults
    }

    func copyConfirmedData() throws {
        if processInspector.isAppStoreStarcatRunning() {
            throw AppStoreToDirectImportError.storeAppRunning
        }
        do {
            try copyStagedFiles()
            migratePreferences()
        } catch let error as AppStoreToDirectImportError {
            throw error
        } catch {
            throw AppStoreToDirectImportError.copyFailed(message: error.localizedDescription)
        }
    }

    /// 只做文件拷贝，不碰 UserDefaults。启动期可以丢到后台线程，避免卡死 splash 后的确认层。
    func copyStagedFiles() throws {
        let stagingRoot = layout.directApplicationSupportRoot.appendingPathComponent(
            ".starcat-appstore-import-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        // 旧模型由 LocalAISharedModelCoordinator 校验后迁入 App Group。首次数据导入
        // 不能再把数 GB 模型复制进 Direct 私有目录，否则会制造第三份副本。
        try stageExistingDirectory(
            layout.storeStarcatAppSupport,
            as: "app-support",
            under: stagingRoot,
            excludedTopLevelNames: ["models"])
        try stageExistingDirectory(layout.storeProductSupport, as: "product-support", under: stagingRoot)
        try stageExistingDirectory(layout.storeKingfisherCache, as: "kingfisher", under: stagingRoot)
        // Direct 没有 `group.com.starcat.app.store.widgets` entitlement。
        // 组容器目录看得见，但一打开就 TCC 拒绝；Widget 快照丢了可以接受，不能阻断主库。
        try stageExistingDirectory(
            layout.storeWidgetGroup,
            as: "widgets",
            under: stagingRoot,
            isOptional: true
        )

        let stagedAppSupport = stagingRoot.appendingPathComponent("app-support", isDirectory: true)
        guard AppStoreToDirectImportEvaluator.containsReadableStoreUserData(
            at: stagedAppSupport,
            fileManager: fileManager
        ) else {
            throw AppStoreToDirectImportError.storeDataUnreadable
        }

        try commitStagedDirectory("app-support", under: stagingRoot, to: layout.directStarcatAppSupport)
        try commitStagedDirectory("product-support", under: stagingRoot, to: layout.directProductSupport)
        try commitStagedDirectory("kingfisher", under: stagingRoot, to: layout.directKingfisherCache)
        try commitStagedDirectory("widgets", under: stagingRoot, to: layout.directWidgetGroup)
    }

    /// 后台线程入口：在闭包内新建 FileManager，避免把 App 主线程的 FileManager 跨隔离域传递。
    static func copyStagedFiles(layout: AppStoreToDirectImportLayout) throws {
        do {
            try AppStoreToDirectImportCopyService(
                layout: layout,
                fileManager: FileManager(),
                processInspector: IdleAppStoreProcessInspector(),
                destinationDefaults: UserDefaults(suiteName: "starcat.direct-import.background") ?? .standard
            ).copyStagedFiles()
        } catch let error as AppStoreToDirectImportError {
            throw error
        } catch {
            throw AppStoreToDirectImportError.copyFailed(message: error.localizedDescription)
        }
    }

    /// StoreKit / Sparkle / 本次导入决策不能带进 Direct。
    static func shouldMigratePreferenceKey(_ key: String) -> Bool {
        if key == AppSettings.Keys.isProUser { return false }
        if key == AppStoreToDirectImportIdentity.decisionDefaultsKey { return false }
        if key.hasPrefix("SU") { return false }
        let lowered = key.lowercased()
        if lowered.contains("storekit") { return false }
        if lowered.contains("transaction") { return false }
        return true
    }

    private func stageExistingDirectory(
        _ source: URL,
        as name: String,
        under stagingRoot: URL,
        isOptional: Bool = false,
        excludedTopLevelNames: Set<String> = []
    ) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        do {
            let destination = stagingRoot.appendingPathComponent(name, isDirectory: true)
            try copyTreeSkippingTemporaryFiles(
                from: source,
                to: destination,
                excludedNames: excludedTopLevelNames)
        } catch {
            if isOptional {
                AppLog.general.warning(
                    "Skip optional App Store import source \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return
            }
            throw error
        }
    }

    private func commitStagedDirectory(_ name: String, under stagingRoot: URL, to destination: URL) throws {
        let staged = stagingRoot.appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(atPath: staged.path) else { return }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
    }

    func migratePreferencesForCurrentLayout() {
        migratePreferences()
    }

    private func migratePreferences() {
        guard let raw = NSDictionary(contentsOf: layout.storePreferencesPlist) as? [String: Any] else {
            return
        }
        for (key, value) in raw where Self.shouldMigratePreferenceKey(key) {
            destinationDefaults.set(value, forKey: key)
        }
    }

    private func copyTreeSkippingTemporaryFiles(
        from source: URL,
        to destination: URL,
        excludedNames: Set<String> = []
    ) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let items = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for item in items {
            if excludedNames.contains(item.lastPathComponent) { continue }
            if Self.shouldSkipCopying(item) { continue }
            let childDestination = destination.appendingPathComponent(item.lastPathComponent)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                // 排除项只作用于本次 source 根层；子目录里同名的普通业务目录照常复制。
                try copyTreeSkippingTemporaryFiles(from: item, to: childDestination)
            } else {
                try fileManager.copyItem(at: item, to: childDestination)
            }
        }
    }

    static func shouldSkipCopying(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == ".DS_Store" { return true }
        if name.hasPrefix(".") && name != "credentials.json" { return true }
        return name.hasSuffix(".tmp")
    }
}
