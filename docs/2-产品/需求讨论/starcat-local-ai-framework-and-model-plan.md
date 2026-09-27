# Starcat Local AI 方案（v1.1 · 按 Starcat 现状修订）

> 目标：Starcat 内置进程内本地 AI 推理（MLX），模型按需下载；下载校验完成后，本地模型作为普通 AI 服务商模型供各 AI 任务选用，全程不需要远程 AI API。
>
> **修订说明（2026-09-12，v1.0 → v1.1）**
> v1.0 是在不了解 Starcat 实现的前提下写的外部方案。v1.1 结合当前代码现状修订：
> - **只保留 v1.0 的两项设计**：MLX 框架选型（MLX Swift LM）与默认模型组合（Qwen3 三件套）。
> - **接入方式全部重写**：不再自建 `LLMProvider / EmbeddingProvider / RerankerProvider` 协议族与独立 Local AI 设置页，而是作为 `AIServiceProvider` 的一个新 case，接入现有 AI 服务商体系与任务级模型配置。
> - 模型下载、存储、Catalog、数据库、门控、测试均改为遵循 Starcat 现有代码逻辑与规范。
>
> **dong4j 已拍板的决策（2026-09-12）**
> 1. 本地 AI **免费**，不做 Pro 订阅门控。
> 2. 本地 AI 作为 **AI 服务商**接入：用户选择「本地 AI」服务商 → 展示若干模型的下载配置 → 下载验证后即可正常使用；不改动现有 AI 服务商的后续配置与逻辑，只做必要适配。

---

## 1. 定位与用户路径

本地 AI = **第 25 个 AI 服务商 case（`AIServiceProvider.localAI`）**，进程内 MLX 推理：无 API Key、无 Base URL、无网络请求（模型下载除外）。它与 ollama / lmStudio（外部本地 HTTP 服务）并存但不同：`localAI` 不要求用户安装任何第三方软件。

用户路径（全部复用现有 AI 设置交互）：

```text
AI 设置 → 服务商列表新增「Starcat Local AI」→ 选中
  → 出现模型管理区（Embedding / Reranker / LLM 三类模型的下载卡片）
  → 下载 + 校验完成 → 模型自动登记进该 profile 的模型列表
  → 「模型配置」区的 摘要 / 标签 / 对话 / 向量化 任务照常选择本地模型
  → 摘要、标签、对话（流式）、语义搜索、知识库 RAG 全链路可用
```

不引入的东西（明确排除）：

- 不新增独立的「Local AI」设置 Tab（`SettingsTab` 不加 case），一切挂在 AI 服务设置页内。
- 不自建 Provider 协议族，不改 `AIModelTask` 任务枚举。
- v1 不做客户端模型转换（PyTorch/safetensors → MLX），只消费已转换好的 MLX 权重。

---

## 2. MLX 框架选型（保留 v1.0 结论）

**选择：MLX Swift LM（`ml-explore/mlx-swift-lm`）**。

- 已核实：`MLXLMCommon` / `MLXLLM` / `MLXVLM` / `MLXEmbedders` 已从 `mlx-swift-examples` 迁入该独立库，Qwen3 embedding 已有官方 Swift 支持（examples PR #402）。
- Swift 原生、Metal / Apple Silicon 优化、`mlx-community` 模型生态充足。
- 后续可扩展 `MLXGuidedGeneration`（结构化输出）或 llama.cpp/GGUF Provider，但 v1 不做。

**Starcat 化修正（v1.0 → v1.1 的关键变化）**：业务代码本来就不该绑定 MLX，而且 Starcat **已经有**这层抽象，不需要新造：

| v1.0 设想 | Starcat 现状（复用对象） |
|---|---|
| `LLMProvider` 协议 + `LocalMLXProvider` | `AITextGenerating` / `AIClientProtocol`（`Starcat/Features/AI/AIClient.swift`），`chat` / `chatStream` / `embeddings` / `listModels` / `testConnection` 全齐；`AIClient.swift` 头注释已预留「Apple 本地模型只需替换 adapter」的意图 |
| `RerankerProvider` + 从零封装 | `RAGReranking` 协议（`Starcat/Features/RAG/Core/RAGSearchProviders.swift`），已有 TEI / Cohere 两个远程实现与 `RAGRerankConfiguration` 装配点，本地 Reranker 只是第三个实现 |
| 非 HTTP 后端如何接入？ | `RAGCLIModelClient` 是现成先例：只实现 `AITextGenerating`、在装配边界接入，业务层零改动 |

本地实现清单：

```text
Starcat/Features/AI/LocalAI/
├── LocalAIModelCatalog.swift      # 内置模型目录（编译期常量）
├── LocalAIModelManager.swift      # 下载/校验/删除/安装状态（actor）
├── LocalAIModelDownloader.swift   # 断点续传 + SHA256 + 磁盘检查
├── LocalAIModelStorage.swift      # 目录布局 + manifest.json 读写
├── LocalMLXRuntime.swift          # 单 actor 串行 GPU 推理 + 模型懒加载/LRU 卸载
└── LocalMLXClient.swift           # 实现 AIClientProtocol 的适配层
Starcat/Features/RAG/Core/
└── LocalMLXRAGReranker.swift      # 实现 RAGReranking
```

---

## 3. 默认模型设计（保留 v1.0 结论 + Spike 决策点）

完整链路不变：`Embedding → 向量召回 Top N → (可选) Reranker 精排 Top K → LLM 生成`。

### 3.1 推荐组合

| 类型 | 默认模型 | 定位 | 大小 | 备注 |
|---|---|---|---|---|
| Embedding | `mlx-community/Qwen3-Embedding-0.6B-8bit` | 默认，语义搜索 / RAG 召回 | ~633 MB | 1024 维，上下文 32K，中英技术文本好 |
| Reranker | `mlx-community/Qwen3-Reranker-0.6B-mxfp8` | RAG 精排（**默认关闭**） | ~615 MB | 与 Qwen3 体系统一；见 3.2 风险 |
| LLM | `mlx-community/Qwen3-4B-Instruct-2507-4bit` | 默认，摘要 / 笔记 / 标签 / 对话 / RAG 回答 | ~2.3 GB | 长文本总结与指令遵循的可用性下限 |
| LLM Lite | `mlx-community/Qwen3-1.7B-4bit` | 标签 / 分类 / 短摘要 / 低内存设备 | ~1 GB | |

选 4B 的理由（v1.0 结论保留）：真实输入是 README + 元数据 + Release + 笔记 + RAG chunks，涉及提取、压缩、分类和一定推理；过小模型在长文本总结、指令遵循与输出稳定性上明显下降。

### 3.2 Spike 必须验证的点（M0，见 §11.1）

模型定稿以 spike 结论为准，以下均为**已核实的风险**：

- **R1 Embedding 维度 bug**：`mlx-swift-lm` issue #36 报告加载 Qwen3-Embedding 转换模型输出 **16384 维而非 1024 维**（pooling 实现）。spike 必须确认 8bit 版本输出维度正确、query / document 两侧相似度 sanity 通过（Qwen3-Embedding 官方用法对 query 侧有 instruct prompt，与 document 非对称——v1 可统一不加 instruct，质量略降可接受，spike 时对比）。
- **R2 Reranker mxfp8 权重用法存疑**：HF 模型卡显示该权重由 `mlx-embeddings 0.0.3` 转换，示例用法是「归一化 embedding + matmul 相似度」，**不是** Qwen3 官方 reranker 的判别式（yes/no logits）用法；且无任何硬件兼容性说明。spike 需验证 Swift 端能否加载、判别式 rerank 是否可行、**M1/M2 芯片上 mxfp8 kernel 是否可用**。不达标即启用备选：`Qwen3-Reranker-0.6B-4bit`（需确认 mlx-community 存在）或 bf16。
- **R3 内存预算**：三模型权重合计 ~3.5 GB。策略：Embedding + 当前任务 LLM 按需加载，Reranker 用完即卸；全部推理走单一 actor 串行；加载前检查 MLX memory limit。

### 3.3 模型标识与索引兼容（Starcat 化设计）

本地模型在现有向量体系中的标识：**把 revision 编进 `model` 字符串**，例如：

```text
local/qwen3-embedding-0.6b-8bit@<short-sha>
```

- `repo_embeddings` 表主键本就是 `(repo_id, model)`，`rag_chunks` 已有 `embedding_model / embedding_dim / embedding_status` 列 → **换模型 = 换 model 串，旧向量自然失效，天然获得「不兼容 → 提示 Re-index」能力，v1 零迁移**（见 §9）。
- 下发到 `AIProviderProfile.models` 的模型名即 catalog 中的稳定名（如 `Qwen3-Embedding-0.6B-8bit`），revision 由 ModelManager 在底层解析，用户不感知。

---

## 4. 接入设计：`AIServiceProvider.localAI`

### 4.1 枚举扩展清单

`AIServiceProvider`（`Starcat/Core/Settings/AppSettings.swift`）枚举文档注释列了硬性清单，逐项落值：

| 清单项 | `localAI` 取值 | 说明 |
|---|---|---|
| rawValue | `localAI` | 追加在枚举尾部（`orcaRouter` 之后），不改已有 rawValue |
| `displayName` | `ai.provider.localai`（LocalizedStringKey） | 「Starcat Local AI」 |
| `iconAssetName` | `localai` | `Resources/Assets.xcassets/AIProviders/` 新建 imageset；上游无品牌资源，用自绘矢量，缺资源时走 fallback |
| `fallbackSystemImageName` | `cpu` | |
| `iconIsMonochromeWhite` | 按实际资源定 | 自绘资源若为单色模板则 `true` |
| `defaultBaseURL` | `""` | 本地无端点；该字段对 localAI 不使用 |
| `defaultChatModel` | `Qwen3-4B-Instruct-2507-4bit` | 占位提示；真实可用列表来自 profile.models 注入 |
| `defaultEmbeddingModel` | `Qwen3-Embedding-0.6B-8bit` | 同上 |
| `supportsEmbeddingEndpoint` | **`true`** | 本地有真实 embedding 能力（与 orcaRouter 相反） |
| `allowsEmptyAPIKey`（`AIConfiguration.swift`） | **`true`**（加入 `.ollama, .lmStudio` 同组） | `fallbackAPIKey` 已有 `"local-ai"` 惯例自动生效 |
| `defaultProfileName`（`AIConfiguration.swift`） | `"Starcat Local AI"` | |

### 4.2 内置 Profile（关键适配点）

现有 selection 解析（`resolveChatSelection` / `resolveEmbeddingSelection`）只卡两件事：profile 存在 + `profile.isVerifiedConfiguration`；注释已明确「本地 Provider 可以合法地没有 Key」。因此最小适配是**注入一个内置固定 profile**：

- 固定 id：`built-in.local-ai`，provider `.localAI`，启动时 seed-if-missing 进 `aiProviderProfiles`；设置页对该 profile 隐藏「删除」，Base URL / Key 输入区对 localAI 隐藏。
- **`isVerifiedConfiguration` 语义**：实现期确认 `AIProviderProfile` 中该属性的存储形态后取最小适配——推荐对 localAI 改为计算属性：catalog 必需模型（按任务用途）已安装且 manifest 校验通过 → `true`。
- **模型列表注入**：模型安装/删除时，把已安装模型以 `AIModelDescriptor`（name + capability：LLM → `.chat`，Embedding → `.embedding`，Reranker → `.rerank`）写入内置 profile 的 `models`。这样下游**全部自动工作**：
  - 任务模型区的 `enabledModels(providerID:capability:)` 过滤 → 任务 picker 自然出现本地模型；
  - `resolveChatSelection` 的 capability 校验自然拦截「拿 embedding 模型跑对话」；
  - `hasConfiguredChatModel`（`AIWorkspaceEntryGate` 依赖）在本地模型齐备后自动为 `true`。
- `testConnection()` 对 localAI = 本地完整性检查（manifest 存在 + 文件校验），不联网；设置页「测试并获取模型」按钮对 localAI 变体为「检查本地模型」。

### 4.3 `LocalMLXClient`（实现 `AIClientProtocol`）

```text
chat(request:) / chatStream(request:)  → MLXLLM 生成；chatStream 产出
                                          AIChatStreamEvent(.delta/.completed/.usage)，
                                          天然接入现有两条流式管道：
                                          对话（RepoAIChatViewModel）与
                                          RAG（KnowledgeRAGService 8Hz 节流）
embeddings(inputs:model:)              → MLXEmbedders 批量推理（内部分批）
embedding(input:model:)                → 单条（query 向量）
listModels()                           → 内置 profile.models（同步 catalog）
testConnection()                       → 本地完整性检查
```

- 生成参数映射：`AIModelParameters`（temperature / topP / topK / maxCompletionTokens / streamEnabled）→ MLX 采样参数；`resolvedContextWindowTokens` 沿用。
- 所有 MLX 调用转发给 `LocalMLXRuntime`（单 actor 串行），client 本身无状态。

**客户端工厂分支**：M1 第一步 `rg "OpenAIClient("` 盘点全部构造点（已知：`RepoAIInsightService.makeClient`、`KnowledgeRAGIndexBuilder` 的 embedding client、`SemanticSearchService`、笔记生成、翻译、批量队列），统一加 `.localAI` 分支返回 `LocalMLXClient`；只加分支，不顺手重构。

### 4.4 Reranker 接入（遵循现有 RAG 配置逻辑）

- `LocalMLXRAGReranker` 实现 `RAGReranking`（`rerank(query:candidates:)` → 逐对 query-document 推理打分）。
- `RAGRerankConfiguration.provider`（`Features/RAG/Core/RAGBackendConfiguration.swift`）加 `.localMLX` case，装配点在 `AppDependencies.swift` 现有 RAG rerank 装配处。
- **保持默认关闭**，与 TEI/Cohere 同等待遇；用户在 RAG 检索设置里显式开启。Reranker 模型卡片未下载时，该选项置灰并引导下载。
- 不做「下载即全链路启用」——v1.0 设想废止，遵循现有 RAG 检索链路配置（hybrid 双路 + RRF 融合 + 可选 rerank）。

---

## 5. 模型管理

### 5.1 Catalog（内置常量，用户不填 Repo ID）

```swift
struct LocalAIModelCatalogEntry {
    let id: String                    // "qwen3-embedding-0.6b-8bit"
    let displayName: String
    let type: LocalAIModelType        // .embedding / .reranker / .llm
    let capability: AIModelCapability // 对齐现有枚举（.embedding/.chat/.rerank）
    let recommended: Bool             // UI 只暴露 Lite / Recommended 两档
    let estimatedDownloadSize: Int64
    let memoryRecommendation: UInt64  // 安装前内存提示
    let contextLength: Int?
    let embeddingDimension: Int?      // embedding 专用，写进向量元数据
    let sources: [LocalAIModelSource] // huggingFace / modelScope（repo + revision + sha256）
}
```

- v1 目录 = §3.1 表格四项，硬编码在 `LocalAIModelCatalog.swift`，每个 entry 必须带 revision（commit SHA）与文件 SHA256。
- UI 只暴露「Lite / 推荐」，不暴露 FP16/4bit/8bit/MXFP8 概念（v1.0 原则保留）。

### 5.2 下载源

- **Hugging Face 为 v1 主源**：`resolve` 端点按 revision 拉取文件，`mlx-community` 仓库。
- **ModelScope 为白名单源（M5）**：只支持 catalog 中逐个登记且人工验证过镜像存在、revision 一致的仓库；白名单外的模型在 ModelScope 源下显示「该源暂不可用」。**禁止**切源时静默变更 revision / 量化 / 文件集——切源后必须校验 SHA256 一致，不一致报错并回退。
- 下载源设置项挂在本地 AI 模型管理区内（`Auto / Hugging Face / ModelScope` Picker），v1 的 Auto = 优先 HF，失败提示手动切源（不做自动探测切换，减少「静默换源」风险面）。

### 5.3 `LocalAIModelDownloader`（actor，补齐现有下载器缺口）

以 `Core/Download/ReleaseAssetDownloader.swift` 为底（downloadTask + Progress KVO + 临时文件 move），补三样全仓缺失的能力：

1. **断点续传**：HTTP Range + `.part` 临时文件；失败恢复后续传。
2. **完整性校验**：SHA256（CryptoKit）对照 catalog。
3. **磁盘空间检查**：`volumeAvailableCapacity` 预检 + 下载中复查，不足时明确报错。

约束：全局并发 1（顺序下载），失败自动重试 3 次（指数退避），支持暂停/取消/恢复。

### 5.4 存储布局（机器级资源，不进 per-user 数据库）

```text
~/Library/Group Containers/8WCUMGCWMB.com.starcat.app.localai/
└── Library/Application Support/Starcat/LocalAI/v1/
    ├── locks/             # 跨进程 flock 文件，与可删除模型目录分离
    └── models/
        ├── embedding/qwen3-embedding-0.6b-8bit@<revision>/
        │   ├── model.safetensors
        │   ├── config.json / tokenizer.json / ...
        │   └── manifest.json  # id/revision/sha256/size/installedAt/source
        ├── reranker/...
        └── llm/...
```

- 路径通过 `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` 解析，App Store 与 Direct 主应用共用 Team ID App Group；Widget、屏保与辅助二进制不授予该组权限。
- 旧版私有 `Application Support/com.starcat.app/models/` 在首次启动时迁移：源文件通过 manifest、大小与 SHA256 校验后才移动；共享目录已有同内容模型时删除已验证重复副本，冲突或残缺目录保留原处。
- `manifest.json` 是安装状态单一真源；启动时扫描目录重建安装列表，容忍脏目录（无 manifest 的目录视为未完成下载，可清理）。
- 推理持有跨进程共享锁，下载与单模型删除持有模型独占锁，迁移与全部清除持有全局独占锁；避免两个渠道同时运行时删除 mmap 权重或混写 `.part`。
- 管理动作：单模型删除（确认弹窗）、全部清除、在 Finder 中显示；存储占用统计复用 `Core/Cache/CacheCleaner.swift` 模式。

### 5.5 `LocalMLXRuntime`（GPU 串行与内存策略）

- **单一 actor**：所有推理（embedding 批量 / LLM 生成 / rerank 打分）排队串行，避免索引任务与对话生成抢 GPU。
- **懒加载 + 卸载**：按需加载；引用计数归零或内存压力（`DispatchSourceMemoryPressure`）时卸载；v1 策略「最多 1 个 LLM + 1 个 embedding 常驻，reranker 用完即卸」。
- 加载前检查 MLX memory limit 与当前任务需求；后台索引场景沿用 `SemanticIndexBuilder` 的限速与暂停/恢复模式（切账号 suspend/resume 由 `AppDependencies` 现有钩子挂接）。

---

## 6. 本地向量索引与 RAG

- **语义搜索**：`SemanticSearchService` 现有 `ensureIndexed` → query 向量 → vDSP cosine 流程不变；embedding 来源从远程 API 换成本地（`resolveEmbeddingSelection()` 解析到内置 profile 时）。
- **RAG 索引**：`KnowledgeRAGIndexBuilder.embedPendingChunks` 同理；`embedding_claim` 并发去重机制照旧。
- **索引失效与重建**：切换本地 embedding 模型 = `model` 串变化 → 旧向量不再被当前搜索读取；UI 检测到「当前激活 embedding 模型与已索引向量不一致」时提示重建（复用现有索引进度入口，`AppStatusToolbarButton` 已暴露索引状态）。
- **冷启动成本**：从远程 embedding 切到本地 = 全量重建，沿用 `SemanticIndexBuilder` 限速模式；设置页在切换时明示预计工作量。

---

## 7. 设置页 UI（全部在 AI 服务设置页内）

挂载点：`Features/Settings/AISettingsView.swift`

1. **服务商列表**：`localAI` 经 `CaseIterable` 自然出现在新增 provider 选择器（Intel Mac 上过滤，见 §8.2）。选中后 provider 详情区对 localAI 特化：隐藏 Base URL / API Key / 「测试并获取模型」，显示：
2. **模型管理区**（新 Section，仿 `enabledModelsSection` 的 DisclosureGroup 折叠风格）：
   - 三个模型卡片：类型 / 名称 / 大小 / 状态（未下载 · 下载中 % · 已安装 · 校验失败 · 磁盘不足）/ [下载] [暂停] [删除] [在 Finder 中显示]；
   - 下载进度条 + 失败原因 + 重试；
   - 下载源 Picker（Auto / Hugging Face / ModelScope）；
   - 存储占用 + 路径 + 全部清除（危险操作走二次确认，样式参考 `StorageSettingsTab`）。
3. **任务模型区**：不改代码，靠 §4.2 的 profile.models 注入自然工作。
4. **规范**：独立操作按钮右对齐（HStack+Spacer）；数值输入禁止 Stepper；`.buttonStyle(.plain)` 必须加 `.focusEffectDisabled()`；所有新文案走 `Localizable.xcstrings`，key 命名 `{section}.{subsection}.{component}`（如 `settings.ai.localai.model.download`）；文字颜色只用 `.primary` / `.secondary`。
5. **存储页联动**：`StorageSettingsTab` 的缓存清单加「本地 AI 模型」一项（用量 + 清除），复用 `CacheCleaner` 模式。

---

## 8. 门控与硬件

### 8.1 免费：现有 Pro 门控的 provider 感知适配

不新增 `ProFeature` case。规则：**当功能当前解析到的 provider 是 `.localAI` 时跳过 `requirePro`**，远程 provider 行为完全不变。适配点清单（全部已定位）：

| 调用点 | 适配 |
|---|---|
| `SemanticSearchService`（`semanticSearch` 门控 ×3） | 解析 selection 后按 provider 判断 |
| `RepoAIInsightService`（aiSummary / aiTags / aiChat） | 同上 |
| `KnowledgeRAGIndexBuilder` / `AppDependencies.swift` / `KnowledgeRAGWorkspaceViewModel`（knowledgeRAG） | RAG 入口：当前 chat/embedding 均为本地 → 放行 |
| `AIWorkspaceEntryGate`（`Shared/Utilities/AIWorkspaceEntryGate.swift`） | 门槛改为「远程已验证配置（需 Pro）∨ 本地模型齐备（免费）」，二者满足其一即放行 |

实现建议：收敛一个 `EntitlementGate.isProviderFree(_:)` 或等价 helper，避免多处各写一套判断。业务层仍禁止直接读 `isProUser` 的既有约束不变。

### 8.2 硬件门控（新增检查，全仓目前没有）

- Apple Silicon 检测：`sysctl("hw.optional.arm64") == 1`（封装进 `LocalAIHardwareSupport`）。
- Intel Mac：服务商选择器不出现 localAI；若用户旧配置残留 localAI 选择，selection 解析报 `providerUnavailable` 并在设置页提示。
- macOS 15 最低版本已满足 MLX 要求，无需额外处理。

### 8.3 双渠道

- 模型不打进 bundle（v1.0 原则保留，吸取 `codebase.bin` 258 MiB 教训）；两渠道运行时下载到 `8WCUMGCWMB.com.starcat.app.localai` 共享容器，同一台 Mac 只保留一份模型。
- App Store 沙箱主 App 与 Developer ID Direct 主 App 都携带该 Team ID App Group；Direct 最终重签使用最小发布 entitlement。Widget、屏保与 `codebase.bin` 均不继承模型组权限。
- MLX 依赖加入两个 app target（`project.yml` 的 Starcat 与 StarcatDirect `dependencies:`），**不进 Widget target**（`APPLICATION_EXTENSION_API_ONLY`）。

---

## 9. 持久化与数据库迁移

**v1 零数据库迁移。** 依据：

1. 模型 = 机器级文件系统资源，状态存 `manifest.json`，不进 per-user 数据库（数据库按 `users/<userId>/` 隔离，模型不该跟着账号走）。
2. 向量元数据已够用：`repo_embeddings` 主键 `(repo_id, model)` + `dimensions` 列，`rag_chunks` 有 `embedding_model / embedding_dim / embedding_status`；revision 编入 `model` 串（§3.3）后，兼容性判定无需新列。
3. 内置 profile / 模型描述符：启动时 seed-if-missing + 从 manifest 重建 `models`，不新增持久化结构。

若实现期证明需要结构化 revision 列或本地任务配置入库，再按铁律追加 **`v24-local-ai`** 迁移（当前最新为 `v23-public-repo-star-history`；禁止回改已落地 schema，依赖表不存在的中间迁移必须 no-op）。

---

## 10. 工程约束与测试

- **依赖**：`project.yml` `packages:` 加 `mlx-swift-lm`（`from:` 版本策略，与现有惯例一致），同步 `docs/3-设计/详细设计/04-技术选型.md`（project.yml 注释要求两处一致）。
- **新文件**：先 `xcodegen generate` 再构建。
- **测试门控（TestEnvironment，强制）**：`AppDependencies` 初始化处对 `LocalMLXRuntime` / `LocalAIModelManager` 做 `TestEnvironment.isRunning` 门控——测试期不加载 MLX、不发起下载、不触 GPU；与 Keychain ping、Aptabase 等现有门控点同级。
- **单测**（对标 `RAGCLIModelClientTests` / `SemanticSearchTests`）：Catalog 结构与唯一性、manifest 读写与脏目录容错、下载器（URLProtocolStub 模拟 Range 续传 / SHA256 失败 / 磁盘不足）、profile 注入与 selection 解析、门控 provider 感知逻辑。GPU 真实推理不进单测（spike 与人工验收覆盖）。
- **跑测**：`make test`；跑测前关闭 Xcode IDE；模型下载/加载代码不得绕过门控。

---

## 11. 落地里程碑

### M0 Spike（先行，不动主工程业务代码）
独立 scratch package / demo target 引入 mlx-swift-lm，验证 §3.2 的 R1–R3：
1. `Qwen3-Embedding-0.6B-8bit`：加载、输出维度 1024、中英 query-doc 相似度 sanity、批量吞吐；
2. Reranker mxfp8：加载、判别式 vs embedding 式用法、M1/M2 兼容；不达标 → 换 4bit 备选；
3. `Qwen3-4B-Instruct-2507-4bit`：首 token 延迟、tokens/s、峰值内存、长上下文内存；
4. MLX memory limit / cache limit API 行为。
**产出**：spike 结论文档，回填 §3.1 默认模型定稿（或换备选）。

### M1 Provider 接入（免费核心链路）
`project.yml` 依赖 → `AIServiceProvider.localAI` 全清单（§4.1）→ 内置 profile 注入与验证语义（§4.2）→ `LocalMLXClient` + 工厂分支（§4.3）→ 门控 provider 感知（§8.1）→ 硬件门控（§8.2）→ TestEnvironment 门控。
**验收**：手动放置模型文件后（开发通道），摘要 / 对话（流式）/ embedding 链路可跑，Intel 模拟下不可见。

### M2 模型管理与下载
Catalog / ModelManager / Downloader（续传 + 校验 + 磁盘检查）/ Storage + manifest / 设置页模型管理区（§5、§7.2）。
**验收**：UI 从 HF 下载三件套 → 校验 → 任务 picker 自动出现本地模型 → 四任务全通；断点续传中断恢复。

### M3 本地向量索引
SemanticSearchService / KnowledgeRAGIndexBuilder 走本地 embedding；GPU actor 串行 + 限速 + 切库 suspend/resume；模型切换 → 索引失效提示重建（§6）。
**验收**：语义搜索与 RAG 召回端到端本地可用；重建提示正确。

### M4 RAG 本地 Reranker
`RAGRerankConfiguration` 加 `.localMLX` + `LocalMLXRAGReranker` + 装配（§4.4），默认关闭。
**验收**：开启后 RAG 全链路本地，rerank 延迟可接受；关闭行为与现状一致。

### M5 收尾
ModelScope 白名单 + 下载源 Picker / 存储页联动 / i18n 全量 / 双渠道构建验证 / `docs/3-设计/详细设计/30-本地RAG设计.md` 等文档同步。
**验收**：§12 清单逐条通过。

---

## 12. v1 验收清单

1. AI 服务商列表出现「Starcat Local AI」；Intel Mac 不可见。
2. 选择本地 AI 后可下载 Catalog 模型：显示大小、进度、状态、磁盘占用；支持暂停/恢复、断点续传、SHA256 校验、磁盘空间预检。
3. 下载校验完成后，**不需要任何 Key / URL 配置**，任务模型配置区即可选择本地模型。
4. 摘要 / 标签 / 对话（流式）/ 向量化四任务可全程本地运行。
5. 本地 AI 免费：使用本地模型不触发任何 Pro 付费墙；远程 provider 的门控行为不变。
6. 本地模式下 AI 内容不发送到第三方 AI API（模型下载元数据请求除外）。
7. 语义搜索与 RAG 召回可本地端到端；RAG rerank 可切本地且默认关闭。
8. 切换 embedding 模型后，旧向量被判定失效并提示重建。
9. 模型可单独删除 / 全部清除，存储占用与路径在设置页可见。
10. 单元测试运行期间无模型下载、无 GPU 加载（TestEnvironment 门控生效）。

---

## 13. 风险与开放问题

| # | 风险 / 待决 | 状态 |
|---|---|---|
| R1 | Qwen3-Embedding Swift 端 16384 维 bug（mlx-swift-lm #36） | M0 验证；不达标换 4bit/BGE-M3 |
| R2 | Reranker mxfp8 权重用法（embedding 式转换）与 M1/M2 兼容 | M0 验证；备选 4bit/bf16 |
| R3 | 8GB 机型内存预算（三模型 ~3.5GB） | 设计已定（懒加载 + 串行 + 卸载）；M0 实测校准 |
| R4 | ModelScope 镜像覆盖与 revision 一致性 | M5 白名单逐个人工验证；不做静默切源 |
| R5 | 远程 → 本地 embedding 切换的全量重建成本 | 复用限速索引；切换时明示（§6） |
| O1 | `AIProviderProfile.isVerifiedConfiguration` 的存储形态（stored vs computed）影响 §4.2 最小适配方式 | M1 实现期确认 |
| O2 | `Localizable.xcstrings` 只允许按行插入（Catalog 禁止工具改写）——新 key 较多，需确认按行插入操作方式 | M2 前确认 |
| O3 | Gemma 3 1B 等小模型仅作 spike 链路验证，不进 catalog | 已决 |

---

## 14. v1.0 → v1.1 差异对照

| 项 | v1.0 | v1.1（本版） |
|---|---|---|
| Provider 层 | 新造 LLMProvider / EmbeddingProvider / RerankerProvider 协议族 | 复用 `AIClientProtocol` / `RAGReranking`，`LocalMLXClient` 走 `RAGCLIModelClient` 的非 HTTP 客户端先例 |
| 接入形态 | 独立 Local AI 设置页 + Local AI 总开关 | `AIServiceProvider.localAI` case + 内置 profile，全部挂在 AI 服务设置页 |
| Embedding 元数据 | 「必须记录 Model ID/Revision/Dimension」当作新建需求 | 已有 `model`+`dimensions` 列；revision 编入 model 串，v1 零迁移 |
| Reranker | 下载即默认启用，自建封装 | `RAGReranking` 第三实现 + `RAGRerankConfiguration.localMLX`，**默认关闭** |
| 模型选择 | Local AI 页面独立选择三模型 | 任务级模型配置照旧，本地模型经 profile.models 注入自然出现 |
| 下载能力 | 列了进度/重试/校验/磁盘检查，无实现基础 | 明确基于 `ReleaseAssetDownloader` 补断点续传/SHA256/磁盘预检三个缺口 |
| 付费 | 未提及 | 免费；`requirePro` 各点位 provider 感知放行 |
| 硬件 | 未提及 | Apple Silicon 检测 + Intel 隐藏入口 |
| 框架与默认模型 | — | **原样保留**（mlx-swift-lm + Qwen3 三件套），以 M0 spike 结论定稿 |

---

## 15. 实施记录（2026-09-12，feature/local-ai 分支）

按本方案 v1.1 完成首版实现。与上文的差异与最终落地口径（以上文 + 本节为准）：

1. **依赖最终形态**：`mlx-swift-lm`（branch: main）提供 `MLXLMCommon / MLXLLM / MLXEmbedders / MLXRerankers / MLXHuggingFace`；3.x 起分词器需自带实现，配套引入 `swift-transformers`（Tokenizers）与 `swift-huggingface`（HuggingFace）。构建脚本全部入口补 `-skipPackagePluginValidation` + `-skipMacroValidation`（mlx-swift 带 SPM 构建插件与宏）。
2. **Reranker 比预期顺利**：上游已提供公共 `RerankerModelFactory`（自动识别 qwen3 判别式权重，归一化 0...1 打分），无需自行封装 yes/no logits；R2 风险中「判别式用法」已由上游解决，仅剩 M1/M2 芯片实测。
3. **Catalog 校验口径**：离线无法预知 commit SHA 与文件哈希，改为「安装时解析 revision（HF API sha）并记录进 manifest；文件 SHA256 下载时流式计算写入 manifest」，后续完整性检查以 manifest 对账。
4. **本地 Reranker 定位**：`RAGReranking` 第三实现 + `RAGRerankConfiguration.provider` 加 `.localMLX`，默认关闭（§4.4 口径落地）。
5. **客户端工厂**：`AIClientFactory.make(configuration:)` 统一 7 个构造点，`.localAI` 返回 `LocalMLXClient`，其余走 `OpenAIClient`。
6. **免费门控**：`EntitlementGate.requirePro(_:usesLocalOnly:)` + `AppSettings.isTaskResolvedToLocalAI(_:)` 系列 helper；适配点：语义搜索 ×3、摘要/标签/对话（RepoAIInsightService ×4）、批量 AI ×5（服务 + UI）、自动整理、RAG（IndexBuilder ×5 + AppDependencies ×2 + WorkspaceViewModel ×2）、`AIWorkspaceEntryGate`。AI 设置页整页 Pro 锁在 Apple Silicon 上放行（免费用户可进入配置与下载）。
7. **设置页**：新增独立「本地 AI 模型」Section（`LocalAIModelsSection.swift`），不依赖 profile 验证状态即可下载；provider 区对 localAI 隐藏 Base URL / Key / 测试按钮，内置 profile 禁止删除；v1 未放下载源 Picker（catalog 尚无 ModelScope 白名单条目，字段已建模）。
8. **i18n**：38 个 `settings.localai.*` + 1 个 `rag.workspace.rerank.provider.localmlx`，18 语言，按行插入（diff 仅新增）。
9. **测试**：Catalog 契约 / Storage（manifest、脏目录、清理、用量，`testRootOverride` 注入临时目录）/ Downloader（整段 + 206 续传 + 忽略 Range + 404 + 体积不符，URLProtocolStub）/ 门控与 selection（本地放行、远程不变、未验证 profile 拒绝）。`TestEnvironment` 门控：不下载、不加载 MLX；manager profile 同步测试期 no-op。
10. **遗留到后续版本**：ModelScope 白名单与下载源 Picker、存储页（StorageSettingsTab）联动项、嵌入切换重建的 UI 引导文案细化、Intel Mac 兜底提示文案。
