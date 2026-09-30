//
//  LayaDecisionModelStorage.swift
//  Starcat
//
//  Laya 决策模型的共享磁盘布局与安装清单。
//
//  模型仍落在 Local AI App Group，但使用独立 `models/decision/` 子树；通用 Local AI
//  扫描器不会把它误当作用户可选的 LLM。manifest 是安装状态唯一真源，无 manifest
//  的目录只视为可续传的未完成下载。
//

import Foundation

struct LayaDecisionInstalledModel: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let revision: String
    let installedAt: Date
    let sourceKind: LocalAIModelSource.Kind
    let files: [LocalAIFileRecord]
    let totalBytes: Int64
}

enum LayaDecisionModelStorage {
    private static let manifestFileName = "laya-manifest.json"

    static func decisionRootURL(fileManager: FileManager = .default) throws -> URL {
        try LocalAIModelStorage.modelsRootURL(fileManager: fileManager)
            .appendingPathComponent("decision", isDirectory: true)
    }

    static func modelDirectory(
        revision: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try decisionRootURL(fileManager: fileManager)
            .appendingPathComponent(
                "\(LayaDecisionModelCatalog.multilingual.id)@\(revision)",
                isDirectory: true
            )
    }

    static func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent(manifestFileName)
    }

    static func save(_ manifest: LayaDecisionInstalledModel, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.prettySorted.encode(manifest)
        try data.write(to: manifestURL(in: directory), options: .atomic)
    }

    static func loadManifest(
        from directory: URL,
        fileManager: FileManager = .default
    ) throws -> LayaDecisionInstalledModel? {
        let url = manifestURL(in: directory)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder.manifest.decode(
            LayaDecisionInstalledModel.self,
            from: Data(contentsOf: url)
        )
    }

    /// 当前仅有一个固定模型；若未来升级产生多个 revision，选择最近安装且完整的一份。
    static func installedModel(
        fileManager: FileManager = .default
    ) -> (manifest: LayaDecisionInstalledModel, directory: URL)? {
        guard let root = try? decisionRootURL(fileManager: fileManager) else { return nil }
        let directories = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return directories.compactMap { directory in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let manifest = try? loadManifest(from: directory, fileManager: fileManager),
                  isInstallationValid(
                    manifest: manifest,
                    directory: directory,
                    verifyHashes: false,
                    fileManager: fileManager
                  )
            else { return nil }
            return (manifest, directory)
        }.max { lhs, rhs in
            lhs.0.installedAt < rhs.0.installedAt
        }
    }

    static func isInstallationValid(
        manifest: LayaDecisionInstalledModel,
        directory: URL,
        verifyHashes: Bool,
        fileManager: FileManager = .default
    ) -> Bool {
        let requiredNames = Set(LayaDecisionModelCatalog.multilingual.files.map(\.name))
        guard manifest.id == LayaDecisionModelCatalog.multilingual.id,
              Set(manifest.files.map(\.name)) == requiredNames
        else { return false }

        for file in manifest.files {
            let url = directory.appendingPathComponent(file.name)
            guard fileManager.fileExists(atPath: url.path),
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value == file.sizeBytes
            else { return false }
            if verifyHashes {
                guard let digest = try? LocalAIModelStorage.sha256(ofFileAt: url),
                      digest.caseInsensitiveCompare(file.sha256) == .orderedSame
                else { return false }
            }
        }
        return true
    }

    static func totalDiskUsage(fileManager: FileManager = .default) -> Int64 {
        guard let root = try? decisionRootURL(fileManager: fileManager) else { return 0 }
        return LocalAIModelStorage.directorySize(at: root, fileManager: fileManager)
    }
}
