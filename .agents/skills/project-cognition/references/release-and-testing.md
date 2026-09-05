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
2. 更新 `pubspec.yaml` 的 `version: X.Y.Z+build`（build 号递增）。
3. 按 Keep a Changelog（中文）更新 `CHANGELOG.md`：Added / Changed / Fixed 分类。
4. 打 tag 并推送：`git tag vX.Y.Z && git push origin vX.Y.Z`。
   Beta 预发布 tag 形如 `vX.Y.Z-beta.N` / `vX.Y.Z-rc.N`（更新检测按 SemVer 预发布规则
   排序，且受"接收 Beta 更新"开关过滤 GitHub Pre-release）。
5. `build-apk.yml` 自动执行：analyze + test → 从 Secrets 恢复 keystore 签名 →
   构建 3 个 ABI APK（arm64-v8a / armeabi-v7a / x86_64）→ 生成各自 MD5 →
   上传 GitHub Release。

## CI 配置（.github/workflows/）

- `ci.yml`：push 到 main/beta 与所有 PR → `flutter pub get` → `flutter analyze` →
  `flutter test` → `flutter build web --release` 冒烟。
- `build-apk.yml`：`v*` tag 或手动触发 → 签名构建 3 ABI + MD5 → 上传 Release。
  Action 版本用 commit SHA 固定（供应链安全习惯）。

## 签名要点

- 本地：`android/key.properties` + keystore 文件（均在 `.gitignore` 中）。
- CI：`ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_PASSWORD` /
  `ANDROID_KEY_ALIAS` 四个 Secrets；keystore base64 解码到 `android/app/zemote-release.jks`。
- 签名不一致 = 用户无法覆盖安装 = 更新链路断裂，发版前务必确认 Secrets 存在。
