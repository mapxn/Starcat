//
//  RepoAIInsightModels.swift
//  Starcat
//
//  单仓 AI 智能化领域模型。
//
//  模块职责：
//  - 定义详情页 AI 摘要需要展示的结构化内容；
//  - 定义 AI 标签推荐的确认单元；
//  - 作为 AI 输出 JSON 与 SwiftUI UI 之间的稳定边界。
//
//  关键约束：
//  - 字段保持小而稳定，避免第一版 prompt 输出过宽导致解析脆弱。
//  - 推荐标签只是建议，不能因为模型返回就自动落库。
//

import Foundation

struct AIExternalContext: Codable, Equatable, Sendable {
    let markdown: String
    let sources: [URL]
    var sourceItems: [AIExternalContextSource] = []
}

struct RepoAIInsight: Codable, Equatable, Sendable {
    var oneLiner: String
    var summary: String
    var summaryMarkdown: String?
    var platforms: [String]
    var suitableFor: [String]
    var strengths: [String]
    var risks: [String]
    var minimalExample: String?
    var suggestedTags: [AITagSuggestion]
    var model: String
    var generatedAt: String

    /// Y2（2026-06-13）：RepoContextPacker 生成的代码上下文元信息（可选，向后兼容）。
    ///
    /// **设计要点**：
    ///   - 旧版 RepoAIInsight 不含此字段，Codable 反序列化时为 nil；
    ///   - 不直接嵌入 `PackMetadata`：PackMetadata 含 `[SkippedFile]` 等大字段，
    ///     塞进 DB 会让 ai_summaries.summary_json 列体积暴增；
    ///   - 只挑 footer 需要的 7 个字段。
    var contextMetadata: RepoAIInsightContextMeta?

    /// Y9（2026-06-14）：摘要生成时 AnySearch 拉取的外部材料（已格式化为 markdown）。
    ///
    /// **为什么放在 Insight 里**：
    ///   - **零 schema migration**（决议 F=f2b）：作为 Codable 可选字段塞进
    ///     `summaryJson` 列，老缓存 JSON 缺该字段时反序列化为 nil，向后完全兼容；
    ///   - **复用缓存生命周期**：与摘要正文同生同灭——`cacheModelKey` 编码了
    ///     `external:on/off` 状态，settings 翻转后会自动失效；
    ///   - **对话路径零 HTTP**（决议 B=b2）：`chatStream` 读 `cachedInsight` 时
    ///     一并拿到 markdown，免去重复调 AnySearch API 烧配额。
    ///
    /// **内容形态**：直接存 `ExternalSearchContextProvider.collect()` 产出的整段
    /// `<external_context source="Exa">...</external_context>` 或
    /// `<external_context source="Aggregate">...</external_context>` 块。
    /// 长度上限：6 条 × 500 字 ≈ 3KB，对 SQLite TEXT 列无压力。
    ///
    /// **不与 summaryMarkdown 末尾的"## 外部参考来源"段冲突**：
    ///   - `summaryMarkdown` 末尾仅有链接列表（无 snippet），给"摘要面板渲染"使用；
    ///   - 本字段保留完整 snippet，给"对话 system prompt 注入"使用；
    ///   - 两份数据来源同一次 collect 调用，无内容漂移风险。
    var externalContextMarkdown: String?

    /// External Context Sources 的轻量元数据。
    ///
    /// 只保存 UI 展示所需的 title / URL / host / provider / fetchedAt，不保存
    /// `extractedText` 或 snippet，避免把第三方网页正文长期塞进 AI 摘要缓存。
    var externalContextSources: [AIExternalContextSource]? = nil

    /// Y9.1（2026-06-14）：摘要生成时的上下文配置快照。
    ///
    /// 字段继续保留以维持既有摘要缓存的序列化结构，但界面不再将它与当前设置比较，
    /// 也不会再因为用户切换代码上下文或外部搜索配置而提示重新生成。
    var generationContextSettings: GenerationContextSettings?
}

/// Y9.1（2026-06-14）：摘要生成时写入既有缓存的上下文配置快照。
struct GenerationContextSettings: Codable, Equatable, Sendable {
    /// 生成时用户是否想要代码上下文（本次覆盖或当时的全局开关）。
    var codeContextEnabled: Bool

    /// 生成时 External Search 外部材料**最终是否被允许**（开关 + 私仓门控的 effective 结果）。
    /// 等价于 `ExternalSearchContextProvider.allowsExternalContext(...)` 在生成那一刻的返回值。
    var externalContextAllowed: Bool
}

struct AIExternalContextSource: Codable, Identifiable, Equatable, Sendable {
    var title: String
    var url: URL
    var host: String
    var provider: ExternalSearchProviderID
    var fetchedAt: String

    var id: String { "\(provider.rawValue):\(url.absoluteString)" }
}

/// Y2：UI footer 显示的代码上下文元信息（PackMetadata 的精简投影）。
struct RepoAIInsightContextMeta: Codable, Equatable, Sendable {
    /// 完整 commit SHA（40 字符）
    var commitSha: String

    /// 分支或 tag（如 `main`）
    var ref: String

    /// 用户设定的 token 上限（来自 settings.aiRepoContextTokenBudget）
    var tokenBudget: Int

    /// 实际消耗的 token 数（基于 char count 估算）
    var actualTokens: Int

    /// 进入 XML 的文件总数（Tier 0 + Tier 1 + Tier 2 截断后保留路径数）
    var totalFiles: Int

    /// Packer 生成时刻 ISO-8601（与 PackMetadata.generatedAt 同源）
    var generatedAt: String

    /// 短 commit SHA（7 字符）—— UI 显示用，避免每次自己 prefix(7)
    var commitShaShort: String { String(commitSha.prefix(7)) }
}

/// 标签建议实际由哪类引擎产生。
///
/// Jev 与 LLM 可能在同一次任务中各自产出一部分建议，因此来源必须随单条建议持久化，
/// 不能只记录在任务级状态上。
enum AITagSuggestionEngine: String, Codable, Equatable, Sendable {
    case jev
    case llm
}

struct AITagSuggestion: Codable, Identifiable, Equatable, Sendable {
    var name: String
    var confidence: Double
    var reason: String
    /// 可选是为了兼容 1.9.0 之前已持久化、尚未确认的批量整理草稿。
    /// 新生成结果必须在可信的 Jev / LLM 调用边界显式写入，不能采信模型自报来源。
    var engine: AITagSuggestionEngine? = nil

    var id: String { name.localizedLowercase }
}

/// 每仓库 AI 标签推荐数量区间（设置页 / 批量整理窗口 / 提示词占位符共用）。
///
/// 默认 1…3，与「复用优先、Untagged 禁空」策略一致；上限钳到 8，避免一次推荐过多
/// 淹没审核列表。真正截断仍由 `AITagSuggestionPolicy.normalizedSuggestions` 执行。
enum AITagSuggestionCountPolicy {
    static let allowedRange = 1...8
    static let defaultMinimum = 1
    static let defaultMaximum = 3

    /// 钳制后保证 `minimum ≤ maximum`，且都落在 `allowedRange`。
    static func clamp(minimum: Int, maximum: Int) -> (minimum: Int, maximum: Int) {
        let loBound = allowedRange.lowerBound
        let hiBound = allowedRange.upperBound
        let hi = min(max(maximum, loBound), hiBound)
        var lo = min(max(minimum, loBound), hiBound)
        if lo > hi { lo = hi }
        return (lo, hi)
    }

    /// 摘要卡与设置旁路展示用的 en-dash 区间，例如 `1–3`。
    static func displayRange(minimum: Int, maximum: Int) -> String {
        let clamped = clamp(minimum: minimum, maximum: maximum)
        return "\(clamped.minimum)–\(clamped.maximum)"
    }
}

/// 批量标签模型在当前请求中的单一职责。
///
/// Jev 已经完成现有词表筛选后，LLM 只能补充一个词表外的新标签，不能重新选择
/// 被 Jev 判定为不匹配的旧标签。显式建模用途，避免靠清空词表等隐式参数改变 Prompt 语义。
enum AITagSuggestionPurpose: Equatable, Sendable {
    case reuseFirst
    case newOnly
}

/// 一次标签生成请求的业务策略。
///
/// JEV 只负责给现有标签打分；是否允许在现有标签不足时调用 LLM 创建新概念，必须由
/// 发起场景显式决定。`minimumReusableConfidence` 只参与“现有标签是否已经足够”的判断，
/// 不会在这里丢弃低分建议，最终展示或自动应用仍由各自界面的阈值策略负责。
struct AITagGenerationPolicy: Equatable, Sendable {
    var allowNewTags: Bool
    var minimumReusableConfidence: Double

    /// 单仓面板由用户逐项确认，允许在词表不足时补一个新标签。
    static let manualReview = AITagGenerationPolicy(
        allowNewTags: true,
        minimumReusableConfidence: 0
    )

    init(allowNewTags: Bool, minimumReusableConfidence: Double) {
        self.allowNewTags = allowNewTags
        self.minimumReusableConfidence = min(max(minimumReusableConfidence, 0), 1)
    }
}

/// AI 标签名的本地收敛策略。
///
/// Prompt 只能提高模型遵守规则的概率，不能充当数据完整性边界；尤其不同 Provider 可能
/// 继续返回 8 个结果、越界置信度，或把 `Open-Source` 改写成 `open source`。因此生成结果
/// 在进入 UI / 批量自动应用前必须再经过本地确定性规则：复用已有标准拼写、同义形式去重、
/// 按配置截断总数且最多 1 个真正的新标签。
enum AITagSuggestionPolicy {
    static let maximumNewTagCount = 1

    /// 兼容旧调用与单测：未显式传上限时用产品默认最大值。
    static var maximumSuggestionCount: Int { AITagSuggestionCountPolicy.defaultMaximum }

    /// 只整理不可见的首尾 / 连续空白，不擅自改变用户标签的展示拼写。
    static func normalizedDisplayName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// 用于 AI 推荐避重的宽松 identity，不用于数据库全局唯一约束。
    ///
    /// 大小写、宽度、音标、空白、`-`、`_` 的差异不应让 AI 新建标签；但保留 `+`、`.`、
    /// `/` 等技术名称有意义的字符，避免把 `C` / `C++` 或 `Vue` / `Vue.js` 错误合并。
    static func canonicalKey(_ raw: String) -> String {
        let normalized = normalizedDisplayName(raw).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let ignored = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "-_")
        )
        return String(normalized.unicodeScalars.filter { !ignored.contains($0) })
    }

    /// 把模型输出收敛为可展示、可应用的稳定结果。
    ///
    /// `vocabulary` 必须按产品优先级排序：当前 repo 标签在前，其余全库标签按使用频率
    /// 降序在后。多个历史标签落到同一 canonical key 时保留第一个，从而优先沿用当前
    /// repo 已有拼写，否则选择全库更常用的拼写。
    ///
    /// `maximumSuggestionCount` 来自设置页区间的最大值；调用方应先 clamp。
    static func normalizedSuggestions(
        _ suggestions: [AITagSuggestion],
        vocabulary: [String],
        maximumSuggestionCount: Int = AITagSuggestionCountPolicy.defaultMaximum
    ) -> [AITagSuggestion] {
        let limit = max(1, maximumSuggestionCount)
        var existingNameByKey: [String: String] = [:]
        for rawName in vocabulary {
            let name = normalizedDisplayName(rawName)
            let key = canonicalKey(name)
            guard !name.isEmpty, !key.isEmpty, existingNameByKey[key] == nil else { continue }
            existingNameByKey[key] = name
        }

        var existingResults: [AITagSuggestion] = []
        var newResults: [AITagSuggestion] = []
        var seenKeys: Set<String> = []

        for suggestion in suggestions {
            guard suggestion.confidence.isFinite,
                  (0.0...1.0).contains(suggestion.confidence)
            else { continue }

            let proposedName = normalizedDisplayName(suggestion.name)
            let key = canonicalKey(proposedName)
            guard !proposedName.isEmpty, !key.isEmpty, !seenKeys.contains(key) else { continue }

            let normalizedSuggestion: AITagSuggestion
            if let existingName = existingNameByKey[key] {
                normalizedSuggestion = AITagSuggestion(
                    name: existingName,
                    confidence: suggestion.confidence,
                    reason: suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines),
                    engine: suggestion.engine
                )
                existingResults.append(normalizedSuggestion)
            } else {
                guard newResults.count < maximumNewTagCount else { continue }
                normalizedSuggestion = AITagSuggestion(
                    name: proposedName,
                    confidence: suggestion.confidence,
                    reason: suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines),
                    engine: suggestion.engine
                )
                newResults.append(normalizedSuggestion)
            }

            seenKeys.insert(key)
        }
        // 选哪些标签仍由词表复用 + 新标签配额决定；展示顺序按置信度从高到低，
        // 避免模型乱序或「已有标签在前」让高置信度项沉到列表下面。
        return sortedByConfidenceDescending(
            Array((existingResults + newResults).prefix(limit))
        )
    }

    /// 同分保持输入相对顺序，避免刷新时行位置跳动。
    static func sortedByConfidenceDescending(_ suggestions: [AITagSuggestion]) -> [AITagSuggestion] {
        suggestions.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.confidence != rhs.element.confidence {
                    return lhs.element.confidence > rhs.element.confidence
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

/// AI 标签生成的"已有标签"提示，分两层语义传递给 prompt。
///
/// **为什么不用扁平 `[String]`**：
/// service 层无法区分"哪些是 repo 已绑定的（强信号，应优先复用避免重复打）"
/// 与"哪些是用户标签库里其它常用项（弱信号，作为风格参考）"。
/// 扁平数组下 prompt 只能写一句"优先复用"，LLM 对 repo 自身已有标签
/// 的避重感知会被全局标签稀释，容易生成「向量搜索 / Vector Search / 向量检索」
/// 这种同义不同名标签让标签库爆炸。
///
/// **设计约束**：
/// - 两个数组都已**去重 + 排序 + 字符预算截断**完成（由 `RepoAIInsightService.makeTagHints`
///   工厂方法统一生成）；service 层不再做二次处理；
/// - 排序保证 deterministic：同一份输入 → 同一份 source.hash → AI 摘要缓存稳定命中，
///   避免 `Set → Array` 顺序不稳导致缓存频繁失效；
/// - `repoTags` 与 `libraryTags` 互斥：`libraryTags` 工厂方法构造时已去掉 `repoTags`
///   里的元素，避免同一标签在 prompt 里出现两次（占字符 + 信号矛盾）；
/// - 任一数组为空时只把对应占位符渲染为空字符串；label 保留，便于用户在 Settings
///   理解模板结构与可用变量。
struct AITagHints: Sendable, Equatable {

    /// 当前 repo 已绑定的标签名（强信号，AI 必须优先复用避免同义重复）。
    /// 列表全部传，不截断——单个 repo 标签数量普遍 ≤10，prompt 占用可控。
    var repoTags: [String]

    /// 用户标签库里其它标签名（首选复用词表，而非仅作风格参考）。
    /// 已去掉 `repoTags` 里的元素，并按使用次数倒序填充到约定字符预算。
    var libraryTags: [String]

    static let empty = AITagHints(repoTags: [], libraryTags: [])

    var isEmpty: Bool { repoTags.isEmpty && libraryTags.isEmpty }
}
