import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/ui/chat_page.dart';

void main() {
  group('parseContextWindowInfo', () {
    test('parses used/max plus cache hit rate and breakdown', () {
      final info = parseContextWindowInfo({
        'contextWindow': {
          'usedTokens': 40000,
          'maxTokens': 128000,
          'cache': {'hitRate': 0.87},
          'breakdown': [
            {'source': 'messages', 'chars': 8000},
            {'source': 'system_prompt', 'chars': 12000},
            {'source': 'skills', 'chars': 3000},
          ],
        },
      });
      expect(info, isNotNull);
      expect(info!.usedTokens, 40000);
      expect(info.maxTokens, 128000);
      expect(info.ratio, closeTo(40000 / 128000, 1e-9));
      expect(info.cacheHitRate, 0.87);
      // sorted by chars desc: system_prompt > messages > skills
      expect(
        info.breakdown.map((e) => e.source).toList(),
        ['system_prompt', 'messages', 'skills'],
      );
    });

    test('breakdown chars from duplicate sources are summed', () {
      final info = parseContextWindowInfo({
        'contextWindow': {
          'usedTokens': 100,
          'maxTokens': 1000,
          'breakdown': [
            {'source': 'messages', 'chars': 10},
            {'source': 'messages', 'chars': 5},
            {'source': 'skills', 'chars': 5},
          ],
        },
      });
      final bySource = {for (final e in info!.breakdown) e.source: e.chars};
      expect(bySource['messages'], 15);
      expect(bySource['skills'], 5);
    });

    test('missing cache/breakdown still yields basic ring data', () {
      final info = parseContextWindowInfo({
        'contextWindow': {'usedTokens': 5, 'maxTokens': 10},
      });
      expect(info, isNotNull);
      expect(info!.cacheHitRate, isNull);
      expect(info.breakdown, isEmpty);
      expect(info.ratio, 0.5);
    });

    test('malformed shapes yield null (ring hidden)', () {
      expect(parseContextWindowInfo(null), isNull);
      expect(parseContextWindowInfo(const {}), isNull);
      expect(
        parseContextWindowInfo({
          'contextWindow': {'maxTokens': 10},
        }),
        isNull,
      );
      expect(
        parseContextWindowInfo({
          'contextWindow': {'usedTokens': 5, 'maxTokens': 0},
        }),
        isNull,
      );
    });
  });

  group('formatters', () {
    test('formatCompactTokens uses zh units', () {
      expect(formatCompactTokens(980), '980');
      expect(formatCompactTokens(10000), '1万');
      expect(formatCompactTokens(12345), '1.2万');
      expect(formatCompactTokens(300000000), '3亿');
    });

    test('formatUsagePercent: >=10% whole, below one decimal', () {
      expect(formatUsagePercent(0.5), '50%');
      expect(formatUsagePercent(0.034), '3.4%');
    });
  });

  group('thought bar (official @sm..@xl chip)', () {
    test('ranks follow the official intensity scale', () {
      expect(thoughtLevelRank('off'), 0);
      expect(thoughtLevelRank('nothink'), 0);
      expect(thoughtLevelRank('low'), 1);
      expect(thoughtLevelRank('medium'), 2);
      expect(thoughtLevelRank('high'), 3);
      expect(thoughtLevelRank('enabled'), 4);
      expect(thoughtLevelRank('xhigh'), 5);
      expect(thoughtLevelRank('max'), 6);
      expect(thoughtLevelRank('unknown-value'), 99);
      expect(thoughtLevelRank(' MAX '), 6);
    });

    test('bar fill = position among enabled options', () {
      // low/high/max → 1/3, 2/3, 3/3
      final opts = ['low', 'high', 'max'];
      expect(thoughtBarFill(opts, 'low'), closeTo(1 / 3, 1e-9));
      expect(thoughtBarFill(opts, 'high'), closeTo(2 / 3, 1e-9));
      expect(thoughtBarFill(opts, 'max'), 1);
    });

    test('off options contribute zero and stay unfilled', () {
      final opts = ['off', 'enabled'];
      expect(thoughtBarFill(opts, 'off'), 0);
      expect(thoughtBarFill(opts, 'enabled'), 1);
      // off/enabled style: off ranks 0, fill of enabled = 1/1
    });

    test('unknown current value fills nothing', () {
      expect(thoughtBarFill(['low', 'max'], 'whatever'), 0);
      expect(thoughtBarFill(<String>[], 'max'), 0);
    });
  });
}
