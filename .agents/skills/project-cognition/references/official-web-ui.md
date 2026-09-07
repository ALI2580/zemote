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
     浅色 chart-1=sky-600 `#0284c7`，深色=sky-500 `#0ea5e9`。
  3. 明细列表：色块(size-2 rounded-sm)+来源名(subtle)+mono 百分比；
     百分比格式 `maximumFractionDigits: p>=0.1?0:1`。
  4. 「平均缓存命中率」行：`border-t` 分隔，mono 百分比。
  5. quota/plan 区（codingPlan 相关，Zemote 不做）。
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
  assistant 反馈/分叉行、长按操作菜单；用量环照常显示。

### Composer 工具栏断点（容器查询，2026-09-07 第二轮解密）

composer 容器名 `composer/inline-size`，Tailwind v4 容器档位（**容器宽**，
非视口宽；移动端等效=窗口宽）：
`@max-sm` <24rem=384px、`@sm` ≥384、`@lg` ≥512、`@xl` ≥576、`@2xl` ≥672。

各 chip 形态（右侧组）：
- **模型 chip（OF）**：<384px → size-7 方形纯图标（icon 类 `inline-flex @sm:hidden`）；
  ≥384px → 图标+模型名（label `hidden @sm:inline-flex`）；≥672px → 模型名前
  追加供应商前缀（prefix `hidden @2xl:inline`）。
- **思考强度 chip（VI）**：<384px → 纯图标；384–576px → 图标+**绿色竖条**
  （`w-1`(4px) 全高圆角条，轨道 `bg-current/10`，填充 `bg-success` 从底部
  长出，`transition-[height]`）；≥576px → 图标+文本标签（竖条隐藏）。
  竖条填充高度 `F = max(0, idx+1-off) / max(1, len-off)`：选项先按强度
  rank 排序（off 族 0 / low 1 / medium 2 / high 3 / enabled 4 / xhigh 5 /
  max 6），off 选项填 0，enabled 档位按名次进度填充。
- **模式 chip**：<576px → size-7 纯图标；≥576px → 图标+文本。
- 工具条左右分组：左 = 附加/更多 + 模式 chip；右 = 用量环 + 模型 + 思考
  （+ 模式），`justify-end`。
- **应用壳断点（非容器查询）**：mobile viewport =
  `matchMedia("(max-width: 767px) and (hover: none) and (pointer: coarse)")`
  ——desktop shell（侧边栏）出现在宽度 ≥768px **或**非触屏设备。
  Zemote 有意下调到 640dp 以覆盖折叠屏窄展开态（~690dp）与 8 寸平板横屏
  （~640dp）；主从布局 720dp（列表 360 + 聊天 ≥360）。

## 待挖清单（下次抓取时继续）

- [ ] assistant 正文容器 / turnHeader / timeline marker 的精确 class
      （reasoning 渐隐遮罩组件 `dX`、`uX` 变量附近可挖到更多）。
- [ ] readdir 响应完整 shape（真机打 `[conversation] readdir` 日志即得）。
- [ ] files 菜单的本地索引/过滤实现（`PIe` → `jIe`/`AIe`，官方可能预建索引）。
- [ ] `¥` 触发符的用途。
- [ ] skill mention 的 value 字段内容（`Xx(e,t)` 的 t 来源）。
- [x] ~~用量环 / 上下文明细 / 缓存命中率~~（2026-09-07 已解密，见「用量环形圈」节）。
- [x] ~~辅助对话语义~~（2026-09-07 已解密，见「辅助对话」节）。
