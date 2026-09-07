import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/ui/chat_page.dart';

void main() {
  group('turnWorkLabel (official chat.history copy)', () {
    test('running shows working + duration', () {
      expect(turnWorkLabel(state: 'running'), '工作中');
      expect(
        turnWorkLabel(state: 'running', durationMs: 125000),
        '工作中 2分5秒',
      );
    });

    test('interrupted and failed collapse to 已停止', () {
      expect(turnWorkLabel(state: 'completedInterrupted', durationMs: 5000),
          '已停止');
      expect(turnWorkLabel(state: 'failed', durationMs: 5000), '已停止');
    });

    test('completed shows worked or processed', () {
      expect(turnWorkLabel(state: 'completedSuccess', durationMs: 0), '已处理');
      expect(turnWorkLabel(state: ''), '已处理');
      expect(
        turnWorkLabel(state: 'completedSuccess', durationMs: 65000),
        '已工作 1分5秒',
      );
    });
  });

  group('formatTurnDuration (zh units 天/时/分/秒)', () {
    test('single unit', () {
      expect(formatTurnDuration(5000), '5秒');
      expect(formatTurnDuration(60000), '1分');
      expect(formatTurnDuration(3600000), '1时');
    });

    test('mixed units drop zero trailing parts', () {
      expect(formatTurnDuration(125000), '2分5秒');
      expect(formatTurnDuration(3665000), '1时1分5秒');
      expect(formatTurnDuration(60000 + 3600000), '1时1分');
    });

    test('zero and negative clamp to 0秒', () {
      expect(formatTurnDuration(0), '0秒');
      expect(formatTurnDuration(-3), '0秒');
    });
  });

  group('turnDefaultOpen (official collapse model)', () {
    test('latest turn open while running', () {
      expect(
        turnDefaultOpen(
            isLastTurn: true,
            running: true,
            isOnlyTurn: false,
            hasAssistantText: true),
        isTrue,
      );
    });

    test('completed latest turn collapses', () {
      expect(
        turnDefaultOpen(
            isLastTurn: true,
            running: false,
            isOnlyTurn: false,
            hasAssistantText: true),
        isFalse,
      );
    });

    test('lone turn without assistant text stays open', () {
      expect(
        turnDefaultOpen(
            isLastTurn: false,
            running: false,
            isOnlyTurn: true,
            hasAssistantText: false),
        isTrue,
      );
      expect(
        turnDefaultOpen(
            isLastTurn: false,
            running: false,
            isOnlyTurn: true,
            hasAssistantText: true),
        isFalse,
      );
    });

    test('older turns always collapsed', () {
      expect(
        turnDefaultOpen(
            isLastTurn: false,
            running: false,
            isOnlyTurn: false,
            hasAssistantText: true),
        isFalse,
      );
    });
  });

  group('emptyGreeting (official chat.empty.greeting copy)', () {
    DateTime at(int hour) => DateTime(2026, 9, 7, hour);

    test('maps hour ranges to official copy', () {
      expect(emptyGreeting(at(6)), '早上好呀，新的一天开始啦');
      expect(emptyGreeting(at(9)), '上午好呀，有什么想让我帮忙的吗');
      expect(emptyGreeting(at(12)), '中午好呀，要不要先休息一下');
      expect(emptyGreeting(at(15)), '下午好呀，接下来交给我吧');
      expect(emptyGreeting(at(20)), '晚上好呀，今天辛苦啦');
      expect(emptyGreeting(at(2)), '夜深啦，别忘了照顾好自己哦');
    });
  });
}
