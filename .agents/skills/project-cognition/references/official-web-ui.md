# 官方 Web 客户端 UI/协议逆向笔记

> 2026-09-06 从 `https://zcode.z.ai/remote/v4` 在线抓取分析（app_version 3.7.7 时代的构建）。
> 抓取方式：`index.html` → 全部 82 个 `/remote/v4/assets/*.{js,css}`（共 8.2MB）。
> 本地临时副本在 `/tmp/zemote-official/`（会丢失），本笔记是仓库内的持久沉淀。
> 只抓干净页面，绝不携带 `sid/hash` 凭据（铁律 9）。

## 构建形态

- React + Vite + Lexical（富文本编辑器）+ Tailwind（class 在 JS 里拼，CSS 只剩原子类）。
- 主 bundle：`index-nOVzQNKW.js`；i18n 表在 `IntlProvider-*.js`（中文明文可搜）。
- 主题：html 根 class `theme-zai-dark` / `theme-zai-light` 切换 CSS 变量。

## Composer mention 体系（@ 引用）—— 已逆向闭环

官方 composer 是 **Lexical 编辑器**，@/#/$ 都是编辑器内的 `prompt-mention`
token 节点（类 `QA`，`setMode('token')`）。节点携带：
`{mentionId, category, label, value, markdown, description}`。

**发送协议**：mention 序列化为其 `markdown` 字符串**内嵌在 sendText 的
`text` 字段里**，没有独立协议字段（与 lib/protocol 侦察结论一致），
桌面端解析这些 markdown 链接形态。

### 各类目 markdown 格式（bundle 函数 Yx/Xx/Zx/Qx/gke 直译）

| 类目 | 触发 | markdown 形态 | 备注 |
|---|---|---|---|
| file/directory | `@` | `[label](./relative/path)`，目录尾补 `/` | 裸相对路径补 `./`；`Jx` 只做归一化不加 scheme |
| skill | `$` | `[$name](value)`，value 缺失时裸 `$name` | Zemote 现有 `$name ` 纯文本兼容 |
| session | `#` | `[#title](#sessionId)`，title 为空/等于 id 时裸 `#id` | gke 函数 |
| 简单提及 | `@` | 裸 `@name`（Zx） | |
| plugin | `@` | `[label](plugin://value)` | value 有 `x@y` 格式校验 |

- 转义规则：label 的 `\` `[` `]`（Kx）；链接 target 的 `\` `>`（qx）。
- **触发规则**：正则 `(^|\s)([/@$#¥])` —— 触发符必须紧跟行首或空白；
  查询词本身不含空白。（¥ 也算官方触发符，用途未挖。）
- 菜单类目：files / sessions / subagents / skills / whiteboards / plugins。
- **files 数据源**：`fileService.readdir`（file channel），参数
  `{path, includeHidden}`。响应 shape 未完全映射（Zemote 的
  `parseFileEntries` 宽松接受 list / `{entries|children|files}`）。
- 渲染侧指令：`:zcode-file-citation:`（单/三冒号 directive，流式期间
  `minimumSingleColonPrefixLength: 6`）——AI 回复里文件引用卡片的实现。

## 消息区官方样式（已确认）

### 主聊天 rows 组件映射（rot switch 表）

userInput→Gat（用户气泡）· assistantText→Kat（直排 markdown）·
reasoning→qat（折叠块）· turnHeader→Jat · toolCall→tot→oY(`ToolCallBlock`→Brt)→
zrt(工具族分发) · subagent→not · timelineMarker→$at。

### 工具卡片（ToolLayout / A7e + O7e + E7e + D7e）

**无卡片容器**——行式布局：
- 头部行 `inline-flex items-center gap-2 text-ui-base(14px)`：
  图标(subtlest) → kindLabel → primaryText → secondaryText → statusNode，
  全部 subtlest 灰（`text-foreground-subtlest`）。
- kindLabel：running 时 `animated-gradient-text`（渐变动画），否则 plain；
  中文文案：读取/搜索/写入/编辑/删除（`chat.toolCall.kind.*`），default 用
  英文 kind 首字母大写。
- 状态文案：等待中/执行中/已执行/执行失败/已拒绝/已停止
  （`chat.toolCall.status.*`）。
- Chevron size-4 默认 opacity-0，hover/展开 100%，展开 rotate-90。
- 展开内容 `pt-2`；**子工具/多文件/问题列表统一左竖线**：
  `ml-2 space-y-2 border-l border-border pl-3.5`。
- 失败态：primaryText 换成 statusLabel（红），statusTooltip 挂错误详情。
- 原始输出 fallback：`px-4 py-3 rounded-xl bg-surface text-ui-xs
  text-foreground-subtle max-h-50 overflow-auto`。

工具族→组件：file-read→Net、file-write→WK（diffCount 角标）、shell→ZK、
search→sq、agent→rtt、todo→Art（默认隐藏）、ask-user-question→Mrt
（kindLabel=正在询问/已询问，secondary=N 个问题）、message→drt/crt、
changesGroup→utt、executeGroup→mtt、default→Dq。

### 文件编辑与 diff（WK + TG/j7e/wG）

- diffCount 角标：`+N -N`，class `text-diff-added` / `text-diff-removed`，
  font-mono，tabular-nums。
- **diff 色值**：`--color-diff-added/removed`：深色 `#46bf72`/`#ff5c5c`，
  浅色 `#1e8a3e`/`#e03131`。
- **diff 行渲染**：行底 = 色 14% 混合（`color-mix 14% transparent`）+
  左 3px 内嵌色条（`boxShadow: inset 3px 0 0 var(--color-diff-*)`）；
  行文本保持**正常前景色**（色彩只在底色与色条）；行号槽 `w-12` 右对齐、
  18% 底色 + 右边框；截断提示行 `px-3 py-1 text-foreground-subtle`；
  容器 `bg-background font-mono leading-relaxed`。

### 交互确认卡（elicitation/permission，"Ask for me"对应物）

- 卡片：`data-elicitation-dialog-card` = `rounded-2xl border border-border
  bg-popover shadow-xs max-h-[min(72dvh,42rem)]`，内体 `p-3 gap-3`。
- 标题 `text-ui-base font-medium leading-5`；问题文本 `leading-6
  text-foreground`（>80 字符可折叠）。
- **选项按钮**（竖排全宽）：`rounded-xl px-3 py-2`，序号 `w-5`，选中
  `bg-selected`，hover `bg-hover`；规则（命令/文件）行
  `font-mono text-ui-base text-foreground-subtle break-all`。
- 键盘：Tab/上下选择，回车确认；倒计时按钮 `min-w-10 tabular-nums`。
- **确认色** `--color-interaction-confirmation-*`：surface 深 `#46bf7229` /
  浅 `#eaf7ee`；foreground 深 `#87d9a4` / 浅 `#166b32`（绿系，非警告橙）。
- 权限文案：需要权限 / 允许 / 始终允许 / 允许本会话 / 始终允许本项目 /
  拒绝 / 始终拒绝；描述文案"后续相同命令不再询问"等。

### turnHeader / timelineMarker / subagent

- turnHeader（Jat）：`border-b border-border py-1 text-ui-sm
  text-foreground-subtle`，内容 `turn · origin · state`。
- timelineMarker（$at）：**左右两条 1px 细线**（`h-px min-w-8 flex-1
  bg-border/50`）夹中央 icon(size-3.5 subtle)+label；running 时
  `animated-gradient-text font-medium`；可点击时 hover 下划线。
- subagent（not）：**一行 subtle 小字** `类型 · 状态 — 摘要`
  （`text-ui-sm text-foreground-subtle`），无卡片无图标。

### 状态面板 / summaryPanel（2026-09-07 第三轮解密）

官方**没有「会话工作台」概念**（i18n 零命中），对应物是 `chat.summaryPanel` +
`chat.statusPanel`——一个悬浮 aside，不是消息流内卡片：

- **摆放**：`aside` `absolute top-0 z-20 pt-4`，`inline` 档 `right-4`，
  `auto` 档 `inset-x-0 flex justify-end px-4`（@min-1280px 有宽屏微调）。
  悬浮在会话区右上角、盖在流上方（z-20），不占排版空间。
- **容器**：`relative overflow-hidden rounded-2xl border border-popover-border
  bg-popover text-foreground shadow-md`，transition 300ms。
- **两档形态**：mini 胶囊 `inline-flex max-h-8.5 w-[--chat-summary-panel-mini-width]
  max-w-[calc(100vw-1.5rem)] flex-col`（高 34px）；面板 `flex max-h-[min(64dvh,32rem)]
  w-80 max-w-[calc(100vw-1.5rem)] flex-col`（320px 宽）。`data-state`
  mini=collapsed / panel=expanded。
- **displayMode 三档设置**（`chat.summaryPanel.displayMode*`）：自动展开 auto /
  始终收起 collapsed / 始终展开 expanded；胶囊↔面板切换键
  `showMini`「收起为胶囊」/ `showPanel`「展开状态」。
- **面板条目**（statusPanel.*）：目标 goal、计划 sessionPlans（打开计划：{title}）、
  更改 changes（git，干净 clean）、分支 branch、终端 terminals、
  智能体 agents（N 运行/已结束）、后台 {count} 个后台运行 + 停止、
  进程/todo 折叠组（当前任务 / 已完成 N 项 / 待处理 N 项 / 前面 N 项 / 后面 N 项）。
  summaryPanel 另有 todoSessionGroup「整个会话」/ todoGoalIterationGroup「第 N 轮迭代」。
- **后台任务**：composer 侧还有 ariaLabel「打开运行中的后台任务：Bash {bashCount} 个，
  子智能体 {subagentCount} 个」；agent 工具行状态「后台运行中，正在同步输出/等待输出」、
  「后台 Agent 过程」；feedback.background.* 是点赞反馈的后台处理提示（另一回事）。
- **计划面板**（planTool.panel.*）：展开/收起计划、复制计划、计划已复制、
  在侧边栏查看计划（open in side pane）、查看完整计划、当前模式 {mode}、
  切换模式、正在同步计划…、暂时还没有结构化步骤。、计划/原始数据 双 tab。
- **待办**（todo.panel.*）：待办 / 当前任务 / todo 已完成 / 切换待办面板（todo 工具行
  默认隐藏，内容进面板，不在消息流渲染）。

Zemote 落地（2026-09-07）：`_ConversationInsights` 常驻「会话工作台」卡整体废弃
（官方无此物），改为 `_StatusSummaryOverlay` 挂在消息列表 Stack 右上角
（top 8 / right 12）：auto 策略（有计划步骤或后台任务才显示）→ mini 胶囊
（高 34px，计划 N/M + N 后台）→ 点开展开面板（宽 min(320, vw-24)、max-h
min(64dvh,512px)、rounded-16、popover 底+hairline+阴影，标题「状态」+收起为胶囊），
内含 计划/文件变更/后台任务 三个可展开 section（复用 _PlanSummary/_FileSummary/
_BackgroundWorkList，后者 ListView→Column 适配无界高度）。displayMode 设置项
与 git changes/branch/terminals 条目未做（移动端无 git 上下文，后续按需）。

### 变更摘要卡（changeSummary）

容器 `rounded-xl border border-border bg-card`，头部行 `h-10 px-2
hover:bg-hover`：chevron size-3 + "N 个文件已更改"（font-medium）+
`+N -N`（tabular-nums diff 色）；展开文件行 `px-1`：chevron + 路径 + 增删；
操作：审查 / 在编辑器中打开 / 撤销（rewind）。

### 用户消息气泡（`data-v4-user-input-bubble`，精确 class）

```
flex max-w-full flex-col gap-2 rounded-xl rounded-tr-xs border border-border
bg-surface px-4 py-3 text-ui-base text-foreground @min-[624px]/conversation:max-w-xl
```

- 行容器：`group/user-row flex flex-col items-end` —— **右对齐**。
- 圆角 `--radius-xl: 0.75rem`（12px）+ 右上 `--radius-xs: 0.125rem`（2px）尖角。
- `bg-surface`（深白5%/浅黑4%）+ `border-border`（10% hairline），**不是蓝色**。
- padding 16/12，max-w 576px，字号 14（`--ui-font-size`）。

### 思考块

- 头部：流式 = `animated-gradient-text font-medium` + 文案“正在思考”；
  完成后 = “思考 · 持续了 N 秒”（`text-foreground-subtlest`）。
- 流式内容底部 16px **渐隐遮罩**（`WebkitMaskImage: linear-gradient(to right,
  transparent 0, black 16px, ...)`）。
- reasoning 紫色系 `--color-trajectory-reasoning: #a78bfa`。

### 时间线轨迹色（`--color-trajectory-*`，深浅同值）

| 角色 | 色值 |
|---|---|
| user | `#60a5fa` |
| assistant | `#2dd4bf` |
| reasoning | `#a78bfa` |
| tool-call | `#f59e0b`（同 warning） |
| tool-result | `#38bdf8`（同 running） |

### 主题 CSS 变量表（深色 / 浅色）

| 变量 | 深色 | 浅色 |
|---|---|---|
| background | `#161616` | `#f8f8f8` |
| header / panel / sidebar | `#202020` | — |
| card / popover / input | `#2b2b2b` | — |
| border | `#ffffff1a`（白10%） | `#0d0d0d1a`（黑10%） |
| border-hover | `#ffffff26` | `#0d0d0d26` |
| hover | `#ffffff0d` | — |
| surface | `#ffffff0d`（白5%） | — |
| 正文字色（实测） | `#dedede` | `#3a3a3a` |

### radius 表

`xs=2px`、`sm=4px`、`md=6px`、`lg=8px`、`xl=12px`、`2xl=16px`。

## Zemote 侧落地（本次已实施）

- `lib/protocol/conversation.dart`：`readdir()`（fileService.readdir 镜像）+
  `parseFileEntries()` 宽松解析（未知 shape 降级为空，UI 隐藏 files 组）。
- `lib/ui/mention_menu.dart`：`MentionMenuBar`（类目分组菜单）、
  `fileMentionMarkdown()` / `sessionMentionMarkdown()`（官方格式直译）。
- `lib/ui/chat_page.dart`：`_updateMentionState`（官方触发规则）、
  `_ensureMentionData`（各数据源独立降级，lesson #4 精神）、
  `_insertMention`（按光标位置替换 token）。
  sessions 数据源 = `subscribeSessionsIndex()`（已有订阅）；skills = `$name`
  注入（兼容现有行为）；files = readdir（**待真机验证响应 shape**）。
- 第一批换壳：`_UserBubble`（官方 12px/右上2px + surface + hairline）、
  `_ReasoningTile`（紫标记 + surface）、theme.dart 新增
  `messageSurface/messageBorder/trajectory*` 常量。

### 用量环形圈（composer 工具条，2026-09-07 抓包解密）

- **环几何**：`svg size-3.5`（14px），viewBox 24，`r=10`，`strokeWidth=4`，
  底环 `opacity:0.25` + 进度环 `opacity:0.7`，`strokeDasharray: C C`、
  `strokeDashoffset: C*(1-ratio)`（C=2π·10≈62.8），`rotate(-90deg)` 从 12 点起，
  `strokeLinecap:round`，颜色 `currentColor`（text-foreground-subtle）。
  外层是 ghost icon-md 按钮；ratio=usedTokens/maxTokens clamp 0..1。
- **悬浮卡（w-80 rounded-xl）**：
  1. 头部行：`chat.contextUsage.title`「上下文容量」(font-medium) + 右侧 mono
     `{used}/{total} ({percent%})`（compact 数字，如 4万/12.8万）。
  2. 分段组成条：`h-2` 圆角条，segments=breakdown 按 chars 降序
     （并列按固定序 messages>system_prompt>meta_user_context>skills>
     tool_prompt>system_tool_schemas>mcp_tool_schemas），颜色=usage-chart-1
     的 5 阶 `color-mix`（100%/78%/58%/42%/28% 混 surface）。
     **theme-zai-* 下 chart-1 = 深 #4099ff / 浅 #0b7fff**（0908 修正：
     旧笔记记的 sky-500/600 是默认主题，remote 客户端恒挂 zai 主题）。
  3. 明细列表：色块(size-2 rounded-sm)+来源名(subtle)+mono 百分比；
     百分比格式 `maximumFractionDigits: p>=0.1?0:1`。
  4. 「平均缓存命中率」行：`border-t` 分隔，mono 百分比；
     **hitRate < 0.78 时整行隐藏**（`OZe` showBelowThreshold:false，
     `EZe=.78`，0908 解密）。
  5. **套餐额度区（fZe，0908 解密，见下节）**。
  6. **Start Plan 今日余额区（gZe，0908 解密，见下节）**。
- **数据源**：快照 `usage.contextWindow`：
  `{usedTokens, maxTokens, cache?: {hitRate}, breakdown?: [{source, chars}]}`。
  breakdown 按 **chars 求和**（同名 source 累加）。旧桌面端可缺 cache/breakdown，
  须宽松解析（Zemote `parseContextWindowInfo`）。
- **来源中文标签**：messages 消息 / system_prompt 系统提示词 /
  tool_prompt 工具提示词 / system_tool_schemas 系统工具 /
  mcp_tool_schemas MCP 工具 / skills 技能 / meta_user_context 其他。
- 文案：`chat.contextUsageDescription`「提示词、工具调用和回复都会共享上下文窗口。」；
  `chat.contextUsage`「上下文已用 {used} / 总量 {total}」；
  compress 相关键（压缩 / 发送 {command} 压缩当前上下文 / 打开 Token 调试）挂在
  quota 区，未随环实现。
- 注：i18n 里的 `chat.planUsage.*` 键（套餐用量/5 小时 Prompt 池等）在 web
  bundle **零引用**——那是桌面端的键；web 真身用 `sidebar.usage.plan.*`。

### 用量 popover 套餐额度区（2026-09-08 解密：NZe/fZe/gZe + 数据链）

- **组件链**：NZe（环+popover 本体）props = `{codingPlanUsageRemaining,
  startPlanBalance, taskUsage(=contextWindow), selectedProvider}`。
  popover 内容顺序：上下文区 → fZe（编程套餐「剩余额度」）→ gZe（Start
  Plan「今日余额」）。区块分隔 `border-t border-border pt-2`，整体 space-y-3。
- **数据源**：`usage-stats` 通道 `getEntitlementSnapshot`（web 端经
  `Ku.toService(getChannel(Wi.UsageStats))` 代理 → `service.method(args)` =
  `channel.call(method, [args])`，与 Zemote channels.call 同构）。参数
  `{includeSubscription:true, preferredProviderId, requirePreferredProvider:true,
  allowDisabledPreferredProvider:true, allowEnvApiKey:false}`；官方每次打开
  popover 触发 onAccess 刷新（带新鲜度缓存）。**桥接前服务是 throw 占位
  Proxy（Z9），桥接后才有真身**。
- **快照 shape**：`{provider:{id}, context, quota:{level, limits:[{type,
  unit, number, remaining, percentage(已用%), nextResetTime(ms),
  usageDetails:[{modelCode, displayName}]}]}, mcpQuota:{aggregate:{…limit}},
  remaining:{isShow,count,percentage,nextResetTime}, subscription:{details},
  unavailableReason}`。
- **limit 选择器（MF/NF）**：type 家族 TOKENS_LIMIT≡CREDIT_LIMIT（YYe）；
  5 小时池 = unit 3 & number 5；每周 = unit 6；工具调用 = TIME_LIMIT unit 5 &
  number 1；ZCode MCP = mcpQuota.aggregate。
- **显示值（PF/IF）**：剩余% = clamp(100-percentage,0,100)；文本 >=10 → 0 位
  小数、<10 → 1 位，null → `--`。
- **重置时间**：5 小时 → HH:mm（uZe）；每周/工具/MCP → `M月d日`（LF date）；
  Start Plan → adaptive（当天 HH:mm，否则日期）。
- **fZe 布局**：标题行「剩余额度」(14 medium) + 右侧重置/刷新钮（eZe：
  refreshing 转圈 → 成功 check → 更多）。栅格 `grid gap-2`，列数
  lI = min(主卡数+MCP?,3) → 1/2/3 列。卡（dZe）：label(subtle 12 truncate)
  → mono 剩余% + ` · ` 重置时间(text-ui-xs subtle，宽度不足时隐藏——
  ResizeObserver 实测) → 6px 圆角条（track surface-hover 深#ffffff1a/
  浅#0d0d0d0d，填充色 5 小时=chart-1/每周=chart-2/工具=chart-3，>0 →
  min-w-1.5(6px)，width 500ms ease-out）。**MCP 行（cZe）**：主卡 ≥3 时
  变全宽单行（border-t pt-1.5：label+info 图标 / 右 mono 值 / 1/3 宽条，
  chart-5 橙）；否则第 3/4 张卡。空态：loading 转圈「同步中...」；
  error/未配置/no_plan → 文案 + 「刷新额度」按钮。
- **gZe（今日余额）**：limits 过滤 CI（(number??unit??0)>0 || remaining>0），
  每模型一卡（hZe）：SI 标签 = usageDetails 的 displayName/modelCode 经
  yI/mZe 美化（GLM-5.2 / GLM-5Turbo 特判）' / ' 连接，空回退 limit.type；
  剩余% = clamp(remaining/number) 0 位小数；条 = bg-success（zai 下 =
  chart-2 同值）。标题右侧可带「升级」按钮（onUpgradeClick）。
- **可见性（BF/AS）**：provider.id 匹配 && unavailableReason≠no_plan &&
  (quota||subscription||remaining)，否则整区隐藏。
- **环色语义（bZe）**：额度重置机会 available → `text-success`；urgent
  （距重置 <3 分钟）→ `bg-warning/10 text-warning`；默认 subtle。配套
  quota-reset celebration（jXe/MXe 状态机 + 彩带动画）——Zemote 未做。
- **theme-zai-* chart 色板**（0908 从 CSS 抓取）：chart-1 深#4099ff/
  浅#0b7fff，chart-2 #46bf72/#1e8a3e，chart-3 #7b5ce5/#9e77ed，
  chart-4 #ff5c5c/#e03131，chart-5 #ff8a30/#e07b00，chart-6 #42c8c8/#0aa7a7。
- Zemote 落地（0908）：`lib/protocol/entitlement.dart`（纯 Dart 解析/
  格式化，test/entitlement_test.dart 锚定）+ `_UsageSheet` 改 Stateful
  （打开即拉快照，失败静默隐藏）+ `_CodingPlanQuotaGrid`/`_StartPlanGrid`/
  `_QuotaCard`/`_QuotaBar`；theme.dart 增 `ZInk.usageChart(n)`/
  `surfaceHover`；usageSegmentColors 换 zai chart-1。

### 模型菜单置顶（2026-09-08 解密：KI/GI/YZe + Ed + wv）

- **供应商 id 枚举（G，`builtin:` 前缀）**：`builtin:zai`、
  `builtin:zai-coding-plan`、`builtin:zai-start-plan`、`builtin:bigmodel`、
  `builtin:bigmodel-coding-plan`、`builtin:bigmodel-start-plan`、
  `builtin:zapi`。`po/Sd` = 七个之一（builtin scope）；`ja/wv` = 除 zapi
  的六个家族 id（**前缀豁免**：PAe 里 providerId ∈ 家族 → 模型 chip 不加
  `{provider}/` 前缀）。
- **菜单分组排序（KI+GI）**：固定优先级 zai-start-plan(0) < zai-coding-plan(1)
  < zai(2) < bigmodel-start-plan(3) < bigmodel-coding-plan(4) < bigmodel(5)
  < zapi(6) < 其他(200)；同级保持原序（stable sort）。**这就是"官方模型
  置顶"的真身**——builtin 家族组恒在最上。家族组（cQe）合并 start/coding/
  apiKey 为一组「Z.ai」/「BigModel」+ badge（Start/Individual/Team/API）+
  连接切换下拉；一方组 `directItems:true` 平铺，其余组走 hover 子菜单。
- **推荐模型集（Ed）**：`['GLM-5.2','GLM-5-Turbo']` —— start-plan 供应商
  的模型列表**只显示**这两个 + 用户显式配置过的模型（YI 过滤器）；默认
  模型 `glm-5.2`（Od），默认思考档 `['max','high','nothink']`（Dd）。
- **组内模型序**：桌面 provider registry 原始顺序（yf），无重排。
- **option schema 补全**：configOptions 的模型项带 `modelProviderId`、
  `modelProviderName`、`modelThoughtLevels`、`modelDefaultThoughtLevel`
  （0908 确认；Zemote ConfigOptionValue 已补 modelProviderId）。
- **Nce 过滤**：origin=injected 或 description 以 "custom model" 开头的
  option 从菜单剔除（Zemote 未做，桌面端 remote 场景暂未见 injected）。
- Zemote 落地（0908）：`groupModelOptions` 按 officialProviderPriority
  排序组（modelProviderId 缺失回退 value 段），一方组内 kRecommendedModels
  置顶（test/composer_menu_regression_test.dart 锚定）；家族合并/badge/
  directItems 未做（Zemote 二级下钻交互保留）。

### 配置两层模型与 draft 收敛（2026-09-09 解密，Fn.current）

官方 composer 配置是**两层**：
1. **workspace draft config**（`It.current`/`$t`，跨会话共享）：用户最近一次的
   模型/思考/模式选择 —— 所有 pane 的 composer 草稿共享这一个变量。
2. **session config**（每会话独立，桌面存储）：`switchModelConfig` 等 envelope
   带 sessionId 作用域，schema payload = `{provider, model, thought,
   runtimeModel?}`（runtimeModel 仅 provider 不在 registry 的恢复路径发）。

**收敛机制（Fn.current）**：发送前置检查里 `t===null`（无消息的同步调用）时，
读 workspace draft，与目标会话 config 比较（`Qe.current?.sessionId===e` 时才有
n，否则 n=null → 无条件推），不一致就发 `switchModelConfig({targetSessionId:e})`。
即官方"新会话/切 pane 继承用户最近选择"是**客户端主动推送 draft**，不是桌面共享。

**Zemote 对照**（2026-09-09 全链路审查，test/side_chat_config_test.dart 锚定）：
Zemote 无 draft 收敛逻辑，chips 读 `_state.config`（会话级）+ `_prep`
（prepareWorkspace 仅回退/选项列表），命令/订阅/帧路由（topic=
conversation/{sessionId}）/state/optimisticPatch 五层全部按 sessionId 隔离，
代码层无主辅共享变量。若实测仍串扰 → 嫌疑收敛到桌面端对 side chat config 的
处理，用 LogStore `[v4]` 帧日志（看主会话 topic 是否收到 config 变化的
state.updated）定位。

### 辅助对话（selection side chat）官方语义（2026-09-07 解密）

- 创建：`createSelectionSideSession {firstInput?: {text}}`——从主会话选区
  「Ask in side chat」发起，pane 组件带 `selectionSideChat:true`。
  桌面 schema 只接受 trim 后非空的 firstInput。
- **官方门控**（pane 内 `!i&&!s` / `s?null:` 系列）：
  - 隐藏 goal 横幅（`goal: s?null:…`）与 暂停/恢复 goal 入口；
  - 隐藏 重试(retryTurn)/分叉(forkAssistant)/编辑重发(editUserQuery) 三个操作；
  - 隐藏 点赞/点踩（onFeedbackChange null）；
  - 禁止嵌套 side chat（selectionActions 关）；
  - slash 面板不注册 `side`/`btw` 命令（那是主会话开辅助对话的入口）。
  保留：消息流、composer、模型/模式/思考切换、用量环。
- Zemote 落地：ChatPage.isSideChat → 隐藏 turnHeader（本轮完成·用时）、goal 横幅、
  assistant 反馈/分叉行、长按操作菜单；用量环照常显示（0608 第十一轮曾误隐，
  已恢复——辅助会话快照自带 contextWindow，缺字段时环自动隐藏）。

### Composer 工具栏完整结构（2026-09-09 全量解密：vRe/gRe/OF/VI/II/NZe + 基元）

**行结构（vRe render）**：输入面 `rounded-2xl border input-border bg-input p-3
transition-colors`（hover 边框变 border-hover，focus-within 变 focused 边框+bg-input-
focused，底色不变）；输入区下方**单行** `flex items-end gap-3(12px)`：
- 左 leading `[data-composer-leading-actions]` = `flex min-w-0 flex-1`，内层
  `[data-composer-leading-content]` `flex shrink-0 gap-1(4px)`：+ 菜单按钮
  （gRe，ellipsis，icon-md 28px）→ 模式 chip（S2e/II）→ Computer Use 按钮
  （xVe，Zemote 无此功能）→ 后台任务按钮（kBe：terminal+N bot+N 计数，
  `@max-[480px]/composer` 起切紧凑单图标——480 是新增容器断点）。
- 右 trailing `flex items-center gap-1.5(6px)`：[编辑态取消按钮 secondary
  icon-md] → submitControl `div.flex.min-w-0.items-center.gap-1` =
  **chips span（`flex min-w-0 shrink gap-1 overflow-hidden empty:hidden`：
  用量环+模型 chip+思考 chip）+ 发送按钮** —— chips 与发送同一行、可被压缩。

**按钮尺寸表（button chunk variants）**：default=h-7(28) gap-1 px-2、xs=h-5、
sm=h-6、lg=h-8、icon=size-7、icon-xs=size-5、icon-sm=size-6、**icon-md=size-7(28px)
rounded-lg + svg size-4(16)**、icon-lg=size-8。chips/发送/+ 菜单/voice 全部
icon-md 或 h-7 —— **整行 28px 等高**。

**发送按钮（icon-md）**：`gap-1 rounded-lg bg-brand text-ui-base
text-foreground-inverse hover:bg-brand/80`，arrow-up size-4 / 提交中 loader
转圈；brand = 深色 #fff / 浅色 #000（zai 主题用墨色，非 sky）。编辑态换成
secondary 取消按钮（square 图标 fill-current，Esc tooltip）。

**“+”菜单（gRe）**：ellipsis 触发（icon-md）→ DropdownMenu `align:start
side:top` **sideOffset=0**（radix 默认）`w-52(208px)`；项：paperclip 添加附件
（无 tag）、at-sign「使用 @ …」（tag @）、square-slash「使用 / …」（tag /）、
dollar-sign「使用 $ …」（tag $）；tag = `rounded bg-tooltip-tag px-1 font-mono
text-ui-sm font-medium text-tooltip-tag-foreground`（tag 底深 #363636/浅
#e6e6e6，字深 #adadad/浅 #5c5c5c）；触发符在文案内嵌（fRe）。

**模式 chip（S2e/II）**：**每模式专属图标（FI，非统一 sliders-horizontal）**
——bypass/full-access/yolo → shield-alert（+文字 warning 色 expanded 态）；
default/build → hand；plan → notepad-text；auto/acceptEdits/agent/autoEdit/
dontAsk/edit → shield-check；缺省 hand。compact：<@xl(576) `size-7 justify-center
gap-0 p-0`（chevron hidden）；≥@xl `h-7 w-fit justify-between gap-1 pl-2 pr-1.5`。
菜单 w-64(256)、item min-h-13 两行（名称+描述）。

**弹出框定位汇总（He 点名）——全部 side:top 从触发器上方弹出**：
| 弹层 | side | align | sideOffset | collisionPadding | 宽 |
|---|---|---|---|---|---|
| 用量 popover（GYe） | top | 默认 | **2** | 默认0 | w-80(320) `!rounded-xl !shadow-md` |
| 模型菜单（OF→Qe） | top | start | **0**（默认） | 默认 | w-48(192)/分组 w-max min-w-48 max-w-[100vw-2rem] max-h-72 |
| 思考菜单（VI→$r） | top | start | **4** | **8** | 默认 min-w-32 自适应 |
| 模式菜单（II→$r） | top | start | **4** | **8** | w-64(256) |
| +菜单（gRe→Qe） | top | start | **0**（默认） | 默认 | w-52(208) |
菜单容器基元：`z-[60] rounded-xl(12) border-popover-border bg-menu p-1
!shadow-md`，动画 100ms fade+zoom-95+按方向 slide-2；radix avoidCollisions
（越右缘翻 align，越上缘翻 side）。用量环触屏语义：pointerDown 且 hover:none
立即开（不等 tap）。

**菜单行**：min-h-8(32) pl-2 pr-8 图标 size-4；选中项**不变蓝**——文字正常
foreground + check 图标 `text-foreground-subtle`；模型分组 provider 行无图标
（仅文字+badge）；footer（管理模型）sticky bottom bg-menu。

**主题补充**：foreground-subtle=深 #d4d4d499/浅 #26262699（60% alpha）；
foreground-inverse=深#000/浅#fff；success #46bf72/#1e8a3e；warning
#ff8a30/#e07b00；menu-hover #363636/#f0f0f0。

（以下为 0707 轮解密，断点与 OF/VI 细节仍有效：）
### Composer 工具栏断点（容器查询，2026-09-07 第二轮解密；OF/VI 组件 0707 晚三轮补全）

composer 容器名 `composer/inline-size`，Tailwind v4 容器档位（**容器宽**，
非视口宽；移动端等效=窗口宽）：
`@max-sm` <24rem=384px、`@sm` ≥384、`@lg` ≥512、`@xl` ≥576、`@2xl` ≥672。

各 chip 形态（右侧组；触发按钮公共类 `gap-1 rounded-lg px-1.5 py-1.5 text-ui-base`）：
- **模型 chip（OF，lucide `package` 图标）**：
  - `<384`：`@max-sm/composer:size-7 justify-center gap-0 p-0` 28px 方形，
    图标显示（`triggerIconClassName: inline-flex @sm/composer:hidden`），
    label/chevron 均隐 → 纯图标。
  - `≥384`：**图标隐藏**（icon 只在 <384 出现！），label 显示
    （`labelVisibilityClassName: hidden @sm/composer:inline-flex`）+
    chevron（`indicatorClassName: hidden @sm/composer:block`，size-3.5
    text-foreground-subtle）。
  - `≥672`：label 前追加供应商前缀 `{providerName}/`（DF 渲染器，
    `triggerLabelPrefixClassName: hidden @2xl/composer:inline`）。
    前缀逻辑 PAe：providerName 为空或 providerId 是一方（ja()，builtin/glm）
    → 无前缀。aria/title 用 fullLabel。
  - tooltip 固定 = `chat.toolbar.model.label`「选择模型」。
  - pending 切换时 label 换 pendingLabel + 转圈 `animate-spin size-3.5`。
- **思考强度 chip（VI，lucide `brain` 图标 size-4 text-current 常显）**：
  - `<384`：同上 size-7 方形 → 纯图标。
  - `384–576`：图标+**绿色竖条**：`relative w-1 self-stretch overflow-hidden
    rounded-full bg-current/10`（全高≈16px），填充 `absolute bottom-0 w-full
    rounded-full bg-success transition-[height] duration-300
    ease-[cubic-bezier(0.34,1.56,0.64,1)]`（300ms 回弹），`F>0 → min-h-1`(4px)。
    显示条件 `hidden @sm/composer:inline-flex @xl/composer:hidden`。
  - `≥576`：竖条隐藏，label 显示（`min-w-0 whitespace-nowrap` +
    `hidden @xl/composer:inline-flex`）；chevron `hidden @xl/composer:block`。
  - 填充公式：`F=(D?0:max(0,O+1-P))/max(1,w.length-P)`，P=off 选项数
    （WZe 过滤器），O=当前项 index（zI 按 rank 排序后）。
  - tooltip：label 可见时 = label 文本，不可见时 =
    `chat.toolbar.thoughtLevel.tooltip`「思考级别」。
  - value→i18n：HZe[RI(value)]（RI 归一化，UZe 同构）；单选项时无 popover
    （data-thought-level-fixed）。
- **模式 chip（II 组件，lucide `sliders-horizontal` 图标）**：<576px → size-7
  纯图标（size-7 justify-center gap-0 p-0，chevron hidden）；≥576px → 图标+文本
  （w-fit gap-1 pl-2 pr-1.5）。
- 工具条左右分组：左 = 附加/更多 + 模式 chip；右 = 用量环 + 模型 + 思考
  （+ 模式），`justify-end`。
- **应用壳断点（非容器查询）**：mobile viewport =
  `matchMedia("(max-width: 767px) and (hover: none) and (pointer: coarse)")`
  ——desktop shell（侧边栏）出现在宽度 ≥768px **或**非触屏设备。
  Zemote 有意下调到 640dp 以覆盖折叠屏窄展开态（~690dp）与 8 寸平板横屏
  （~640dp）；主从布局 720dp（列表 360 + 聊天 ≥360）。

Zemote 落地（0707 晚）：ComposerChip 增 `showIcon`/`prefixLabel`/方形
iconOnly（28×28 居中零内边距）/`_ThoughtLevelBar`（AnimatedFractionallySizedBox +
Cubic(0.34,1.56,0.64,1) 300ms + 4px 最小填充）；模型 chip 图标
radio_button→`Icons.inventory_2_outlined`（package），<384 图标、384-672 纯文字
（无图标！）、≥672 `{provider}/` 前缀（builtin/glm 豁免，`_modelPrefixAndLabel`），
tooltip「选择模型」；思考 chip 竖条改全高动画，tooltip 按官方动态（<576「思考级别」
/≥576 档位文本）。

## 待挖清单（下次抓取时继续）

- [ ] assistant 正文容器 / turnHeader / timeline marker 的精确 class
      （reasoning 渐隐遮罩组件 `dX`、`uX` 变量附近可挖到更多）。
- [ ] readdir 响应完整 shape（真机打 `[conversation] readdir` 日志即得）。
- [ ] files 菜单的本地索引/过滤实现（`PIe` → `jIe`/`AIe`，官方可能预建索引）。
- [ ] `¥` 触发符的用途。
- [ ] skill mention 的 value 字段内容（`Xx(e,t)` 的 t 来源）。
- [x] ~~用量环 / 上下文明细 / 缓存命中率~~（2026-09-07 已解密，见「用量环形圈」节）。
- [x] ~~辅助对话语义~~（2026-09-07 已解密，见「辅助对话」节）。
- [x] ~~状态面板/summaryPanel（工作台对应物）~~（2026-09-07 已解密，见「状态面板」节）。

### 2026-09-07 晚第四轮补充解密（He 反馈批）

- **工具条图标字形**：模型 chip = lucide `package`（箱子）；思考 chip =
  `brain`；模式 chip = `sliders-horizontal`；附加 = `paperclip`；更多 =
  `ellipsis`；发送 = `arrow-up`；停止 = `circle-stop`；文件变更 =
  `file-diff`；计划 = `list-todo`。已抓取 path 数据生成
  lib/ui/official_icons.dart（LucideIcon CustomPaint 渲染：24 网格、stroke 2、
  round cap/join；懒加载 chunk 格式 `var t=[[…]],n=e(`name`,t)`）。
- **OF 触发按钮完整 class**：`w-fit justify-between gap-1 rounded-lg pl-2
  pr-1.5 text-ui-base`；triggerIconClassName 调用点覆盖
  `inline-flex @sm/composer:hidden`（**图标只在 <384 出现**）。
- **goal 横幅语义**：i18n 键 chat.goalBanner.label「目标」、
  chat.goalVerification.checking/complete/incomplete/cancelled =
  目标校验中/目标已完成，任务结束/目标未完成，任务继续/目标校验已中断；
  协议 goal 状态枚举含 completedSuccess（Zemote 曾把它原文渲染出来）。
  终态不常驻横幅，结果走 goalVerify 时间线标记。
- **用户消息编辑**：官方在原气泡内原地编辑（inline），无独立对话框。

### 流光真身与工具族图标（2026-09-08，v0.6.6 批）

- **样式真身在 CSS 资产里**（`assets/index-BMndL2ru.css`，只抓 JS 拿不到）：
  `.animated-gradient-text{background:linear-gradient(90deg, strong 0%, strong 34%,
  soft 50%, strong 66%, strong 100%); color:#0000; background-size:300% 100%;
  animation:4s linear infinite gradient-flow}`，
  `@keyframes gradient-flow{0%{background-position:100% 0}50%{background-position:0 0}to{0 0}}`
  ——前 2s 扫过后 2s 停驻。变量：dark strong=#fff soft=#ffffff38（实测 20%）；
  light strong=#0d0d0d soft=#0d0d0d38。另有 `.animated-gradient-text-subtle`
  （strong=foreground-subtle）。
- **层级**：进行中行=foreground 墨色+流光标签；已完成行=`text-foreground-subtlest`
  （更浅）。
- **turnHeader 时长**（BX 函数）：`activeMs ?? max(endedAt-startedAt,0) ?? now-startedAt`。
- **rowsRange**：请求 `{sessionId, beforeRowId?, limit(min1,max=rowsRangeMaxLimit)}`，
  响应 `{rows:[...], atSeq, atLogEpoch, hasMore}`；官方 loadOlder 默认 limit=
  snapshotTailWindowRows，loadAllOlder 循环 limit=rowsRangeMaxLimit 到 hasMore=false。
- **工具族图标**（lucide，全部已入库 official_icons.dart）：brain/terminal/search/
  earth/globe/file-diff/list-todo/bot/git-branch + composer 触发器 sliders-horizontal/
  package + 操作行 copy/thumbs-up/thumbs-down + plus 菜单 paperclip/ellipsis。
  官方**没有**独立铅笔字形（编辑族用 file-diff）、没有 split（分叉用 git-branch）、
  没有每模式专属图标（模式触发器统一 sliders-horizontal）。
- **加号菜单**（He 官方截图）：添加附件 / 使用 @ 添加上下文 / 使用 / 选择能力 /
  使用 $ 选择技能——四项，横向排开；无压缩/用量/计划项。
- **辅助对话**：独立 sessionId 携带主会话上下文；隐藏 goal/重试/分叉/编辑重发/
  点赞点踩/嵌套入口；保留完整 composer（配置按会话独立）+ 用量环。
