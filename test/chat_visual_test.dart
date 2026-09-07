import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/ui/chat_page.dart';
import 'package:zemote/ui/theme.dart';

void main() {
  // golden 基线在 Windows 本机生成；Linux CI 的字体/光栅化即使同版本 Flutter
  // 也与 Windows 有像素差，无法共用基准图——CI 上跳过，仅本地视觉回归用。
  final goldenSkipped = Platform.environment['CI'] == 'true';

  // 视觉回归：工具行（图标/标签/摘要/状态同一中线）+ 操作行四按钮
  // 等大 30px 方格。
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
  }, skip: goldenSkipped);

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

  testWidgets('official toolbar row is 28px tall throughout',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildDarkTheme(),
      home: Scaffold(
        body: ListView(children: [chatRowsGoldenSample()]),
      ),
    ));
    await tester.pump();
    // 官方 icon-md / h-7 体系：发送按钮与 + 入口 28px 方形。
    final send = tester.renderObject<RenderBox>(
        find.byWidgetPredicate((w) => w is Opacity, description: 'send'));
    expect(send.size.height, 28);
    expect(send.size.width, 28);
    // Tooltip 包裹的 ghost 按钮（28px 方形，四周无边距）。
    final plusBox = tester.renderObject<RenderBox>(
        find.byType(SizedBox).last);
    expect(plusBox.size.height, 28);
    // chip 文字存在（模型展开态；模式 iconOnly 方形 + 思考竖条态按官方
    // @xl 前隐藏 label）。
    expect(find.text('计划模式'), findsNothing);
    expect(find.text('GLM-5.2'), findsOneWidget);
    expect(find.text('思考'), findsNothing);
  });
}
