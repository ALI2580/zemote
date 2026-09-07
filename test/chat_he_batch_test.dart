import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/ui/chat_page.dart';

void main() {
  group('resolveToolFamily (official tool-family parity)', () {
    test('exact builtin families keep official labels and icons', () {
      expect(resolveToolFamily('Read'), (label: '读取', icon: 'search'));
      expect(resolveToolFamily('Grep'), (label: '搜索', icon: 'search'));
      expect(resolveToolFamily('Glob'), (label: '搜索', icon: 'search'));
      expect(resolveToolFamily('WebSearch'), (label: '搜索', icon: 'earth'));
      expect(resolveToolFamily('WebFetch'), (label: '搜索', icon: 'globe'));
      expect(resolveToolFamily('Write'), (label: '写入', icon: 'file-diff'));
      expect(resolveToolFamily('Edit'), (label: '编辑', icon: 'file-diff'));
      expect(resolveToolFamily('MultiEdit'), (label: '编辑', icon: 'file-diff'));
      expect(resolveToolFamily('Bash'), (label: '终端', icon: 'terminal'));
      expect(resolveToolFamily('TodoWrite'), (label: '待办', icon: 'list-todo'));
      expect(resolveToolFamily('Task'), (label: '任务', icon: 'bot'));
    });

    test('streamed desktop ids (case/underscore variants) still resolve',
        () {
      // 查询（search）族在 APK 内失联的根因假设之一：桌面下发的 tool id
      // 大小写/下划线形态不定，精确表未命中即回退原始英文名。
      expect(resolveToolFamily('webSearch').label, '搜索');
      expect(resolveToolFamily('webSearch').icon, 'earth');
      expect(resolveToolFamily('web_search').icon, 'earth');
      expect(resolveToolFamily('websearch').icon, 'earth');
      expect(resolveToolFamily('grep').label, '搜索');
      expect(resolveToolFamily('todo_write').label, '待办');
    });

    test('mcp server__tool ids resolve by trailing segment', () {
      final f = resolveToolFamily('mcp__web-search__search');
      expect(f.label, '搜索');
      expect(f.icon, 'earth');
    });

    test('query-ish fallback keeps the search family', () {
      expect(resolveToolFamily('searchMemory').label, '搜索');
      expect(resolveToolFamily('custom_query_tool').label, '搜索');
      expect(resolveToolFamily('http_fetch').icon, 'globe');
    });

    test('unknown tools fall back to raw name + default icon', () {
      final f = resolveToolFamily('Frobnicate');
      expect(f.label, 'Frobnicate');
      expect(f.icon, isNull);
      expect(resolveToolFamily('').label, '');
    });
  });

  group('goalBannerStatus (official goal semantics)', () {
    test('active states keep the goal visible', () {
      expect(goalBannerStatus(''), (true, null));
      expect(goalBannerStatus('active'), (true, null));
      expect(goalBannerStatus('verifying'), (true, '目标校验中'));
      expect(goalBannerStatus('checking'), (true, '目标校验中'));
      expect(goalBannerStatus('paused'), (true, '已暂停'));
      expect(goalBannerStatus('onHold'), (true, '已暂停'));
    });

    test('terminal states do not persist the banner', () {
      expect(goalBannerStatus('completedSuccess'), (false, null));
      expect(goalBannerStatus('completedIncomplete'), (false, null));
      expect(goalBannerStatus('cancelled'), (false, null));
      expect(goalBannerStatus('failed'), (false, null));
      expect(goalBannerStatus('error'), (false, null));
    });
  });
}
