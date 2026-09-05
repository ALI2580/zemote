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
