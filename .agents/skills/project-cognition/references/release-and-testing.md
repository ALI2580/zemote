# 测试与发布流程

## 本地验证（贡献门槛，CI 同款）

```bash
flutter analyze            # 必须零告警
flutter test               # 单元测试必须全过
flutter build web --release  # Web 编译冒烟（CI 会跑）
```

本地运行：

```bash
flutter run                # Android
flutter run -d chrome      # Web（调试/快速预览）
flutter run -d windows     # Windows 桌面
```

## 测试分层与写法

### 单元测试（test/，不需要真实桌面）

协议层是纯 Dart，全部用 **fake 注入回环**风格测：

```dart
late List<Map<String, dynamic>> sent;
late RpcFrameTransport transport;

setUp(() {
  sent = [];
  transport = RpcFrameTransport(
    bridgeSessionId: 'bridge-1',
    sendPayload: (p) => sent.add(p),   // fake 发送，回环自收
  );
  transport.messages.listen((msg) => received.add(msg));
});
```

既有覆盖面（新增同类逻辑时对齐）：

- 协议编解码：`ipc_codec_test`、`rpc_transport_test`、`connection_params_test`
- 状态机/合并：`task_home_merge_test`（双源合并）、`chat_grouping_test`（气泡分组）、
  `session_list_cache_test`
- 状态持久化：`account_store_test`、`id_account_test`
- 平台特性：`update_checker_test`（含版本排序/预发布）、`notify_state_test`、
  `voice_models_test`
- UI：`chat_theme_test`、`diff_view_test`、`settings_page_test` 等 widget 测试

### 集成测试（integration_test/，需要真实桌面 + 凭据）

- 通过环境变量 `ZEMOTE_PROBE_URL` 注入远程控制 URL，**永不写死凭据**。
- 只做**只读探针**：验证 `listTasks` 条数、sessions-index 条数、最终可见会话数一致。
- 协议层改动后，若有真实环境建议跑一次只读验证（先例：0.4.3 用
  `listTasks=1` / sessions-index `=2` / 可见会话 `=2` 验证合并逻辑）。

### 回归测试纪律

修任何 bug（尤其协议/连接/合并类）必须同时新增锚定该 bug 的回归测试。
历史先例：Initialize 单元素帧 `[200]`、双数据源空响应、Beta 版本排序。

## 发布流程（稳定版与 Beta 版）

1. 代码合入 `main`（稳定）或 `beta`（预发布）分支，保证 analyze/test 全绿。
2. **版本号三处同步**：`pubspec.yaml`（`version: X.Y.Z+build`，build 号递增）、
   `lib/update/app_version.dart`（更新检查用的常量）、`test/update_checker_test.dart`
   的守护测试（断言版本与 build 号的具体值）。漏一处 CI 必红。
3. 按 Keep a Changelog（中文）更新 `CHANGELOG.md`：Added / Changed / Fixed 分类。
4. 打 tag 并推送：`git tag vX.Y.Z && git push origin vX.Y.Z`。
   Beta 预发布 tag 形如 `vX.Y.Z-beta.N` / `vX.Y.Z-rc.N`（更新检测按 SemVer 预发布规则
   排序，且受"接收 Beta 更新"开关过滤 GitHub Pre-release）。
5. `build-apk.yml` 自动执行：analyze + test → 从 Secrets 恢复 keystore 签名 →
   构建 3 个 ABI APK（arm64-v8a / armeabi-v7a / x86_64）→ 生成各自 MD5 →
   上传 GitHub Release。实测全程约 13 分钟。
6. **顺序纪律（0.5.4 验证零返工）**：先推 `main` 等 ci.yml 全绿，再打 tag——0.5.3 因
   tag 抢在测试修复前推送，导致一次失败的 Release 构建。严格按本清单执行可一次通过。

## CI 配置（.github/workflows/）

- `ci.yml`：push 到 main/beta 与所有 PR → `flutter pub get` → `flutter analyze` →
  `flutter test` → `flutter build web --release` 冒烟。
- `build-apk.yml`：`v*` tag 或手动触发 → 签名构建 3 ABI + MD5 → 上传 Release。
  Action 版本用 commit SHA 固定（供应链安全习惯）。
- **门禁盲区（0.5.5 踩过）**：ci.yml **不编译 Android**——"先推 main 等 CI 绿再打 tag"
  的策略只覆盖 Dart 层。Kotlin/gradle 改动（新原生 API、依赖升级、compileSdk 调整）的
  真正编译验证只在 build-apk.yml；首次接入原生 API 预期 1-2 次构建失败，修复流程见
  lessons.md 的 Live Updates 节（framework 符号陷阱、androidx.core 版本甜点位、
  AAR metadata 的 minCompileSdk 检查）。

## 签名要点（当前仓库 ALI2580/zemote，已配置完成）

- 四个 GitHub Secrets 已配置：`ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` /
  `ANDROID_KEY_PASSWORD` / `ANDROID_KEY_ALIAS=zemote`；gradle 侧本地走
  `android/key.properties`（git-ignored），CI 走 `ANDROID_*` 环境变量，键名一一对应。
- **keystore 备份在 `C:\Users\99553\zemote-signing\`**：`zemote-release.jks`（本体）、
  `.pass`（store/key 密码，两者相同）、`keystore.base64.txt`（Secrets 用）。此密钥决定
  所有后续版本的覆盖安装链路，丢失后无法弥补——云盘 + 本地各存一份。
- 证书：`CN=ALI2580, OU=Zemote`，自签名，有效期 10000 天；SHA-1
  `37:78:91:25:BF:E2:5B:7B:CE:44:62:B6:89:D9:52:D4:28:33:B5:3E`。
- 与原作者官方版签名不同：装过 HumanAILoop 原版 APK 的设备需先卸载；从本仓库 v0.5.3 起
  后续版本均可覆盖升级。
- CI 绿色 ≠ 正式签名：Secrets 缺失时构建只打 WARN 并回退 debug 签名。验证方式见
  lessons.md（解 APK Signing Block 抠证书，或 `git check-ignore` 确认本地签名文件不入库）。

## 本机开发环境注意事项

- **本机已有 Flutter SDK（2026-09-06 起）**：`D:\SoftWare\Develop\flutter`（3.47.2 stable，
  Dart 3.13.2）。Git Bash 里 `export PATH="/d/SoftWare/Develop/flutter/bin:$PATH"` 后可
  直接跑 `flutter analyze`（约 7s）/ `flutter test`（秒级）——**改码后先本地 analyze 再
  推送，不要再用 CI 盲猜 lint**（0.5.7/0.6.0 都因盲猜多跑过红 CI）。
- 注意 `flutter pub get` 会重新生成 `windows/flutter/generated_*`（本地插件注册），
  属正常变更可一并提交。
- UI 改动建议配合 MuMu 12 模拟器验证：`/d/SoftWare/Common/Mumu/emulator/MuMuPlayer-12.0/shell/adb.exe`
  （emulator-5554），装 x86_64 APK；连接凭据走 app 内"粘贴链接添加"，`adb shell input text`
  输入 URL 时用单引号保护 `&`。桌面端单设备限制：MuMu 连接会挤掉用户真机——
  **验证完成后不要反复抢占连接**。
- 本仓库 git 由源码副本新初始化，远程历史是镜像的原作者提交；推送走 SSH
  （公钥 `zemote-dev-rog-strix` 已注册到 GitHub 账号）。
