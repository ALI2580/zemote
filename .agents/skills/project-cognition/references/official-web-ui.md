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

## 待挖清单（下次抓取时继续）

- [ ] assistant 正文容器 / turnHeader / timeline marker 的精确 class
      （reasoning 渐隐遮罩组件 `dX`、`uX` 变量附近可挖到更多）。
- [ ] readdir 响应完整 shape（真机打 `[conversation] readdir` 日志即得）。
- [ ] files 菜单的本地索引/过滤实现（`PIe` → `jIe`/`AIe`，官方可能预建索引）。
- [ ] `¥` 触发符的用途。
- [ ] skill mention 的 value 字段内容（`Xx(e,t)` 的 t 来源）。
