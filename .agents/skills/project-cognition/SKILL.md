---
name: project-cognition
description: Zemote 仓库的项目认知与开发经验库。凡是在本仓库内做任何开发工作——修 bug、加功能、改协议层、写测试、调 UI、发版本、排查连接问题——都应先加载本 skill，即使没有明确提到"项目认知"。它提供架构地图、代码约定、历史踩坑（回归教训）和发布流程，避免重蹈已修复的 bug。
---

# Zemote 项目认知（Project Cognition）

## 项目一句话

Zemote 是 **ZCode 桌面端 Web 远程控制协议的独立复刻**（protocol reimplementation）：
Flutter 写的手机/平板客户端，多设备并发连接桌面 ZCode，提供任务列表、Conversation V4
对话、文件 diff、模型供应商管理、离线语音输入、应用自更新。

两个理解项目的关键前提：

1. **协议不是自己设计的**，是逆向复刻官方 Web 客户端。代码注释中出现的 `otn()`、`k()`、
   `Pne`、`N()`、`wD` 是官方 Web 客户端被混淆后的内部函数名，本项目的对应实现全部镜像它们。
   改协议层前先确认官方行为，不要"顺手优化"。
2. **协议层是纯 Dart、零 Flutter 依赖**，这是本仓库最重要的架构决策——所有协议逻辑可被
   `flutter test` 直接单测，不依赖真机。

## 架构地图

```
lib/
├── protocol/            ★ 核心：纯 Dart 协议栈（自底向上依次依赖）
│   ├── connection_params.dart   远程控制 URL 解析（sid/hash/t）、relay WS 地址
│   ├── proof.dart               配对证明 HMAC-SHA256 / base64url
│   ├── relay_client.dart        relay WebSocket + 心跳 + 重连状态机
│   ├── rpc_transport.dart       rpc-frame 分片/重组/CRC32 校验/ack
│   ├── ipc_codec.dart           IPC 值编解码 + 13 字节帧解析
│   ├── channel_client.dart      channel RPC（reqType 100-103 / respType 200-204）
│   ├── conversation.dart        Conversation V4：快照 + 增量、sessions-index 订阅
│   └── zemote_client.dart       ★ 门面：relay→配对→bootstrap→bridge→channel
│                                BridgeSession 管理生命周期、degraded/recovered
├── state/               AppSession（多设备连接，ChangeNotifier）、AccountStore、
│                        LogStore、凭据加密、崩溃留痕（含 io/stub 条件实现）
├── ui/                  main_shell、task_home、chat（最大文件 ~4400 行）、
│                        settings、三个调试器页（日志/RPC/Channel）
├── voice/               条件导入三件套：barrel → stub / native / web
├── update/              GitHub Releases 更新检测 + Android 下载安装（MD5/断点续传）
└── notifications/       Android 前台服务任务通知
```

连接生命周期：`connect() → waitPaired() → bootstrap() → openBridge(workspaceKey)`
返回 `BridgeSession`，其上通过 `channels` 做 channel RPC、通过 `conversation()` 拿
Conversation V4 传输层（每 workspace 缓存一份）。

## 铁律：历史踩坑（改代码前对照，详细版见 references/lessons.md）

这些全部是真实发生过的回归，每条都对应 CHANGELOG 里修过的 bug：

1. **竞态缓冲**：桌面对端的帧可能在本方 await 完成注册路由前到达。未知 bridge 的帧先进
   `_pendingBridgePayloads` 缓冲，注册后 flush（`zemote_client.dart` 的 dispatch 处）。
   新增异步握手路径时必须考虑"先到帧"问题。
2. **单元素帧 `[200]` 是合法的 Channel Initialize**，不是畸形帧。曾因边界检查误杀导致
   所有任务 RPC 超时、会话列表空。做帧校验时禁止比官方更严格。
3. **握手能力版本用桌面兼容版本 `3.6.5`**，绝不用 Zemote 自身版本号（`0.x`）参与协商。
4. **双数据源独立保存再合并**：channel 任务数据与 sessions-index 实时推送是两个来源，
   空快照、晚到响应、订阅失败都不得清空对方的数据。
5. **重连即降级**：relay 断开时立即把所有活动 bridge 标记 `degraded`，发送命令走
   `waitHealthy()` 排队；恢复后必须 `recovered` 计数 +1 触发重新订阅（服务端订阅状态随旧
   bridge 死亡）。恢复循环重试直到成功，不许半途放弃。
6. **一条回复一个气泡**：保留服务端原始段落顺序（思考→文本→工具→文本…），连续文本合并，
   点赞区只出现在最后一个文本段；`turnId` 中途变化不拆散分组。
7. **版本常量单一来源**：更新检查曾因使用旧硬编码版本号重复提示同一版本。版本号只认
   `pubspec.yaml`。
8. **配色必须主题感知**：所有颜色走 `ui/theme.dart` 的 `ZInk` 体系。浅色主题下白底白字
   是反复出现的回归（代码块、状态点、Diff、骨架屏都中过招）。
9. **凭据安全**：远程控制 URL 的 `sid/hash` 等同设备凭证。永不入库、永不写进测试代码
   （集成测试用 `ZEMOTE_PROBE_URL` 环境变量注入）；仅允许 HTTPS/WSS；Android 禁备份。
10. **发版三处版本同步**：版本号同时存在于 `pubspec.yaml`、`lib/update/app_version.dart`
    和守护测试 `test/update_checker_test.dart`（断言 appVersion/appBuildNumber 的具体值，
    防止发版忘改常量）。三者必须一起改，漏任何一处 CI 必红；这是 0.5.3 发版实际踩过的坑。
11. **流式列表滚动判定只用用户驱动**：消息列表的吸底/取消吸底只由用户真实拖动或惯性滚动
    更新（`userScrollDirection != ScrollDirection.idle`，程序 `animateTo` 期间恒为 idle），
    跟随只在吸底时执行。禁止重新引入"接近底部 N 像素即跟随"的距离启发式——流式输出时
    maxScrollExtent 持续增长，任何静态阈值都会把正在翻历史的用户往下拽（0.5.4 修过的坑）。
12. **Android 原生 API 优先走 androidx compat**：framework 新符号可能在 stable SDK 里
    不可用（Live Updates 的 `setColor`/`setRequestPromotedOngoing` 属 API 36.1
    / @FlaggedApi，直接调用编译失败）。上岛通知统一用 `NotificationCompat`，依赖锁
    `androidx.core:core:1.18.0`（1.19.x 传递的 core-ktx 要求 compileSdk 37，挂在
    AAR metadata 检查）；`compileSdk` 固定 36。改 Kotlin/gradle 前先读
    `references/lessons.md` 的 Live Updates 节。
13. **composer 断点用容器宽，不用视口宽**：官方是 `@container composer/inline-size`
    （384/576/672），必须 LayoutBuilder 取工具条实测宽；用视口宽在平板主从/折叠屏
    上必错（0.6.4 实际踩过）。壳侧边栏断点（640/720）是另一套，别混用。
14. **UI 资源一律官方抓取**：图标走 `lib/ui/official_icons.dart`（lucide 矢量数据 +
    自定义渲染器，重抓用 `build/gen_icons.py`）；配色以官方 CSS 变量为准（深
    #161616/#202020/#2B2B2B/白10%线，浅 #F8F8F8/白/黑10%线，正文 #DEDEDE/#3A3A3A）；
    流光/层级等动效样式先抓官方 CSS（`assets/*.css`，别只抓 JS）再实现，禁止自创。
    向 He 声明"与官方一致"前必须有官方截图做视觉校准。

## 代码约定

- 状态管理只用 `ChangeNotifier` / `ValueNotifier`，没有 bloc/riverpod/provider。
- 平台差异代码用**条件导入三件套**：`foo.dart`（barrel export）+ `if (dart.library.io)`
  native + `if (dart.library.js_interop)` web + stub 兜底。参考 `lib/voice/`。
- 协议层一律注入 `onLog` 回调输出调试行（`[bridge]`、`[ipc]` 前缀），日志汇聚到 LogStore。
- fake 注入测试风格：`sendPayload: (p) => sent.add(p)` 回环自收发，不起真实网络。
- 注释语言：协议层英文为主（对应官方函数名），UI 层中文。中文文档/CHANGELOG。
- 新协议字段照官方 schema 抄全（如 `automationId`、`runtimeModel`、`mcpServers`），不猜。

## 测试与发布

```bash
flutter analyze          # CI 门槛：零告警
flutter test             # 单元测试（协议/状态机/合并逻辑/更新检测）
flutter run -d chrome    # Web 冒烟
```

- 集成测试（`integration_test/`）需要真实桌面，通过 `ZEMOTE_PROBE_URL` 环境变量注入 URL，
  只做只读探针（如验证 `listTasks`、sessions-index 条数）。改协议层后若有真实环境，跑一次。
- **修任何协议/连接 bug 必须同时补回归测试**锚定该 bug（先例：Initialize 单元素帧、
  双数据源空响应）。
- 发布：`main`（稳定）/ `beta`（预发布）分支打 tag `vX.Y.Z` → GitHub Actions 构建
  3 ABI 签名 APK + MD5 并上传 Release。签名靠本地 `android/key.properties` + CI Secrets，
  保证覆盖安装。版本号 + `CHANGELOG.md`（Keep a Changelog 中文版）随版本一起改。

## 深入阅读（按需加载）

- 改**协议层/连接/重连**相关代码前 → 读 `references/protocol-map.md`
  （各层职责、官方函数对应、帧格式、竞态点）。
- 改**对话页 UI / composer / mention(@) 相关**前 → 读
  `references/official-web-ui.md`（官方 Web 客户端逆向：mention markdown
  格式、主题 CSS 变量、消息区样式常量、状态面板/summaryPanel、composer
  OF/VI 组件断点、工具族图标映射、待挖清单）；改样式动效前先抓官方
  `assets/*.css`（流光、层级等真身在 CSS 里）。
- 排查**回归类 bug** 或写修复方案前 → 读 `references/lessons.md`
  （按主题分类的完整踩坑记录与根因）。
- 发**版本或改 CI/签名/更新检测**前 → 读 `references/release-and-testing.md`。
