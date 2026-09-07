# 踩坑记录（按主题分类，源自 CHANGELOG 与修复历史）

修 bug 或设计新功能前扫一遍对应主题；修复后把新经验追加到这里。

## 连接与重连

- **后台切回连不上**（0.5.1-beta.2）：从其他应用返回、锁屏解锁后停在"重连中"无法恢复。
  多个重连请求并发时旧 WebSocket 事件覆盖新连接状态。教训：重连路径要防并发覆盖。
- **误判"被踢下线"**（0.5.1-beta.2）：连接冲突被当成永久踢下线。认证阶段先执行一次干净
  重连再判定。
- **bridge 不恢复**（0.3.5）：relay 心跳超时触发重连时跳过了 `reconnecting` 状态，导致配对
  后 bridge 不恢复。状态机迁移不能跳步。
- **重连后发消息超时**（0.3.2/0.3.3）：relay 断开时立即标记 bridge 降级，命令在恢复前排队
  （`waitHealthy`）；发送超时后等重连并自动重试一次；恢复循环重试到成功为止。另外
  `sendText` 在连接健康时超时**不**自动重发（避免重复消息），只在断线中重试。
- **冷启动预热超时**（0.3.5）：会话首次订阅放宽到 60s，避免打开聊天页时误判"连不上"。
- **泄漏**（0.3.3）：`ZemoteClient.dispose()` 必须释放活动桥；订阅初始化失败要清理事件
  监听和定时器。

## 协议帧与握手

- **单元素帧 `[200]` 被误杀**（0.4.2/0.4.3，两次回归）：合法 Channel Initialize 帧
  `[200]` 被边界检查判为畸形 → `listTasks` 和 sessions-index 永远等待 → 会话列表无数据。
  教训：帧校验边界以官方行为为准，回归测试锚定。
- **握手版本协商错误**（0.4.2/0.4.3）：Conversation V4 握手曾错误携带 Zemote 应用版本
  （`0.x`）参与桌面能力协商。正确做法：协议能力版本固定 `3.6.5`。
- **首条消息发不出**（0.3.1）：订阅未就绪时命令被丢弃。对齐官方 composer：普通文本首条
  消息随 `createSession(firstInput)` 一起发送；附件/目标指令路径发送前等待订阅建立。
- **ack 不检查**（0.3.1）：`sendText` / `sendGoalCommand` 的 ack 被忽略导致发送失败静默。
  所有发送路径必须检查 ack 并提示具体原因。
- **交互格式错**（0.4.1/0.3.2）：AI 多问题交互的答案是一次性 `accept` 提交；权限请求选项
  按官方 schema + 自由输入；`questions` 表单（单选/多选）。

## 数据合并与状态

- **双数据源互相清空**（0.4.3）：channel 任务数据与 sessions-index 实时数据必须独立保存
  再合并；空快照、晚到响应、订阅失败都不得清空对方。
- **跨工作区串数据**（0.4.1）：从聊天页返回后要按当前工作区 sessions-index 重新合并会话
  列表，避免缺项、旧顺序、跨工作区任务混入。会话列表缓存按工作区隔离（0.5.0）。
- **骨架屏卡住**（0.4.2）：sessions-index 快照到达后立即结束加载，不被旧任务 RPC 的超时
  骨架屏遮住；空列表也要正常结束加载。

## 消息渲染

- **气泡顺序颠倒 / 拆分**（0.3.2/0.3.3/0.3.4）：保留服务端原始段落顺序
  （思考→文本→工具→文本…），连续文本合并，一条回复一个气泡、一个点赞区（只在最后一个
  文本段）；`turnId` 中途变化不拆散分组。
- **滚动定位**（0.3.4/0.3.5/0.4.1）：打开聊天页完成初始历史加载后强制定位到最新；向上翻
  历史时流式更新不拉扯；加载更早消息后若在底部则自动回底。

## UI / 主题

浅色主题下"白底白字/不可见"是本仓库反复出现的回归类型，中过招的组件：代码块与行内代码、
推理面板、工具卡片、状态点、Diff 内容、骨架屏、Markdown 标题/列表/表格（0.2.1/0.3.2/
0.4.3/0.4.4/0.5.2）。**规则：任何颜色必须来自 `ui/theme.dart` 的 ZInk 主题感知体系，
禁止硬编码颜色。** 新增 UI 后浅色/深色都过一遍。

布局类：任务首页固定模块过多曾把任务列表压到半屏（0.5.2）；低频操作收进按需展开；文案
不直接显示内部状态值（如 `completedSuccess` 要映射成人话）。

## Android 平台 / 更新

- **APK 按 ABI 拆分 + MD5**（0.4.2）：`arm64-v8a` / `armeabi-v7a` / `x86_64` 三个产物各带
  `.md5`；安装前校验。
- **下载健壮性**（0.4.1/0.4.2）：断点续传；本地已有且 MD5 正确的包跳过下载直开安装器；
  APK 存放在应用内部 `files/update` 目录，FileProvider 只暴露该目录；升级完成后靠
  `MY_PACKAGE_REPLACED` 广播自动清理旧包。
- **Beta 通道重复提示**（0.5.2-beta.2）：更新检查曾用旧硬编码版本常量，装了 Beta 后反复
  提示同一版本。版本常量单一来源（`pubspec.yaml` → `update/app_version.dart`）。
- **签名统一**（0.2.1）：正式 keystore 本地 + CI（GitHub Secrets base64 注入）同一签名，
  否则覆盖安装失败。
- **凭据不进备份**：Android `allowBackup` 禁用 + 凭据加密存储（`credential_cipher.dart`）。

## 安全红线

- 远程控制 URL 含 `sid/hash`，等同设备访问凭证：不入库、不写进测试代码、不外发。
  集成测试用环境变量 `ZEMOTE_PROBE_URL` 注入。
- 拒绝非 HTTPS/WSS 的连接 URL。
- 凭据泄露的补救：桌面端重新生成远程控制二维码，旧凭据立即失效。

## 发版与仓库迁移（2026-09-06，v0.5.3 发版实战）

- **发版守护测试是第三处版本常量**（第一次 CI 失败的直接原因）：`update_checker_test.dart`
  的 "bundled app version matches the release currently being built" 断言 `appVersion` /
  `appBuildNumber` 的具体值。发版 = 三处一起改：`pubspec.yaml`、`app_version.dart`、
  该测试。改完 CI 全绿才准打 tag。
- **比较测试不得依赖 appVersion**：`compareVersions` 语义测试曾把 `appVersion` 混进断言
  （`compareVersions('0.5.2', appVersion)`），版本一 bump 就崩。已改为字面量，后续发版
  不再触碰；新增版本测试同理，只测纯函数语义。
- **仓库指向硬编码四处**：原作者仓库地址曾出现在 `update_checker.dart`（更新检查 API，
  3 处）、`settings_page.dart`（关于页，2 处）、`README.md`（badges）。迁移/fork 后必须
  全局替换，否则应用内更新检查打的是别人的 Release API。
- **文档声称的安全边界要实测**：README 声称 `.gitignore` 已忽略签名文件（`*.jks` /
  `key.properties`），实际条目缺失（已补）。验证方式：`git check-ignore <路径>`，不要信
  文档描述。
- **`keytool -printcert -jarfile` 验不了现代 APK**：Flutter 产物是 v2/v3 签名（无 v1 的
  META-INF/*.RSA），该命令报"不是已签名的 jar 文件"。验证线上包签名的可行路径：解包
  APK Signing Block 抠出 DER 证书 → `keytool -printcert -file`；或看构建日志的签名步骤。
- **CI 绿色 ≠ 正式签名**：Secrets 缺失时 build-apk.yml 只打 WARN 并回退 debug 签名，构建
  依然成功。重要发版要么确认 Secrets 已配置，要么实拆 APK 验证证书 CN。
- **tag 强推只允许发生在 Release 生成前**：修 CI 后曾 `tag -f` 重指向新提交并强推——
  当时 Release 还没产出，安全；一旦 Release 已发布，强推 tag 会造成版本事实分叉，禁止。

## 交互实现模式（2026-09-06，v0.5.4 实战）

- **流式列表滚动拉扯的根因是距离启发式**：旧代码 `pixels > max - 400` 就跟随——流式输出
  时 `maxScrollExtent` 持续增长，静态阈值反复成立，每帧把翻历史的用户往回拽；且普通
  controller 监听分不清用户拖动与程序动画，动画本身又会把 `pixels` 拉回阈值内形成循环。
  正确模式：`_onScroll` 只在 `userScrollDirection != ScrollDirection.idle`（用户拖动/惯性）
  时更新吸底标志（`animateTo` 的 DrivenScrollActivity 期间恒为 idle），跟随只在吸底时执行；
  `ScrollDirection` 需从 `package:flutter/rendering.dart` 导入。判定用"距底部 40px"只在
  **用户滚动时**比较一次，不参与跟随决策。
- **AnimatedSize 必须常驻挂载**：条件渲染 `if (expanded) AnimatedSize(...)` 会让收起动画
  永远不生效——收起时组件连同动画一起被移除，内容瞬跳。手风琴标准写法：每个分组的
  动画容器常驻，child 在"内容"与"零高度盒"（`SizedBox(width: double.infinity)`）之间切换，
  靠 child 尺寸变化驱动展开与收起两个方向的动画。
- **缓存类状态要清理"旧 key"**：输入框草稿按 sessionId 缓存、新会话按 workspaceKey 缓存。
  首条消息发送后 sessionId 从 null 变为真实 id，若不清旧 key，返回再新建会话会冒出已发送
  的内容。模式：会话创建成功时显式 `cache.remove(旧key)`，发送清空控制器会自动写空新 key。
- **宽屏断点用 640dp，别用 800/840**：折叠屏内屏展开宽度约 717dp，840 阈值会把它漏进
  窄屏路径。辅助对话侧滑面板实现：`showGeneralDialog` + `Align(centerRight)` +
  `SlideTransition`（barrierDismissible 点遮罩关闭），ChatPage 可作为普通组件嵌入面板
  （嵌套 Scaffold 合法，ScaffoldMessenger 走根 messenger）。面板宽度
  `(width * 0.55).clamp(360, 560)`。
- **StatelessWidget 的辅助方法访问不到 build 局部变量**：`_modeChip` 最初引用 build 里的
  `sid` 直接编译失败——类方法只能访问字段。要么把值当参数传，要么改用类字段
  （`sessionId ?? ''`）。列表项内需要新 context 时用 `Builder(builder: (context) ...)` 包裹。
- **无 SDK 静态自查抓到过真 bug**：0.5.4 的两个缺陷（手风琴收起动画不生效、草稿旧 key
  残留）都是自查阶段发现修复的，CI 未必能覆盖（无对应 widget 测试）。本机无 Flutter 时
  自查清单：删除符号的残留引用、动画/生命周期组件的挂载周期、跨 key 状态残留、
  闭包捕获的变量作用域、`withValues` 等版本敏感 API 与仓库既有用法一致。

## Android Live Updates 接入（2026-09-06，v0.5.5 实战）

- **framework 的 Live Updates 符号不在 stable SDK 36 里**：`Notification.ProgressStyle`
  类可解析，但其 `setColor` 与 `Notification.Builder.setRequestPromotedOngoing` 编译报
  unresolved——它们属于 API 36.1（Baklava QPR，@FlaggedApi）/ 更新层。官方 compose 文档
  恰好把 compat 方法名写成了 framework 链接，误导性强。**结论：上岛通知一律走 androidx
  compat，不直接调 framework 符号。**
- **androidx.core:core:1.18.0 是甜点位**：`NotificationCompat.ProgressStyle` +
  `Builder.setRequestPromotedOngoing`（写 extra，无 framework 依赖）齐全，minCompileSdk
  =36。**1.19.x 的 POM 传递依赖 core-ktx 1.19.0，其 AAR metadata 要求 compileSdk 37**，
  在 `:app:checkReleaseAarMetadata` 阶段直接构建失败。升级 androidx 前先下载 AAR 查
  aar-metadata.properties 的 minCompileSdk。
- 验证 API 真实存在性的可靠手段（本机无 Android SDK 时）：从
  `dl.google.com/android/maven2/androidx/core/core/<v>/core-<v>-sources.jar` 下载源码
  jar 用 `jar -xf` 解压 grep；framework 事实以 AOSP raw 源码
  （`aosp-mirror/platform_frameworks_base`）与 CI 编译结果为准，官方文档/diff 页可能
  空内容或模型补全有误。
- ProgressStyle 语义：compat 的 progress max 默认 100（`getProgressMax()`），segment
  长度是相对权重；promoted 需 `setOngoing(true)` + `POST_PROMOTED_NOTIFICATIONS` 权限 +
  无 customContentView + 非 groupSummary/colorized + 渠道 importance ≥ LOW。用户可在
  系统设置里关闭某个应用的 promoted 通知（`canPostPromotedNotifications()` 探测）。
- CI 的 ci.yml（web 冒烟）**不编译 Android**——Kotlin/gradle 改动只有 tag 触发的
  build-apk.yml 才会真正编译。首次接入原生 API 时预期 1-2 次构建失败是正常的，修复后
  `tag -f` 重指（Release 未生成的窗口内安全）。

## 官方 UI 对齐实战（2026-09-07/08，v0.5.7→v0.6.6 八轮迭代）

**视觉级证据强于逆向推断**：bundle 的 class 串只保证结构；卡片容器、状态文字、图标、颜色层级这类视觉决策必须用 He 的官方截图校准（v0.5.9 曾"结构对但视觉错"被打回）。主动要截图，比猜快。

**Flutter InputDecoration 三态继承**：`border: InputBorder.none` 只关 border 一态，`enabledBorder`/`focusedBorder` 仍从全局主题漏入（灰边+聚焦蓝边）。一体化输入框（composer、气泡内联编辑）必须三态显式置空。

**AnimatedSwitcher 手势陷阱**：切换瞬间旧 child 仍在层级内、新 child 已可命中，同一手势的抬指可能落在"刚出现的部件"上反向触发（状态胶囊收起点击无效的根因）。形态切换要么瞬时 swap，要么延迟切态。

**SVG path 解析**：小写 `m`（相对移动）之后的隐式线段是相对的（`m5 12 7-7 7 7`），误当绝对坐标会画出飞出画布的"竖线"。lucide 图标大量以小写 m 起笔。

**图标体系**：官方全部用 lucide（main.js 内 `X=Io('name',dataVar)` 定义 + 懒加载 chunk 格式 `var t=[[…]],n=e('name',t)`）。仓库 `lib/ui/official_icons.dart` 是生成物——重抓/新增图标走 `build/gen_icons.py`（icons.json → dart），生成后必须核对 map 收尾 `};` 没被拼接吃掉、无重复键。Dart 侧解析器已修相对移动 bug。

**工具族图标映射**（实抓）：思考=brain、Bash=terminal、Read/Grep/Glob=search、WebSearch=earth/WebFetch=globe、Write/Edit族=file-diff（官方无独立铅笔字形！）、TodoWrite=list-todo、Task/subagent=bot、fork=git-branch（官方无 split）。

**流光真身**（官方 CSS `index-BM2ndL2ru.css`，**样式在 CSS 资产里，别只抓 JS**）：`.animated-gradient-text` = linear-gradient(90deg, strong 0/34/66/100%, soft 50%)，background-size 300%，`gradient-flow` 4s linear——前 2s 从 position 100% 扫到 0、后 2s 停驻；strong=正文色（深 #fff/浅 #0d0d0d），soft=同色 20%/22%。是墨色呼吸，不是彩色闪光。

**层级规则**：进行中行=foreground 墨色+流光标签；已完成行=subtlest（更浅）。turnHeader 时长官方用 BX 函数算：`activeMs ?? endedAt-startedAt ?? now-startedAt`，只读单一字段会拿不到秒数。

**composer 断点=容器查询**：官方 `@container composer/inline-size`（@sm 384/@xl 576/@2xl 672），必须用工具条实测约束宽（LayoutBuilder），用视口宽在平板主从/折叠屏上必错。侧边栏壳断点（768px+触屏判定）是另一套，Zemote 有意下调 640/720。

**脚本工程**：Git Bash heredoc 会吞反斜杠（`'\'`→`''`），带转义的 python 一律用 Write 工具写成文件再执行；循环 curl 里用 `stat -c%s` 判断成败会整批误报，单发 curl 实际都成功。

**协议补充**（逆向）：rowsRange 响应=`{rows:[…], atSeq, atLogEpoch, hasMore}`（rows 是裸数组），schema 对 limit 有 max（rowsRangeMaxLimit，值未挖到，用 50 安全）；官方 loadAllOlder 循环拉到 hasMore=false——单页大 limit 会被拒。turnHeader/turn 时长字段=startedAt/endedAt/activeMs。goal 终态枚举含 completedSuccess（勿原文渲染）。

**辅助对话语义**（官方）：独立 sessionId、创建时携带主会话上下文；隐藏 goal 横幅/重试/分叉/编辑重发/点赞点踩/嵌套入口；保留完整 composer（模型/模式/思考按会话独立）+ 用量环。配置命令按 sessionId scope，串扰是 UI 层共享草稿显示问题。

## 第十一轮反馈批（2026-09-08，未发版）——四个真根因

**胶囊收不起的真根因不是手势**：上一轮把「无法收起」归因为 AnimatedSwitcher 过渡吞手势（见上节），实际是 `_StatusSummaryOverlay.build` 里 `if (!_expanded)` 分支构建胶囊后**没有提前 return / else**，随后的展开面板赋值把胶囊直接覆盖——点收起 rebuild 出的胶囊永远被丢弃，界面恒为面板。教训：**「移除动画修手势」这类解释若无验证就可能掩盖真正的结构性 bug**；同变量两段赋值必查互斥性。本轮已改胶囊分支提前 return。

**SVG 隐式数字分隔（查询工具族整行消失的根因）**：SVG path 允许无分隔符连写数字，第二个小数点即新数字起点（`1.704.706` = `1.704` + `.706`；`c0 1.1.9 2` = `1.1` + `.9`）。解析器把整段吞成一个 token，`double.parse` 在 **paint 期**抛 FormatException → release APK 里所在工具行整体渲染失败（earth=查询/WebSearch 族、file-diff=写入编辑族均中招）。已按 SVG 数字文法在第二个小数点分词；**回归测试逐字形 pump 全部 LucideIcon 并断言无 paint 异常**（test/official_icons_test.dart），新增字形必须过这道闸。

**图标名缺失 = 静默空白**：`LucideIcon(未知名)` 渲染空白 SizedBox 不报错——`git-branch` 字形从未入库，分叉按钮在 APK 里一直是隐形占位（He 报的「四个按钮错位」实为第四个按钮不存在）。图标引用走变量（`lucideIcon: 'name'`）时编译期查不出，**入库新图标后要 `grep 引用名 vs kOfficialIcons 键` 对账**；官方图标测试已断言关键字形存在。

**LayerLink.leader 是 LeaderLayer 不是 RenderBox**：popover 定位强转 `as RenderBox?` 在 leader 挂载后必抛 TypeError（debug 红屏、release 静默无反应）——用量环点击「没有任何效果」整一轮都是这个。取锚点 RenderBox 的正路是给目标 widget 挂 GlobalKey 再 `currentContext.findRenderObject()`。

**操作行时机（官方语义补全）**：复制/点赞/点踩/分叉只在轮次结束后出现——门控必须用**轮次级** running（`_rowIsActive`：流式文本/执行中/待确认/turnHeader running 任一即压住），按文本段自己的 streaming 判定会在工具调用间隙闪出按钮。

**工具族 id 容错**：桌面流式下发的 toolName 大小写/下划线形态不定（`webSearch`/`web_search`），MCP 形态是 `server__tool`。`resolveToolFamily`（公开顶层函数，有单测）先精确归一化匹配、`__` 尾段解析，查询类模糊回退保持「搜索」族标签与 earth/search 图标。
