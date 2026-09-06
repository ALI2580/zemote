import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/protocol/conversation.dart';
import 'package:zemote/ui/chat_page.dart';
import 'package:zemote/ui/composer_menu.dart';

ConfigOptionValue _opt(String provider, String model, {String? name}) {
  return ConfigOptionValue.fromRaw({
    'value': '$provider/$model',
    'name': name ?? model,
    'modelProviderName': provider,
  });
}

void main() {
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
