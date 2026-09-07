import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/ui/official_icons.dart';

void main() {
  // 回归：SVG path 解析器曾把 `1.704.706` 这类 SVG 隐式分隔的双小数点
  // 并进同一个 token，double.parse 在 paint 期抛 FormatException，
  // earth（查询/WebSearch 族）与 file-diff 字形整行渲染失败。
  testWidgets('all official glyphs paint without parser errors', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Wrap(
          children: [
            for (final entry in kOfficialIcons.entries)
              SizedBox(
                width: 24,
                height: 24,
                child: LucideIcon(entry.key, size: 24),
              ),
          ],
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test('icon registry keeps the glyphs the chat UI references', () {
    expect(kOfficialIcons.containsKey('chevron-up'), isTrue);
    expect(kOfficialIcons.containsKey('earth'), isTrue);
    expect(kOfficialIcons.containsKey('globe'), isTrue);
    // 分叉按钮引用 git-branch —— 缺字形时按钮渲染为空白 15px 方块。
    expect(kOfficialIcons.containsKey('git-branch'), isTrue);
  });
}
