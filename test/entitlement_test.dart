import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/protocol/entitlement.dart';

Map<String, Object?> _limit({
  String type = 'TOKENS_LIMIT',
  int? unit,
  int? number,
  num? remaining,
  double? percentage,
  int? nextResetTime,
  List<Map<String, Object?>> usageDetails = const [],
}) =>
    {
      'type': type,
      if (unit != null) 'unit': unit,
      if (number != null) 'number': number,
      if (remaining != null) 'remaining': remaining,
      if (percentage != null) 'percentage': percentage,
      if (nextResetTime != null) 'nextResetTime': nextResetTime,
      if (usageDetails.isNotEmpty) 'usageDetails': usageDetails,
    };

void main() {
  group('officialProviderPriority (KI/GI pinning)', () {
    test('builtin presets follow the fixed official order', () {
      expect(officialProviderPriority('builtin:zai-start-plan'), 0);
      expect(officialProviderPriority('builtin:zai-coding-plan'), 1);
      expect(officialProviderPriority('builtin:zai'), 2);
      expect(officialProviderPriority('builtin:bigmodel-start-plan'), 3);
      expect(officialProviderPriority('builtin:bigmodel-coding-plan'), 4);
      expect(officialProviderPriority('builtin:bigmodel'), 5);
      expect(officialProviderPriority('builtin:zapi'), 6);
    });

    test('unknown providers fall back to 200', () {
      expect(officialProviderPriority('custom:openrouter'), 200);
      expect(officialProviderPriority(null), 200);
    });

    test('family predicate covers six ids but not zapi (ja/wv)', () {
      expect(isFamilyProviderId('builtin:zai'), isTrue);
      expect(isFamilyProviderId('builtin:bigmodel-coding-plan'), isTrue);
      expect(isFamilyProviderId('builtin:zapi'), isFalse);
      expect(isFamilyProviderId('glm'), isFalse);
      expect(isFamilyProviderId(null), isFalse);
      // Sd (scope predicate) does include zapi.
      expect(isBuiltinProviderId('builtin:zapi'), isTrue);
    });
  });

  group('EntitlementSnapshot.parse (MF/NF selectors)', () {
    test('picks 5-hour, weekly, monthly-tool and MCP limits', () {
      final snap = EntitlementSnapshot.parse({
        'provider': {'id': 'builtin:zai-coding-plan'},
        'quota': {
          'level': 'pro',
          'limits': [
            _limit(unit: 3, number: 5, percentage: 20.0), // five-hour
            _limit(unit: 6, percentage: 55.5), // weekly
            _limit(
                type: 'TIME_LIMIT',
                unit: 5,
                number: 1,
                percentage: 0.0), // monthly tool
            _limit(unit: 9, number: 9, percentage: 10.0), // ignored
          ],
        },
        'mcpQuota': {
          'aggregate': _limit(unit: 1, percentage: 33.0),
        },
        'subscription': {'details': []},
      });
      expect(snap, isNotNull);
      expect(snap!.providerId, 'builtin:zai-coding-plan');
      expect(snap.visible, isTrue);
      expect(snap.isStartPlan, isFalse);
      expect(snap.level, 'pro');
      expect(snap.fiveHour, isNotNull);
      expect(snap.fiveHour!.remainingPercent, 80.0);
      expect(snap.weekly, isNotNull);
      expect(snap.weekly!.remainingPercent, closeTo(44.5, 0.001));
      expect(snap.monthlyTool, isNotNull);
      expect(snap.monthlyTool!.remainingPercent, 100.0);
      expect(snap.monthlyTool!.isFull, isTrue);
      expect(snap.mcpAggregate, isNotNull);
      expect(snap.mcpAggregate!.remainingPercent, 67.0);
    });

    test('CREDIT_LIMIT counts as the TOKENS_LIMIT family (YYe)', () {
      final snap = EntitlementSnapshot.parse({
        'quota': {
          'limits': [_limit(type: 'CREDIT_LIMIT', unit: 3, number: 5)],
        },
      });
      expect(snap!.fiveHour, isNotNull);
    });

    test('no_plan hides the section entirely (BF)', () {
      final snap = EntitlementSnapshot.parse({
        'unavailableReason': 'no_plan',
        'quota': {'limits': []},
      });
      expect(snap!.visible, isFalse);
    });

    test('start-plan provider switches to the balance section', () {
      final snap = EntitlementSnapshot.parse({
        'provider': {'id': 'builtin:zai-start-plan'},
        'quota': {
          'limits': [
            _limit(number: 100, remaining: 40),
            _limit(number: 0, remaining: 0), // filtered by CI
          ],
        },
      });
      expect(snap!.isStartPlan, isTrue);
      expect(snap.startPlanLimits, hasLength(1));
    });

    test('non-map and empty responses degrade to null/hidden', () {
      expect(EntitlementSnapshot.parse(null), isNull);
      expect(EntitlementSnapshot.parse('junk'), isNull);
      final snap = EntitlementSnapshot.parse({});
      expect(snap!.visible, isFalse);
    });
  });

  group('formatQuotaPercent (IF)', () {
    test('null renders --', () {
      expect(formatQuotaPercent(null), '--');
    });
    test('>= 10 uses whole numbers, below keeps one decimal', () {
      expect(formatQuotaPercent(80.0), '80%');
      expect(formatQuotaPercent(44.54), '45%');
      expect(formatQuotaPercent(3.44), '3.4%');
      expect(formatQuotaPercent(3.0), '3%');
      expect(formatQuotaPercent(0.0), '0%');
    });
  });

  group('formatStartPlanPercent (pZe)', () {
    test('remaining/number as whole percent, clamped', () {
      expect(formatStartPlanPercent(40, 100), '40%');
      expect(formatStartPlanPercent(150, 100), '100%');
      expect(formatStartPlanPercent(1, 3), '33%');
      expect(formatStartPlanPercent(5, 0), '--');
      expect(formatStartPlanPercent(null, null), '--');
    });
  });

  group('model name prettifiers (yI/mZe/SI)', () {
    test('modelCodeDisplay strips prefix and special-cases turbo', () {
      expect(modelCodeDisplay('model:glm-5-turbo'), 'GLM-5Turbo');
      expect(modelCodeDisplay('glm-4.6'), 'GLM-4.6');
    });
    test('prettyModelName keeps GLM dash structure', () {
      expect(prettyModelName('glm-5.2'), 'GLM-5.2');
      expect(prettyModelName('GLM-5-turbo'), 'GLM-5-Turbo');
      expect(prettyModelName('charglm_4'), 'Charglm 4');
      expect(prettyModelName('emohaa'), 'Emohaa');
    });
    test('startPlanLimitLabel joins details, falls back to type', () {
      final limit = QuotaLimit.fromRaw({
        'type': 'TOKENS_LIMIT',
        'usageDetails': [
          {'modelCode': 'model:glm-5.2', 'displayName': ' GLM-5.2 '},
          {'modelCode': 'glm-5-turbo'},
        ],
      });
      expect(startPlanLimitLabel(limit), 'GLM-5.2 / GLM-5Turbo');
      final empty = QuotaLimit.fromRaw({'type': 'TOKENS_LIMIT'});
      expect(startPlanLimitLabel(empty), 'TOKENS_LIMIT');
    });
  });

  group('reset time formatters (uZe/LF)', () {
    test('clock and date formats', () {
      final ms = DateTime(2026, 9, 8, 14, 5).millisecondsSinceEpoch;
      expect(formatResetClock(ms), '14:05');
      expect(formatResetDate(ms), '9月8日');
      expect(formatResetClock(null), '');
    });
    test('adaptive shows HH:mm only for same-day resets', () {
      final now = DateTime.now();
      final laterToday = now.add(const Duration(minutes: 30));
      // 跨日边界容错：只在确定同日时断言 HH:mm。
      if (laterToday.day == now.day) {
        expect(formatResetAdaptive(laterToday.millisecondsSinceEpoch),
            matches(RegExp(r'^\d{2}:\d{2}$')));
      }
      final nextWeek = now.add(const Duration(days: 7));
      expect(formatResetAdaptive(nextWeek.millisecondsSinceEpoch),
          '${nextWeek.month}月${nextWeek.day}日');
    });
  });
}
