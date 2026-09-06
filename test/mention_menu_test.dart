import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/ui/mention_menu.dart';

void main() {
  group('fileMentionMarkdown', () {
    test('bare relative path gets ./ prefix', () {
      expect(fileMentionMarkdown('a.dart', 'a.dart'), '[a.dart](./a.dart)');
    });

    test('directory gets trailing slash', () {
      expect(
        fileMentionMarkdown('lib', 'lib', directory: true),
        '[lib](./lib/)',
      );
    });

    test('absolute and parent paths stay untouched', () {
      expect(
        fileMentionMarkdown('x', '/abs/path/x'),
        '[x](/abs/path/x)',
      );
      expect(
        fileMentionMarkdown('x', '../sibling/x'),
        '[x](../sibling/x)',
      );
    });

    test('escapes brackets in label and > in target', () {
      expect(
        fileMentionMarkdown('a[b]c', 'p>q'),
        '[a\\[b\\]c](./p\\>q)',
      );
    });

    test('escapes backslashes in both parts', () {
      expect(
        fileMentionMarkdown('a\\b', 'x\\y'),
        '[a\\\\b](./x\\\\y)',
      );
    });
  });

  group('sessionMentionMarkdown', () {
    test('links title to session id', () {
      expect(
        sessionMentionMarkdown('sess-1', 'Fix login'),
        '[Fix login](#sess-1)',
      );
    });

    test('bare #id when title empty or equal to id', () {
      expect(sessionMentionMarkdown('sess-1', ''), '#sess-1');
      expect(sessionMentionMarkdown('sess-1', 'sess-1'), '#sess-1');
    });

    test('escapes brackets in title', () {
      expect(
        sessionMentionMarkdown('s1', 'a[b]'),
        '[a\\[b\\]](#s1)',
      );
    });
  });
}
