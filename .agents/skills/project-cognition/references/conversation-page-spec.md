# 官方对话页全量规格（Conversation Page Master Spec）

> 2026-09-07 从 zcode.z.ai/remote/v4 bundle（app_version 3.7.7 构建）全量逆向。
> 抽取物：880 个 `chat.*` i18n 键中文值（/tmp/chat_i18n.json，本文件沉淀关键部分）、
> 主 bundle 组件 class 串与逻辑门控。**这是对话页复刻的权威清单**；
> 视觉/样式细则见 official-web-ui.md，本文件管「结构 + 内容 + 逻辑」。
> **版本核对（2026-09-07）**：桌面端 3.7.7 → 3.11.2 后重抓 index.html 与全部资产，
> 主 bundle/IntlProvider/CSS 的 MD5 与 3.7.7 时代逐字节一致（Vite 内容哈希文件名全部相同）
> ——**Web 远程控制页没有随桌面 3.11.2 重新构建**，本规格继续有效。
> app_version 参数只是桌面端自报版本，不代表 web bundle 变化。
> 状态标记：✅ Zemote 已对齐 / 🟡 部分 / ❌ 缺失 / ➖ 桌面专属不适用。

## 1. Turn 结构与折叠（`got` 组件 + `PX` turnHeader）

官方把一轮对话折叠成一个「历史消息」单元（Collapsible，class
`history-message flex flex-col`，块间距 `mt-5`=20px）：

```
[用户消息气泡]
[⌄ 已工作 3m2s        ← 可折叠触发行（仅在 turn 有 assistant 内容时出现）]
[assistant 内容：reasoning / 工具行 / 正文 / changeSummary …]
```

- 触发行：`flex w-full border-b border-[var(--color-border)]/50 pb-2`，
  内部 `flex items-center gap-2 text-left text-ui-base text-foreground-subtle`，
  文本 truncate；chevron size-4 subtlest opacity-70，**闭合朝右、展开转 90° 朝下**。
- 文案（chat.history.*）：running=`工作中 {duration}`；interrupted=`已停止`；
  completed+duration=`已工作 {duration}`；completed 无 duration=`已处理`。
  duration=workStatus.durationMs，格式 chat.history.duration.{second,minute,hour,day}。
- **默认展开逻辑**（assistantHistoryDefaultOpen）：`forceOpen ||
  (isLastTurn && running) || (仅此一个 turn && 尚无正文 && 有工作行)`。
  即：**运行中的最新 turn 展开，turn 完成 → 自动收起**；用户手动展开/收起
  覆盖，但默认值翻转时用户覆盖被重置（useEffect 监听 default 变化）。
- 时长文案换行规则：秒/分/时/天 单位分别为 秒/分/时/天（1时5分3秒 形态）。

**Zemote 状态**：🟡 → 本轮实施：_TurnGroupWidget 改造为折叠模型 +
turnHeader 文案对齐（替换「本轮完成 · 时长」）。

## 2. 消息区各 row（rot switch 表 → 组件）

| row kind | 官方组件 | 关键规格 | Zemote |
|---|---|---|---|
| userInput | AX/Gat 气泡 | surface+hairline+12px 圆角右上 2px；操作行=编辑/复制/分叉（仅 latest） | ✅ |
| assistantText | AX/Kat | 直排 markdown；操作行仅 latest（hideAssistantActions:!latest）；deferred 显示 | ✅ |
| reasoning | qat | 无框纯文本行；chevron 交互后短暂出现；完成态「思考 · 时长」 | ✅ |
| toolCall | tot→ToolLayout | 行式灰字；族图标；完成态无状态文字；+N -N 角标；chevron 交互显示 | ✅ |
| turnHeader | PX | 见 §1 | 🟡 实施中 |
| subagent | not | 一行 subtle 小字 `类型 · 状态 — 摘要` | ✅ |
| timelineMarker | $at | 双细线夹中央 icon+label；running 渐变动画 | ✅ |
| changeSummary | utt 卡 | 见 §3 | ❌ → 本轮实施 |
| mailMessage | 邮箱卡 | 「来自 {sessionId} 的新消息」+ 恢复 | ➖ 未实现 |
| hookInvocation | hooks 行 | chat.hooks.state.{running,completed,failed,blocked,cancelled,timedOut}，来源 plugin/project/user | ➖ 缺失 |
| cuaGroup | 电脑操作卡 | chat.toolCall.cua.*（68 键） | ➖ 桌面专属暂缓 |

## 3. changeSummary 卡（utt，规格全量）

容器 `rounded-xl border border-border bg-card`；头部 `h-10 px-2 hover:bg-hover`：
chevron size-3 + 「{count} 个文件已更改」（font-medium）+ `+N -N`
（tabular-nums，diff 色）；展开文件行 `px-1`：chevron + 路径 + 增删计数。
操作：审查（review）/ 在编辑器中打开（openInEditor，移动端不适用）/ 撤销（rewind）。
撤销对话框（rewindDialog.*）：预检「可安全撤销 N / 不能安全撤销 N / 已忽略 N」，
原因枚举：bash 修改已忽略 / 缺少 checkpoint / 无法读取 checkpoint / 旧 checkpoint
无法安全还原 / 当前文件已被外部修改 / 无法读取当前文件。
已撤销 toast=`已撤销`；重新应用=`重新应用`。
**Zemote**：❌ changeSummary 行当前混入 insights；本轮实施为独立卡片
（撤销走既有 applyFileRewind 路径）。

## 4. 状态面板（statusPanel/summaryPanel，会话工作台卡官方形态）

浮动 `aside`（absolute top-0 right，conversation ≥1280px 时 `right-4`），
mini 胶囊 / 展开面板两态，displayMode 三档（自动/始终收起/始终展开）：
- **Git 工具**（environment）：更改行（icon+「更改」+`+N -N` mono diff 色，可点开审查）、
  分支行；干净=「干净」。
- **目标**（goal）：目标状态。
- **计划**（plan/sessionPlans）：「打开计划：{title}」。
- **智能体**（agents）：`{count} 运行` / 已结束；可打开子智能体会话。
- **进程**（todo）：已完成 N 项折叠 / 待处理 N 项折叠 / 前面 N 项 / 后面 N 项。
- **终端**（terminals）；**后台任务**：`{count} 个后台运行`，行级停止。
**Zemote**：🟡 _ConversationInsights 是自创聚合（文件摘要+后台任务），
官方为浮动面板+胶囊形态；后续轮次重构（本轮不动，避免一次改太多）。

## 5. composer 上方与 composer

- **后台任务胶囊**（composer 顶部）：「打开运行中的后台任务：Bash N 个，
  子智能体 M 个」tooltip；运行中才出现。🟡 _BackgroundWorksBar 已有近似。
- **上下文用量环**：见 official-web-ui.md 用量环形圈节。✅
- **mention/slash/skill**：官方触发 `(^|\s)[/@$#¥]`。✅
- **队列**（chat.queue.*，20 键）：待发送消息（N）/ 编辑（退回输入框）/
  移除 / 立即 / 加入队列说明 / 暂停三态（出错、手动中断、通用）+ 继续 /
  发送确认对话框（要清除之前已排队的 {count} 条消息吗？）。
  🟡 _QueueBar 有基础，缺暂停态与发送确认。
- **输入增强**：chat.promptEnhance.*（9 键，提示词增强）。❌ 待挖。

## 6. 空态（chat.empty.*）

- 时段问候（greeting）：morningEarly 早上好呀，新的一天开始啦 /
  morning 上午好呀，有什么想让我帮忙的吗 / noon 中午好呀，要不要先休息一下 /
  afternoon 下午好呀，接下来交给我吧 / evening 晚上好呀，今天辛苦啦 /
  lateNight 夜深啦，别忘了照顾好自己哦。
- 标题=`开始对话`；描述=`开始在 {workspace} 项目新建任务`。
**Zemote**：🟡 → 本轮实施时段问候。

## 7. 消息级交互（chat.message.*）

复制/赞/踩/分叉/编辑/重试；大消息预览（bodyPreview：这条回复较大，当前只显示
预览（N / M）+ 查看完整消息 + 重试）；工具快照加载全部
（N 个工具调用仅预览 N / M）；toolSlice（已显示 N / M 条工具调用 + 加载更多）；
分叉错误枚举（找不到分叉点 checkpoint / 原对话已不存在 / 任务结束后可分叉 /
当前 agent 暂不支持分叉）。
**Zemote**：🟡 基础操作齐；预览分页（bodyPreview/toolSlice）❌ 后续轮次。

## 8. 压缩与重试状态

- contextCompaction（8 键）：正在压缩上下文 / 上下文已压缩（自动）/ 压缩失败 /
  已中断 / 正在重试压缩上下文（N/M）/ 已是最新，无需压缩。
  🟡 timelineMarker 已显示 compact 标记，失败/重试态缺失。
- apiRetryStatus：`{attempt}/{maxRetries}` 重试指示（HTTP 状态并显）。❌

## 9. 编辑重置（chat.edit.*）

编辑并重发时「对话 + 文件重置」选项：恢复本轮文件、重置对话并发送 /
本轮没有可安全恢复的文件改动 / 压缩中或有待处理交互时不能重置文件 /
文件冲突对话框（仅重置对话并发送）。❌ 后续轮次。

## 10. 实施批次

- **本轮（2026-09-07）**：§1 turn 折叠+文案、§6 时段问候、§3 changeSummary 卡、
  块间距 mt-5 节奏对齐。
- 下轮：§4 状态面板重构、§5 队列暂停/发送确认、§7 预览分页。
- 待真机数据：§2 hookInvocation/mailMessage/cuaGroup、§8 apiRetry、§9 编辑重置。
