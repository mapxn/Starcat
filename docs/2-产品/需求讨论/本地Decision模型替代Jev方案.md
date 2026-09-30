# Starcat Decision Engine 抽象与 Laya MLX Swift 集成方案

> 状态：Labs 实验功能已实施，等待真实场景验收与领域评测
>
> 记录日期：2026-09-21；实施更新：2026-09-28
>
> 目标：以可扩展的 Decision Engine 边界承载 Jev 与本地 Laya，由用户显式选择实现，同时保持原有 LLM 兜底和人工确认边界。

---

## 1. 背景与当前决定

Starcat 已使用 Jev 为现有 GitHub Lists 和标签执行封闭集判断：应用把仓库事实、README 摘要和候选分组 / 标签组成多个 `noul` 问题，取得每个候选的概率，再交给现有 Policy 做排序、阈值过滤和人工确认。

Jev 需要 API Key 和远程请求。为了让更多用户在不配置第三方服务的情况下使用相同能力，曾考虑增加本地 Decision Model，并复用 Starcat 已有的本地 AI 下载、模型生命周期和 MLX Swift 基础设施。

截至 2026-09-21，相关开源项目出现较快，但仍普遍存在以下一项或多项问题：

- 只有 Python / PyTorch / Python MLX 运行时，不能直接嵌入 Swift App；
- 只是读取普通 LLM 的候选 token logits，并非训练过的决策模型；
- 返回的是候选集合内的相对分数，缺少面向实际正确率的校准；
- 模型过大、上下文过短、语言覆盖不足，或公开评测与 Starcat 场景不一致；
- 项目刚发布，API、模型格式、许可证和维护状态尚不稳定。

2026-09-28 重新核验后，社区 [`laya-mlx`](https://github.com/mizorewww/laya-mlx) 已提供完整 MLX 网络实现、Apache-2.0 许可证、NOTICE 与预转换多语言 FP16 checkpoint。Starcat 已完成 Swift 原生结构移植和固定样本对拍，因此将 `Laya Multilingual 322M` 作为 Labs 实验引擎接入；这不代表模型质量门禁已经完成，也不把社区 runtime 表述为 Laya 官方原生支持。

**当前决定：Jev 与 Laya 是同一抽象下的并列实现，由用户显式选择。** 不按“本地优先、失败再切远端”的顺序自动串联两种引擎。总开关关闭或所选引擎在调用前不可用时，才走既有 LLM 路径；引擎开始执行后的网络、加载、解析或推理错误直接反馈，不再双跑另一引擎或 LLM。

---

## 2. 候选项目快照

> 以下是 2026-09-21 的调研快照。该生态变化很快，重新启动时必须核验最新代码、模型卡、许可证、评测和提交状态。

| 候选 | 模型 / 实现 | 本地运行 | MLX 状态 | 当前判断 |
|---|---|---:|---|---|
| [Laya](https://github.com/NandhaKishorM/laya) | 322M / 421M 双向 Encoder，支持 `choice` / `score` / `noul` | 是 | [laya-mlx](https://github.com/mizorewww/laya-mlx) 为社区 Python MLX runtime；Starcat 已将所需网络移植到 MLX Swift | 已接入 `aac6fef/laya-multilingual-mlx` FP16 Labs POC；仍需 Starcat 领域评测与人工验收 |
| [Kev](https://github.com/jaredpalmer/kev) | Qwen3 / Qwen3.5 + LoRA + 专用 pointer head，兼容 `/v1/systemone` | 是 | Apple Silicon 目前主要走 PyTorch / MPS；MLX 后端尚在计划中 | API 与 Jev 最接近，等待 MLX 后端和稳定版本 |
| [Von](https://github.com/wfzyx/von) | 395M ModernBERT 决策模型，兼容 TypeSafe API | 是 | 未提供 MLX | 可作为离线质量对照，不适合当前 Swift 内嵌路径 |
| [OpenJev](https://huggingface.co/AlexWortega/openjev) | Qwen3.5 NLI cross-encoder，输出 entailment / contradiction / neutral | 是 | 未提供 MLX | 语义上适合标签隶属判断，但不是完整 System One API |
| [Bespoke Nimble](https://github.com/bespokelabsai/nimble) | Qwen3.5 9B typed-decision 模型 | 是 | Python MLX | 体积和内存要求过高，不适合作为普惠默认模型 |
| [Verdict](https://github.com/Heman10x-NGU/Verdict-open-jev) | 151M ModernBERT，ONNX / WebGPU | 是 | 无 MLX | 足够小，但公开外部评测与 Jev 差距较大 |
| [NanoJev](https://github.com/TianyuCodings/NanoJev) | Qwen3 0.6B + 决策 head | 是 | 当前以 CUDA 路径为主 | 训练和评测偏游戏决策，不适合直接迁移到仓库标签 |
| [jevmlx](https://github.com/bnsd55/jevmlx) / [LitJev](https://github.com/zhengxuyu/litjev) / [Jevify](https://github.com/Mintzs/jevify) | 普通 LLM 的候选 logits / 约束解码 | 是 | 部分支持 Python MLX | 可用于 baseline 和原型，不应未经校准就把输出称为置信度 |
| [PocketJev](https://github.com/NullPo-jp/PocketJev) | Qwen3-VL + 选项 logits | 是 | 使用 MLX Swift / mlx-swift-lm | 证明 Swift 读取候选 logits 的技术路径可行，但不是训练过的通用决策模型 |
| [LocalJev](https://github.com/githubnext/localjev) | DiffusionGemma 生成概率 JSON | 是 | 依赖 oMLX 和较大模型 | 协议兼容但概率为模型自报，模型过大，不适合 Starcat 默认能力 |

社区汇总入口：[Jev Reproductions Tracker](https://huggingface.co/spaces/multimodalart/jev-reproductions-tracker)。该页面同样明确指出，当前开源项目尚未公开复现 Jev 的 RLCD 训练算法、权重与校准能力。

---

## 3. MLX 可行性边界

“支持 MLX”必须区分三层，后续评审时不得混用：

1. **Python MLX**：能在 Apple Silicon 本地运行，但需要 Python 环境，不能直接作为 Starcat 的 Swift 进程内模型。
2. **MLX Swift / mlx-swift-lm**：可以复用 Starcat 当前运行时、下载器和 Metal 生命周期管理，才是现有架构下优先考虑的内嵌形式。
3. **Core ML**：不是 MLX，但可由 Swift 原生加载，并可使用 GPU / Neural Engine；如果开放模型已经提供经过验证的 Core ML 包，它可能比自行移植到 MLX Swift 风险更低。

Starcat 的通用 Local AI 模型类型仍为 LLM、Embedding、Reranker。Laya 没有伪装成其中任意一种，而是使用独立 `models/decision/` 目录、安装 manifest、生命周期管理器和 MLX actor；设置入口只位于 Labs。普通 Qwen 的 next-token softmax 仍只能作为技术验证，在完成领域评测和温度校准前不得称为“正确率”或“可靠置信度”。

---

## 4. 已实施架构

业务问题构造已经与具体 runtime 拆开：

```text
仓库分组 / 标签复用业务
          ↓
DecisionSuggestionRouters
          ↓
RepositoryDecisionService
          ↓
DecisionEngineRegistry（只解析用户选择的一种实现）
          ├── JevDecisionEngine
          │     ├── 原生 TypeSafe API（优先）
          │     └── OpenRouter Decisions（Jev 内部 fallback）
          └── LayaDecisionEngine
                └── LayaMLXDecisionRuntime（进程内 MLX Swift）
```

两种引擎共用以下业务语义：

- 仓库事实与 README 状态构造；
- 一个候选分组 / 标签对应一个独立 `noul` 问题；
- 结果合法性检查、排序、阈值过滤和封闭集约束；
- 标签库不足时进入现有 LLM 新标签生成路径；
- AI 建议仍需用户确认，不能因为改成本地模型而扩大自动写入权限。

路由规则固定为：

```text
Labs 决策引擎总开关关闭
    → 既有 LLM

总开关开启 + 所选引擎调用前可用
    → 只调用所选的 Jev 或 Laya

所选引擎调用前不可用
    → 既有 LLM

所选引擎已经开始执行但失败
    → 直接上抛；不切另一引擎，也不重复调用 LLM
```

Jev 的 transport 选择不进入通用引擎枚举：原生 TypeSafe Key 可用时始终优先；只有原生 Key 缺失或最近一次显式测试失败，才选择第一个已启用、已验证且有 Key 的 OpenRouter profile，并固定使用 `typesafe/jev-1.13`。一次请求解析 transport 后不会因业务错误临时切换。

Laya 首版固定 `aac6fef/laya-multilingual-mlx` FP16 checkpoint。模型下载保留 `encoder/`、`tokenizer/` 子目录并校验 manifest；共享读写锁和串行 operation gate 保证另一进程或设置页删除模型时，不会移除仍被加载/推理使用的 mmap 文件。runtime 当前只公开 Starcat 实际使用的 `noul`，最多 16 条问题一批，不暴露尚未完成产品验证的 `choice`、`score` 或 action 输出。

---

## 5. 重新启动前的评测门禁

候选模型不能只凭公开 benchmark 入选。必须先建立 Starcat 专用、可重复的离线评测集：

- 用户已确认的仓库与标签关系；
- 用户已确认的 GitHub List 归属；
- 明确不匹配的负样本、近义标签和无匹配样本；
- 英文、中文及中英混合 README；
- 不同候选规模、不同 README 长度和冷启动场景。

至少评估：

- Precision、Recall、F1；
- Brier Score、ECE 和可靠性曲线；
- 自动应用阈值下的误打率与覆盖率；
- 首次加载时间、单仓库延迟、批量吞吐、峰值内存和模型下载体积；
- 候选顺序扰动、近义标签、空标签库和超长 README 的稳定性；
- App Store / Direct 两种构建渠道的模型下载、签名与运行行为。

当前 Jev 路径按字符截取 README，并允许最多 150 个标签候选。Laya runtime 使用 checkpoint tokenizer 按真实 `max_len` / `head_max_len` 预算构造输入，并把 Noul 问题按最多 16 条分批；分批只改变执行方式，不改变最终排序、阈值和去重语义。后续 checkpoint 若改变上下文或 prompt 协议，必须重新对拍，不能只修改 catalog 数字。

---

## 6. 进入稳定功能前的收口条件

Labs POC 不等于正式能力。进入稳定设置或默认路由前仍需满足：

1. 至少一个开放权重模型具备稳定的 `noul` / 多标签判断能力，而不只是普通 LLM 自报概率。
2. MLX Swift runtime 与固定上游 checkpoint 具有可重复的 Python 对拍和升级兼容测试。
3. 模型与代码许可证允许 Starcat 商业分发，并能完整登记第三方版权与 NOTICE。
4. 在独立、未参与训练的评测集上公开校准指标、失败边界和可复现结果。
5. 模型体积、内存、上下文和批量延迟适合 Starcat 的普通 Apple Silicon 用户。
6. 上游 API、权重格式和维护状态稳定；checkpoint 升级必须显式评审，不能静默跟随 latest。
7. Starcat 自有评测证明其在标签复用和仓库分组场景达到可接受门槛。

未满足这些条件时，Laya 只能留在 Labs，不能替代 Jev 默认值或扩大自动应用权限。

---

## 7. 数据与合规边界

- 训练、微调和校准数据应来自独立人工标注或用户明确确认过的 Starcat 结果。
- 不使用 Jev 输出作为训练、蒸馏或模仿数据。TypeSafe 当前公开协议限制使用其服务或输出训练、开发类似或竞争模型；未来实施前必须重新核验最新条款。
- 不把私人仓库 README、笔记、标签或组织信息上传为公共数据集。
- 发布模型或转换权重前，必须同时核验基础模型、适配器、训练集、转换代码与 tokenizer 的许可证。

参考：[TypeSafe Master Customer Agreement](https://typesafe.ai/legal/mca)。

---

## 8. 本次实施边界

- 只重构仓库分组与标签复用的决策生成；候选校验、阈值、人工确认和最终写入策略保持不变。
- 只接入 Jev 与 Laya 两个引擎；OpenRouter 是 Jev transport，不是第三种引擎。
- Laya 只使用既有 MLX Swift / Tokenizers 依赖，不引入 Python、ONNX Runtime 或 Core ML runtime。
- 不新增数据库 schema；旧 Jev Labs UserDefaults 只做一次性迁移，继续选择 Jev。
- 不自动下载模型；用户在 Labs 明确安装，删除时等待在途推理退出。
- 不把固定样本对拍等同于 Starcat 领域质量验收；真实标签/分组评测仍是正式化门禁。
