import 'package:flutter/material.dart';

import 'theme.dart';

/// Composer mention menu (`@` files / `#` sessions), mirroring the official
/// web client's prompt-mention popup. Injection strings follow the official
/// serialization: mention tokens live in the message text as markdown links
/// (file = `[label](./relative/path)`, session = `[#title](#sessionId)`);
/// there is no dedicated protocol field.

enum MentionCategory { files, sessions, skills }

extension MentionCategoryLabel on MentionCategory {
  String get title => switch (this) {
        MentionCategory.files => '文件',
        MentionCategory.sessions => '会话',
        MentionCategory.skills => '技能',
      };
}

class MentionItem {
  final MentionCategory category;
  final String title;
  final String subtitle;
  final String insertMarkdown;
  final bool isDirectory;

  const MentionItem({
    required this.category,
    required this.title,
    required this.subtitle,
    required this.insertMarkdown,
    this.isDirectory = false,
  });
}

/// `[label](path)` with the official escaping: brackets in the label, `>` in
/// the target; bare relative paths get the `./` prefix, directories a tail `/`.
String fileMentionMarkdown(String title, String path, {bool directory = false}) {
  var p = path.trim().replaceAll('\\', '\\\\').replaceAll('>', '\\>');
  if (directory && !p.endsWith('/')) p = '$p/';
  if (!p.startsWith('/') && !p.startsWith('./') && !p.startsWith('../')) {
    p = './$p';
  }
  final label = title
      .replaceAll('\\', '\\\\')
      .replaceAll('[', '\\[')
      .replaceAll(']', '\\]');
  return '[$label]($p)';
}

/// `[#title](#sessionId)`, or a bare `#sessionId` when title is empty.
String sessionMentionMarkdown(String sessionId, String title) {
  final t = title.trim();
  if (t.isEmpty || t == sessionId) return '#$sessionId';
  final label = t
      .replaceAll('\\', '\\\\')
      .replaceAll('[', '\\[')
      .replaceAll(']', '\\]');
  return '[$label](#$sessionId)';
}

class MentionMenuBar extends StatelessWidget {
  /// Filter word typed after the trigger character (`@` or `#`).
  final String query;

  /// Per category entries; a `null` value means still loading, an empty list
  /// means nothing matched (or the source degraded — e.g. file service
  /// unavailable).
  final Map<MentionCategory, List<MentionItem>?> items;

  /// Categories hidden entirely (e.g. files when readdir is unavailable).
  final Set<MentionCategory> hidden;

  final void Function(MentionItem item) onSelect;

  const MentionMenuBar({
    super.key,
    required this.query,
    required this.items,
    this.hidden = const {},
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final q = query.toLowerCase();
    final sections = <MentionCategory, List<MentionItem>>{};
    for (final category in MentionCategory.values) {
      if (hidden.contains(category)) continue;
      final list = items[category];
      if (list == null) continue; // still loading
      final filtered = q.isEmpty
          ? list
          : list
              .where((i) =>
                  i.title.toLowerCase().contains(q) ||
                  i.subtitle.toLowerCase().contains(q))
              .toList();
      if (filtered.isNotEmpty) sections[category] = filtered;
    }

    final anyLoading =
        items.entries.any((e) => e.value == null && !hidden.contains(e.key));

    if (sections.isEmpty) {
      return Container(
        margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          anyLoading ? '正在加载上下文…' : '没有匹配的上下文',
          style: TextStyle(fontSize: 12, color: ZInk.faint(context)),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      constraints: const BoxConstraints(maxHeight: 300),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZInk.panelBorder(context)),
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          for (final entry in sections.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
              child: Text(
                entry.key.title,
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.5,
                  color: ZInk.faint(context),
                ),
              ),
            ),
            // 官方每个类目默认只露出前几条，避免长列表淹没输入框。
            for (final item in entry.value
                .take(entry.key == MentionCategory.files ? 6 : 4))
              ListTile(
                dense: true,
                leading: Icon(
                  item.category == MentionCategory.files
                      ? (item.isDirectory
                          ? Icons.folder_outlined
                          : Icons.insert_drive_file_outlined)
                      : item.category == MentionCategory.sessions
                          ? Icons.chat_bubble_outline
                          : Icons.auto_awesome_outlined,
                  size: 16,
                  color: item.category == MentionCategory.skills
                      ? ZColors.warning
                      : ZColors.primary,
                ),
                title: Text(
                  item.title,
                  style: const TextStyle(fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: item.subtitle.isEmpty
                    ? null
                    : Text(
                        item.subtitle,
                        style: TextStyle(
                            fontSize: 11, color: ZInk.faint(context)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                onTap: () => onSelect(item),
              ),
          ],
        ],
      ),
    );
  }
}
