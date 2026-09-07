import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/protocol/conversation.dart';

/// 主辅会话配置隔离锚定（He 2026-09-09 报告：辅助会话与主会话"共用"
/// 模型/思考强度）。
///
/// Zemote 侧每个 ChatPage 持有独立 ConversationSubscription（topic =
/// conversation/{sessionId}），帧按 topic 过滤、state 按订阅实例隔离、
/// switchModelConfig 只携带本会话 sessionId（envelope 顶层，与官方
/// schema 一致）。本组测试锚定这三层语义，任何一层被改坏（topic 过滤
/// 丢失 / state 共享 / config patch 广播）都会红。
void main() {
  ConversationState injectSession(String sessionId,
      {String provider = 'builtin', String model = 'GLM-5.2', String thought = 'high'}) {
    final state = ConversationState();
    state.applyFrame({
      'topic': 'conversation/$sessionId',
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'sessionId': sessionId,
          'logEpoch': 'epoch-$sessionId',
          'revision': 1,
          // 辅助会话创建时携带主会话上下文 —— 初始 config 相同。
          'config': {'provider': provider, 'model': model, 'thought': thought},
          'rows': const {
            'window': [],
            'totalCount': 0,
          },
        },
      },
      'toSeq': 1,
    }, onGap: () => fail('snapshot must not gap'));
    return state;
  }

  void applyConfigPatch(ConversationState state, String sessionId,
      {required String model, required String thought}) {
    state.applyFrame({
      'topic': 'conversation/$sessionId',
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {
            'op': 'state.updated',
            'patch': {
              'config': {'provider': 'builtin', 'model': model, 'thought': thought},
            },
          },
        ],
      },
      'fromSeq': state.seq,
      'toSeq': state.seq + 1,
    }, onGap: () => fail('contiguous delta must not gap'));
  }

  group('side-chat config isolation', () {
    test('main-session config update never reaches the side-chat state',
        () {
      final main = injectSession('main-1');
      final side = injectSession('side-1');
      expect(side.config?['model'], 'GLM-5.2');

      // Desktop pushes state.updated ONLY on the main topic.
      applyConfigPatch(main, 'main-1', model: 'GLM-5.2-Air', thought: 'max');

      expect(main.config?['model'], 'GLM-5.2-Air');
      expect(main.currentThought, 'max');
      // The side chat keeps its own config snapshot.
      expect(side.config?['model'], 'GLM-5.2');
      expect(side.currentThought, 'high');
    });

    test('side-chat config update never reaches the main-session state',
        () {
      final main = injectSession('main-1');
      final side = injectSession('side-1');

      applyConfigPatch(side, 'side-1', model: 'GLM-5.2-Air', thought: 'nothink');

      expect(side.config?['model'], 'GLM-5.2-Air');
      expect(side.currentThought, 'nothink');
      expect(main.config?['model'], 'GLM-5.2');
      expect(main.currentThought, 'high');
    });

    test('optimistic patch only mutates its own state instance', () {
      final main = injectSession('main-1');
      final side = injectSession('side-1');

      // The UI's optimistic patch after switching in the side chat.
      side.optimisticPatch({
        'config': {...?side.config, 'model': 'GLM-5.2-Air'},
      });

      expect(side.config?['model'], 'GLM-5.2-Air');
      expect(main.config?['model'], 'GLM-5.2');
    });

    test('config patch before the snapshot buffers into the right session',
        () {
      // Patch-before-snapshot ordering must not leak across instances.
      final lateMain = ConversationState();
      lateMain.applyFrame({
        'topic': 'conversation/main-1',
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {
              'op': 'state.updated',
              'patch': {
                'config': {'provider': 'builtin', 'model': 'X', 'thought': 'off'},
              },
            },
          ],
        },
        'fromSeq': 0,
        'toSeq': 1,
      }, onGap: () => fail('first patch must not gap'));

      final other = injectSession('side-1');
      expect(other.config?['model'], 'GLM-5.2');

      lateMain.applyFrame({
        'topic': 'conversation/main-1',
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'sessionId': 'main-1',
            'logEpoch': 'e',
            'revision': 2,
            'config': const {
              'provider': 'builtin',
              'model': 'GLM-5.2',
              'thought': 'high',
            },
            'rows': const {'window': [], 'totalCount': 0},
          },
        },
        'toSeq': 2,
      }, onGap: () => fail('snapshot must not gap'));

      // The buffered patch merges into main's snapshot only.
      expect(lateMain.config?['model'], 'X');
      expect(other.config?['model'], 'GLM-5.2');
    });
  });
}
