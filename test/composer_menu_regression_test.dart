import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/protocol/conversation.dart';
import 'package:zemote/ui/chat_page.dart';
import 'package:zemote/ui/composer_menu.dart';

ConfigOptionValue _opt(String provider, String model,
    {String? name, String? providerId}) {
  return ConfigOptionValue.fromRaw({
    'value': '$provider/$model',
    'name': name ?? model,
    'modelProviderName': provider,
    if (providerId != null) 'modelProviderId': providerId,
  });
}

void main() {
  group('groupModelOptions pinning (official KI priority + Ed set)', () {
    test('builtin provider groups float to the top in official order', () {
      final groups = groupModelOptions([
        _opt('My Router', 'claude-4', providerId: 'custom:openrouter'),
        _opt('BigModel', 'GLM-4.6', providerId: 'builtin:bigmodel'),
        _opt('Z.ai', 'GLM-5.2', providerId: 'builtin:zai-coding-plan'),
      ]);
      expect(groups.keys.toList(), ['Z.ai', 'BigModel', 'My Router']);
    });

    test('zai-start-plan beats zai-coding-plan beats zai', () {
      final groups = groupModelOptions([
        _opt('Z.ai', 'GLM-5.2', providerId: 'builtin:zai'),
        _opt('Z.ai CP', 'GLM-5.2', providerId: 'builtin:zai-coding-plan'),
        _opt('Z.ai SP', 'GLM-5.2', providerId: 'builtin:zai-start-plan'),
      ]);
      expect(groups.keys.toList(), ['Z.ai SP', 'Z.ai CP', 'Z.ai']);
    });

    test('recommended models pin to the top inside a builtin group', () {
      final groups = groupModelOptions([
        _opt('Z.ai', 'GLM-4.6', providerId: 'builtin:zai'),
        _opt('Z.ai', 'GLM-5-Turbo', providerId: 'builtin:zai'),
        _opt('Z.ai', 'GLM-4.5-air', providerId: 'builtin:zai'),
        _opt('Z.ai', 'GLM-5.2', providerId: 'builtin:zai'),
      ]);
      expect(groups['Z.ai']!.map((v) => v.name).toList(),
          ['GLM-5.2', 'GLM-5-Turbo', 'GLM-4.6', 'GLM-4.5-air']);
    });

    test('custom provider groups keep their wire order untouched', () {
      final groups = groupModelOptions([
        _opt('Router A', 'GLM-5.2', providerId: 'custom:a'),
        _opt('Router A', 'GLM-4.6', providerId: 'custom:a'),
        _opt('Router B', 'gpt-x', providerId: 'custom:b'),
      ]);
      expect(groups.keys.toList(), ['Router A', 'Router B']);
      // GLM-5.2 is NOT reordered inside a non-first-party group.
      expect(groups['Router A']!.first.name, 'GLM-5.2');
    });

    test('missing modelProviderId falls back to the value segment', () {
      final groups = groupModelOptions([
        _opt('custom:x', 'foo'),
        _opt('builtin:zai', 'GLM-4.6'),
        _opt('builtin:zai', 'GLM-5.2'),
      ]);
      expect(groups.keys.toList(), ['builtin:zai', 'custom:x']);
      expect(groups['builtin:zai']!.first.name, 'GLM-5.2');
    });
  });

  group('slashCommandMatchScore', () {
    test('empty query matches everything as prefix', () {
      expect(slashCommandMatchScore('compact', ''), 0);
    });

    test('prefix beats word-boundary beats substring', () {
      expect(slashCommandMatchScore('compact', 'com'), 0);
      expect(slashCommandMatchScore('my-compact', 'com'), 1);
      expect(slashCommandMatchScore('xcompact', 'com'), 2);
    });

    test('no match returns null', () {
      expect(slashCommandMatchScore('compact', 'zoo'), isNull);
    });
  });

  group('ComposerModelMenuBody (provider rows after a switch)', () {
    // Regression: the provider holding the current model used to collapse
    // into an unlabeled flat model list, so its provider row disappeared
    // right after switching to one of its models.
    final options = [
      _opt('builtin:zai', 'GLM-5.2'),
      _opt('builtin:zai', 'GLM-4.5'),
      _opt('custom:openrouter', 'claude-4', name: 'Claude 4'),
    ];

    Future<Finder> pumpBody(WidgetTester tester, String current) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ComposerModelMenuBody(
              options: options,
              currentModelValue: current,
              onSelect: (_) {},
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return find.byType(ComposerModelMenuBody);
    }

    testWidgets('every provider keeps a visible row after a switch',
        (tester) async {
      await pumpBody(tester, 'custom:openrouter/claude-4');
      expect(find.text('builtin:zai'), findsOneWidget);
      expect(find.text('custom:openrouter'), findsOneWidget);
      expect(find.text('当前 · Claude 4'), findsOneWidget);
      expect(find.text('2 个模型'), findsOneWidget);
    });

    testWidgets('tapping a provider drills into its model list',
        (tester) async {
      await pumpBody(tester, 'custom:openrouter/claude-4');
      await tester.tap(find.text('builtin:zai'));
      await tester.pumpAndSettle();
      expect(find.text('GLM-5.2'), findsOneWidget);
      expect(find.text('GLM-4.5'), findsOneWidget);
      // The back header with the provider name stays on top.
      expect(find.text('builtin:zai'), findsOneWidget);
      // Other provider's models are not leaked into the drill page.
      expect(find.text('Claude 4'), findsNothing);
    });
  });
}
