import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/ui/chat_page.dart';
import 'package:zemote/ui/theme.dart';

void main() {
  // 视觉回归：工具行（图标/标签/摘要/状态同一中线）+ 操作行四按钮
  // 等大 30px 方格。Ahem 字体下平台无关，CI 可复现。
  testWidgets('chat rows visual sample (dark)', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildDarkTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: chatRowsGoldenSample(),
            ),
          ),
        ),
      ),
    ));
    // 运行中行的流光动画停在确定相位。
    await tester.pump(const Duration(milliseconds: 1200));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/chat_rows_dark.png'),
    );
  });

  testWidgets('running search-family rows render label and summary',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildDarkTheme(),
      home: Scaffold(
        body: ListView(children: [
          chatRowsGoldenSample(),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    // 查询（search）族：运行中也要有官方族标签与 query 摘要。
    expect(find.text('搜索'), findsNWidgets(2));
    expect(find.text('终端'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    // 运行中的 MCP 查询行：行内摘要 + 展开的输入详情都携带 query。
    expect(find.textContaining('layer link renderbox'),
        findsAtLeastNWidgets(1));
    expect(find.textContaining('official web ui reverse'),
        findsAtLeastNWidgets(1));
  });
}
