# GitHub 与 Multica 任务对齐

> 日期：2026-10-07。覆盖 Starcat 主仓库及全部存在开放 Issue 的配套仓库。日常执行入口为 Multica。

## 对齐范围

| 指标 | 整理前 | 整理后 |
| --- | ---: | ---: |
| GitHub 开放 Issue | 31 | 77 |
| Multica 在办任务 | 49 | 77 |
| 已完成/取消 Multica 历史记录 | 113 | 113 |

本次在 GitHub 补录 46 项，在 Multica 补录 28 项，并复用 3 对已有相同范围的任务。数量增加来自补齐两边的既有待办，不代表增加新功能范围。

全部在办 Multica 任务仍为 backlog；新任务不分配负责人、不设置优先级。已有任务的状态、优先级及负责人保留，HOM-168 仍为 High。

本表包含 8 个父任务，父子项不是可重复开发的两套需求；父任务负责整体交付验收，子任务负责独立交付。HOM-53、HOM-92 等已完成历史父任务不重开，其剩余子任务分别跟踪。

本次核对任务身份、范围与状态，不把建立镜像当作功能“完全未实现”的证据；具体开工前仍需复用已有实现并核对剩余验收。

## 执行与收尾

- 每个 Multica 任务开头有唯一 GitHub 主关联 URL；GitHub 正文有对应 HOM 编号。
- 修改范围或验收要求时同步双方；配套仓库使用完整 owner/repo/issue 身份。
- 验收后在 GitHub 留下英文 commit/PR、验证与限制说明，按 completed 关闭并同步 Project，再把 Multica 设为 done，回读双方。
- 取消使用 Multica cancelled 与 GitHub not planned；任一端失败记录“同步待补”，不宣称两端完成。
- 子任务完成不得直接关闭父任务；父任务等待保留子项和自身验收完成。
- 本次未配置状态变化 webhook 或定时自动关闭；在 Multica 手动点 done 不会自动发起 GitHub 请求，必须由执行者落实收尾。

完整规则见 [任务录入规范](任务录入规范.md)；已取消范围见 [任务取消与范围同步](2026-10-07-任务取消与范围同步.md)。

## 范围校正

- CloudKit Schema #84 去掉已取消的 SavedSearch 同步要求；既有本地表和数据保留。
- HOM-48 保留 Starcat 自有 JSON 导入及备份父任务，HOM-208 / #71 独立跟踪 JSON 导出；不恢复 OhMyStar/Astral 兼容。
- HOM-61 汇总窗口置顶、最近查看、常用标签，三个子任务独立关联；不恢复 README 独立窗后续工作。
- HOM-130 负责社区完整度和 License 信号集成，HOM-159 唯一维护 SPDX 风险分类规则。
- HOM-97 原说明及验收属于本地工具检测实现，标题类型由调研统一为 Feature，保留原范围。
- HOM-109 复用已完成 #108 公告详情，跟踪剩余 radar 流程；HOM-131 不恢复已取消 #75 通用详情增强。
- HOM-168 仍需先确认功能矩阵中的 BYOK/Pro 边界；不恢复 #82 的语义搜索 Pro 门控。

## 对应清单

### starcat-app/Starcat（66 项）

| Multica | 任务 | GitHub | 父子关系 |
| --- | --- | --- | --- |
| HOM-48 | Starcat JSON 导入与数据导出 | [#121](https://github.com/starcat-app/Starcat/issues/121) | 父任务 |
| HOM-56 | CloudKit 多端同步 | [#77](https://github.com/starcat-app/Starcat/issues/77) | 父任务 |
| HOM-57 | iOS / iPadOS 响应式布局适配 | [#85](https://github.com/starcat-app/Starcat/issues/85) | 独立任务 |
| HOM-61 | 窗口置顶 / 最近查看 / 常用标签 | [#122](https://github.com/starcat-app/Starcat/issues/122) | 父任务 |
| HOM-79 | 文档与本地优先路线对齐 | [#123](https://github.com/starcat-app/Starcat/issues/123) | 独立任务 |
| HOM-88 | 开源项目分析工具集成 | [#124](https://github.com/starcat-app/Starcat/issues/124) | 父任务 |
| HOM-89 | 技术选型助手主任务 | [#89](https://github.com/starcat-app/Starcat/issues/89) | 父任务 |
| HOM-90 | 安全雷达：Star 项目漏洞监控（主任务） | [#125](https://github.com/starcat-app/Starcat/issues/125) | 父任务 |
| HOM-91 | Discover 轻量项目情报订阅（主任务） | [#126](https://github.com/starcat-app/Starcat/issues/126) | 父任务 |
| HOM-93 | 贡献机会发现（主任务） | [#127](https://github.com/starcat-app/Starcat/issues/127) | 父任务 |
| HOM-95 | 轻量项目分析：GitHub 元数据 / README / manifest | [#128](https://github.com/starcat-app/Starcat/issues/128) | 子任务 → HOM-88 |
| HOM-96 | 技术栈识别与 manifest 解析器 | [#129](https://github.com/starcat-app/Starcat/issues/129) | 子任务 → HOM-88 |
| HOM-97 | 本地分析工具检测：Repomix / Gitingest / OSV Scanner | [#130](https://github.com/starcat-app/Starcat/issues/130) | 子任务 → HOM-88 |
| HOM-99 | Repo 详情 Analysis 面板 | [#131](https://github.com/starcat-app/Starcat/issues/131) | 子任务 → HOM-88 |
| HOM-100 | 报告数据模型与会话存储 | [#132](https://github.com/starcat-app/Starcat/issues/132) | 子任务 → HOM-89 |
| HOM-101 | 候选发现：本地 / Discover / GitHub Search | [#133](https://github.com/starcat-app/Starcat/issues/133) | 子任务 → HOM-89 |
| HOM-102 | 候选确认 UI | [#134](https://github.com/starcat-app/Starcat/issues/134) | 子任务 → HOM-89 |
| HOM-103 | AI 对比报告生成 | [#135](https://github.com/starcat-app/Starcat/issues/135) | 子任务 → HOM-89 |
| HOM-104 | 报告编辑、保存与 Markdown / ADR 导出 | [#136](https://github.com/starcat-app/Starcat/issues/136) | 子任务 → HOM-89 |
| HOM-105 | 数据模型与扫描结果缓存 | [#137](https://github.com/starcat-app/Starcat/issues/137) | 子任务 → HOM-90 |
| HOM-106 | OSV API 与 GitHub Global Security Advisories 客户端 | [#138](https://github.com/starcat-app/Starcat/issues/138) | 子任务 → HOM-90 |
| HOM-107 | manifest / lockfile 轻量扫描与版本提取 | [#139](https://github.com/starcat-app/Starcat/issues/139) | 子任务 → HOM-90 |
| HOM-108 | 漏洞匹配、影响依据与风险解释 | [#140](https://github.com/starcat-app/Starcat/issues/140) | 子任务 → HOM-90 |
| HOM-109 | 漏洞列表 / 详情 / 筛选页 | [#141](https://github.com/starcat-app/Starcat/issues/141) | 子任务 → HOM-90 |
| HOM-110 | 自有仓库安全告警 + SBOM / Dependency Graph 高级集成评估 | [#142](https://github.com/starcat-app/Starcat/issues/142) | 子任务 → HOM-90 |
| HOM-111 | 数据模型 FeedSource / FeedItem / DiscoveredRepo / Channel | [#143](https://github.com/starcat-app/Starcat/issues/143) | 子任务 → HOM-91 |
| HOM-112 | GitHub Markdown Feed 拉取与缓存 | [#144](https://github.com/starcat-app/Starcat/issues/144) | 子任务 → HOM-91 |
| HOM-113 | Markdown 中 GitHub Repo URL 提取、去重与 metadata 补全 | [#145](https://github.com/starcat-app/Starcat/issues/145) | 子任务 → HOM-91 |
| HOM-114 | Today / This Week / Sources / Saved for Later UI | [#146](https://github.com/starcat-app/Starcat/issues/146) | 子任务 → HOM-91 |
| HOM-115 | 主题频道：Skill / MCP 规则匹配与频道 UI | [#147](https://github.com/starcat-app/Starcat/issues/147) | 子任务 → HOM-91 |
| HOM-116 | GitHub Search 定时任务源 | [#148](https://github.com/starcat-app/Starcat/issues/148) | 子任务 → HOM-91 |
| HOM-117 | 项目动作：Star 入库 / 稍后看 / 不感兴趣 / 加入技术选型 | [#149](https://github.com/starcat-app/Starcat/issues/149) | 子任务 → HOM-91 |
| HOM-118 | AI 推荐理由与摘要生成 | [#150](https://github.com/starcat-app/Starcat/issues/150) | 子任务 → HOM-91 |
| HOM-119 | Embedding Provider 与生成队列 | [#151](https://github.com/starcat-app/Starcat/issues/151) | 历史父任务 HOM-53（已完成） |
| HOM-121 | 混合搜索排序：FTS5 + Embedding + RRF | [#152](https://github.com/starcat-app/Starcat/issues/152) | 历史父任务 HOM-53（已完成） |
| HOM-122 | Search UI：关键词 / 语义 / 混合 / 技术选型模式 | [#153](https://github.com/starcat-app/Starcat/issues/153) | 历史父任务 HOM-53（已完成） |
| HOM-124 | WebSearchProvider 抽象：anysearch / Jina Search / Jina Reader | [#154](https://github.com/starcat-app/Starcat/issues/154) | 历史父任务 HOM-53（已完成） |
| HOM-125 | 搜索结果动作与入库状态 | [#155](https://github.com/starcat-app/Starcat/issues/155) | 历史父任务 HOM-53（已完成） |
| HOM-127 | GitHub 扩展数据按需抓取与本地缓存 | [#156](https://github.com/starcat-app/Starcat/issues/156) | 历史父任务 HOM-92（已完成） |
| HOM-128 | 项目健康度规则评分模型 | [#157](https://github.com/starcat-app/Starcat/issues/157) | 历史父任务 HOM-92（已完成） |
| HOM-129 | 维护活跃度指标：commit / release / issue / PR | [#158](https://github.com/starcat-app/Starcat/issues/158) | 历史父任务 HOM-92（已完成） |
| HOM-130 | License 与社区完整度风险检查 | [#159](https://github.com/starcat-app/Starcat/issues/159) | 历史父任务 HOM-92（已完成） |
| HOM-131 | Insights Health / Maintenance / Licenses 子页 | [#160](https://github.com/starcat-app/Starcat/issues/160) | 历史父任务 HOM-92（已完成） |
| HOM-133 | GitHub Issues API：good first issue / help wanted 拉取 | [#161](https://github.com/starcat-app/Starcat/issues/161) | 子任务 → HOM-93 |
| HOM-134 | 缓存、排序与适配度评分 | [#162](https://github.com/starcat-app/Starcat/issues/162) | 子任务 → HOM-93 |
| HOM-135 | Insights Contribution Opportunities UI | [#163](https://github.com/starcat-app/Starcat/issues/163) | 子任务 → HOM-93 |
| HOM-159 | License 风险分类与 SPDX 白名单 | [#164](https://github.com/starcat-app/Starcat/issues/164) | 历史父任务 HOM-92（已完成） |
| HOM-161 | AI 解释层 task 接入与回退兜底 | [#165](https://github.com/starcat-app/Starcat/issues/165) | 历史父任务 HOM-92（已完成） |
| HOM-168 | AI 配额管理与 Pro 权限门控 | [#166](https://github.com/starcat-app/Starcat/issues/166) | 独立任务 |
| HOM-205 | RAG 本地 CLI 准入评估 | [#62](https://github.com/starcat-app/Starcat/issues/62) | 独立任务 |
| HOM-206 | ACP 外部 Agent 运行时 | [#65](https://github.com/starcat-app/Starcat/issues/65) | 独立任务 |
| HOM-207 | 仓库窗口置顶 | [#66](https://github.com/starcat-app/Starcat/issues/66) | 子任务 → HOM-61 |
| HOM-208 | 仓库 JSON 导出 | [#71](https://github.com/starcat-app/Starcat/issues/71) | 子任务 → HOM-48 |
| HOM-209 | CloudKit 冲突解决界面 | [#81](https://github.com/starcat-app/Starcat/issues/81) | 子任务 → HOM-56 |
| HOM-210 | CloudKit 用户数据 Schema | [#84](https://github.com/starcat-app/Starcat/issues/84) | 子任务 → HOM-56 |
| HOM-211 | 最近查看仓库 | [#93](https://github.com/starcat-app/Starcat/issues/93) | 子任务 → HOM-61 |
| HOM-212 | 常用标签快捷访问 | [#95](https://github.com/starcat-app/Starcat/issues/95) | 子任务 → HOM-61 |
| HOM-213 | 合并重复工具逻辑 | [#96](https://github.com/starcat-app/Starcat/issues/96) | 独立任务 |
| HOM-214 | 项目命名规范 | [#97](https://github.com/starcat-app/Starcat/issues/97) | 独立任务 |
| HOM-215 | 收拢 DTO 模型映射 | [#98](https://github.com/starcat-app/Starcat/issues/98) | 独立任务 |
| HOM-216 | 核心状态回归测试 | [#99](https://github.com/starcat-app/Starcat/issues/99) | 独立任务 |
| HOM-217 | 统一 Logger 级别 | [#100](https://github.com/starcat-app/Starcat/issues/100) | 独立任务 |
| HOM-218 | 限定图片缓存预算 | [#102](https://github.com/starcat-app/Starcat/issues/102) | 独立任务 |
| HOM-219 | 数据库启动失败恢复提示 | [#103](https://github.com/starcat-app/Starcat/issues/103) | 独立任务 |
| HOM-220 | 性能验收基线 | [#104](https://github.com/starcat-app/Starcat/issues/104) | 独立任务 |
| HOM-221 | 完成视觉升级参考界面 | [#106](https://github.com/starcat-app/Starcat/issues/106) | 独立任务 |

### starcat-app/starcat-chrome-plugin（1 项）

| Multica | 任务 | GitHub | 父子关系 |
| --- | --- | --- | --- |
| HOM-222 | Chrome 商店上架准备 | [#1](https://github.com/starcat-app/starcat-chrome-plugin/issues/1) | 独立任务 |

### starcat-app/starcat-safari-plugin（1 项）

| Multica | 任务 | GitHub | 父子关系 |
| --- | --- | --- | --- |
| HOM-223 | Safari 商店上架准备 | [#1](https://github.com/starcat-app/starcat-safari-plugin/issues/1) | 独立任务 |

### starcat-app/starcat-sharing-api（3 项）

| Multica | 任务 | GitHub | 父子关系 |
| --- | --- | --- | --- |
| HOM-224 | 审核 Sharing Fly 参数 | [#26](https://github.com/starcat-app/starcat-sharing-api/issues/26) | 独立任务 |
| HOM-225 | Sharing 本地冒烟验证 | [#27](https://github.com/starcat-app/starcat-sharing-api/issues/27) | 独立任务 |
| HOM-226 | 收口 Sharing 版本包 | [#28](https://github.com/starcat-app/starcat-sharing-api/issues/28) | 独立任务 |

### starcat-app/starcat-trending-api（4 项）

| Multica | 任务 | GitHub | 父子关系 |
| --- | --- | --- | --- |
| HOM-227 | Trending 本地冒烟验证 | [#22](https://github.com/starcat-app/starcat-trending-api/issues/22) | 独立任务 |
| HOM-228 | Trending 去重并发富化 | [#23](https://github.com/starcat-app/starcat-trending-api/issues/23) | 独立任务 |
| HOM-229 | 收口 Trending 用户同步 | [#24](https://github.com/starcat-app/starcat-trending-api/issues/24) | 独立任务 |
| HOM-230 | 明确 Trending 模型边界 | [#25](https://github.com/starcat-app/starcat-trending-api/issues/25) | 独立任务 |

### starcat-app/starcat-wiki-api（2 项）

| Multica | 任务 | GitHub | 父子关系 |
| --- | --- | --- | --- |
| HOM-231 | 增加文档站探测 | [#7](https://github.com/starcat-app/starcat-wiki-api/issues/7) | 独立任务 |
| HOM-232 | 扩展有界批量探测 | [#8](https://github.com/starcat-app/starcat-wiki-api/issues/8) | 独立任务 |

## 回读核验

已使用执行后的完整分页结果核对：77 个开放 GitHub Issue 与 77 个在办 Multica 任务逐一对应，无漏项、重复主关联或正文写入差异。父子关系、状态及既有负责人/优先级均通过检查。Multica 共 190 条记录：77 backlog、106 done、7 cancelled；113 条历史任务及主仓库既有关闭 Issue 的状态、关闭原因和正文保持原状。

GitHub Project 的 77 张对应卡片已按卡片 ID 直接回读，均属于 Starcat Development Board、未归档、Issue 开放且状态为 Backlog。批量列表曾短暂漏出已写入卡片，最终以逐卡 GraphQL 状态核验通过为准。
