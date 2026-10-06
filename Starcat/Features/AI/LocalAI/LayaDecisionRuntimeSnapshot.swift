//
//  LayaDecisionRuntimeSnapshot.swift
//  Starcat
//
//  Laya 决策模型的只读运行时快照。磁盘安装状态仍由
//  LayaDecisionModelManager 管理，不能用“已下载”冒充“已驻留”。
//

import Foundation

/// 跨 actor 传给状态面板的轻量值；不得持有 runtime、张量或文件锁。
struct LayaDecisionRuntimeSnapshot: Sendable {
    var model: LocalAIResidentModel?
    /// MLX 一旦初始化便可安全读取进程级内存统计；卸载模型不会把 Metal 运行时反初始化。
    var isMLXInitialized = false
    var queuedCount = 0
}
