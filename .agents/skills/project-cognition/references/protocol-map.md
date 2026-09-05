# 协议层地图（改 lib/protocol/ 前必读）

## 分层与依赖方向

```
connection_params ─→ proof ─→ relay_client ─→ rpc_transport ─→ ipc_codec
                                                                  │
                             zemote_client (门面) ←─ channel_client
                                     │
                              conversation (V4)
```

只有 `zemote_client.dart` 和 `conversation.dart` 依赖 Flutter（`foundation.dart` 的
ValueNotifier 等），其余全部是纯 Dart。

## 与官方 Web 客户端的对应关系

官方 Web 端代码是混淆过的，本项目实现时在注释里标注了镜像来源：

| 本项目 | 官方 Web 端 | 说明 |
|---|---|---|
| `ZemoteClient` 整体流程 | `otn()` | relay connect → pair → bootstrap → bridge → channel |
| `ZemoteClient.request()` + matcher | `k()` | 请求/响应按 matcher 匹配，**响应不保证回带 requestId**，每个 payload 要过所有 pending matcher |
| `ChannelClient` | `Pne` | channel RPC 请求/响应编解码 |
| `sendMobileViewState()` | `N()` | 上报当前视图状态 |
| `BridgeSession.conversation()` 缓存 | `wD` | 每 service 握手一次，按 scope 缓存；transport 换栈时清除缓存重新握手 |

## 关键帧格式

- **rpc-frame**（relay payload 上的分片传输）：字段 `bridgeSessionId` / `seq` /
  `messageSeq` / `fragmentIndex` / `fragmentCount` / `messageBytes` / `dataBase64`；
  接收方需回 `rpc-frame-ack`；CRC32 校验（`crc32.dart`）。
- **Channel 请求头数组**：`[reqType, reqId, channelName, name]` + 参数值。
  reqType：`100` promise 调用、`101` 取消、`102` 事件订阅、`103` 订阅释放。
- **Channel 响应头数组**：`[respType, reqId]` + 数据值。
  respType：`200` Initialize、`201` 成功、`202/203` 失败、`204` 事件触发。
  **`[200]` 是单元素合法 Initialize 帧**（曾因误判畸形导致全部 RPC 超时）。
- **IPC 编码**（`ipc_codec.dart`）：值编解码 + 13 字节 IPC 帧。注意：workspace bridge
  上的 rpc-frame 消息体**就是**一个 ChannelClient body（value-stream），不走 13 字节
  IPC 分帧；13 字节帧用于别的通道路径。别把两条路径的分帧规则搞混。
- **Conversation V4**：快照 + 增量（delta）；`sessions-index` 订阅 + workspace-list
  推送双源合并；历史分页用已加载的最旧消息作游标。

## 连接状态机与恢复

`RelayClient` 状态：`connecting → paired`，断开进入 `reconnecting` / `error`。
心跳超时先探测（`poke()`）再重连。

`ZemoteClient` 监听 relay 状态：

1. relay 进入 `reconnecting/error` → 立即把所有活动 bridge 标记
   `degraded`（命令发送经 `waitHealthy()` 阻塞排队，而不是在死 socket 上超时）。
2. relay 重新 `paired` → 对每个 bridge 走恢复流程，**重试 15 次 × 3s 直到成功**：
   - 廉价路径：`workspace-reconnect-request`（15s 超时）；
   - 失败则完整重开：新的 `workspace-bridge-open`（新 bridgeSessionId、generation +1、
     携带旧 `recoveryId`），然后把新 transport/channels **换栈进同一个 BridgeSession**
     （页面持有的引用不失效）。
3. 恢复成功 → `session.recovered.value += 1`。所有订阅方监听该计数器重新订阅
   （服务端订阅状态随旧 bridge 一起死亡）。
4. 桌面主动下发 `bridge-degraded`（如 `rpc-transport-fault`）→ 同样进恢复循环。

## 已知的竞态点（写新代码时要主动对齐）

- **Initialize 先到**：桌面对端可能在 `openBridge` 的 await 续体注册路由之前推送
  rpc-frame。未知 bridge 的帧缓冲进 `_pendingBridgePayloads`，注册后 flush。
- **并发重连覆盖**：多个重连请求并发时，旧 WebSocket 的事件不得覆盖新连接状态
  （0.5.1-beta.2 修过）。重连路径要带 generation / 独占保护。
- **被踢下线的误判**：连接冲突（在别处打开）会被服务端表现成认证失败；认证阶段先做一次
  干净重连再判定，不要直接报"永久被踢"。
- **订阅初始化失败要清理**：事件监听器和定时器要拆干净，异常分片不得中断整个订阅。
- **回显不保证 requestId**：`request()` 的 matcher 按内容匹配（type + requestId +
  其他键），新增请求类型时 matcher 要收窄到能唯一定位该响应，又不能依赖服务端会回显
  我们没发过的字段。

## 调试入口

应用内三个调试器页（`ui/log_page.dart`、`rpc_explorer_page.dart`、
`channel_explorer_page.dart`）+ 协议日志开关。排查协议问题优先打开 relay/IPC/V4 帧日志。
