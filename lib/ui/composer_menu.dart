import 'package:flutter/material.dart';

import '../protocol/conversation.dart';
import 'theme.dart';

/// Groups model options by provider, preserving first-appearance order.
/// Key prefers the desktop-provided `modelProviderName`; falls back to the
/// provider segment of the value (`builtin:plan/GLM-5.2` → `builtin:plan`).
Map<String, List<ConfigOptionValue>> groupModelOptions(
    List<ConfigOptionValue> options) {
  String keyOf(ConfigOptionValue v) {
    if (v.modelProviderName != null && v.modelProviderName!.isNotEmpty) {
      return v.modelProviderName!;
    }
    final idx = v.value.lastIndexOf('/');
    return idx <= 0 ? v.value : v.value.substring(0, idx);
  }

  final groups = <String, List<ConfigOptionValue>>{};
  for (final v in options) {
    groups.putIfAbsent(keyOf(v), () => []).add(v);
  }
  return groups;
}

/// One row inside a composer menu card.
class ComposerMenuEntry {
  final IconData? icon;
  final String title;
  final String? subtitle;
  final bool selected;
  final String? trailingTag;

  const ComposerMenuEntry({
    this.icon,
    required this.title,
    this.subtitle,
    this.selected = false,
    this.trailingTag,
  });
}

/// Anchored toolbar chip with a dropdown card pinned above it (official-web
/// composer style). The chip owns its overlay; tapping outside closes it.
///
/// Narrow-composer variants (official container-query behavior): [iconOnly]
/// drops the label and chevron for a square icon button; [barFill] renders
/// the thought-level vertical bar instead of the label (official shows the
/// bar between 384–576px composer widths, green fill = level progress).
class ComposerChip extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color? labelColor;
  final double iconSize;
  final double fontSize;
  final bool enabled;
  final bool iconOnly;

  /// 0..1 — fill height of the vertical level bar; null hides the bar.
  final double? barFill;
  final String? tooltip;

  /// Builds the dropdown content. [close] dismisses the menu — call it
  /// before running the selected action so the overlay tears down first.
  final Widget Function(BuildContext context, VoidCallback close) menuBuilder;

  const ComposerChip({
    super.key,
    required this.icon,
    required this.label,
    required this.menuBuilder,
    this.labelColor,
    this.iconSize = 15,
    this.fontSize = 13,
    this.enabled = true,
    this.iconOnly = false,
    this.barFill,
    this.tooltip,
  });

  @override
  State<ComposerChip> createState() => _ComposerChipState();
}

class _ComposerChipState extends State<ComposerChip> {
  final _link = LayerLink();
  OverlayEntry? _entry;
  bool get _open => _entry != null;

  void _toggle() {
    if (_open) {
      _close();
      return;
    }
    final overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: const SizedBox.expand(),
            ),
          ),
          CompositedTransformFollower(
            link: _link,
            targetAnchor: Alignment.topLeft,
            followerAnchor: Alignment.bottomLeft,
            offset: const Offset(0, -6),
            showWhenUnlinked: false,
            child: Material(
              color: Colors.transparent,
              child: ComposerMenuCard(
                  child: widget.menuBuilder(context, _close)),
            ),
          ),
        ],
      ),
    );
    overlay.insert(_entry!);
    setState(() {});
  }

  void _close() {
    _entry?.remove();
    _entry = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chipColor = widget.labelColor ?? ZInk.soft(context);
    final showBar = widget.barFill != null && !widget.iconOnly;
    final chip = Container(
      decoration: BoxDecoration(
        color: _open ? ZInk.tile(context) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: EdgeInsets.symmetric(
          horizontal: widget.iconOnly ? 6 : 8, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(widget.icon, size: widget.iconSize, color: chipColor),
          // 官方思考强度竖条（@sm..@xl 区间）：4px 宽圆角条，success 绿从
          // 底部填充，填充高度 = 当前档位在已启用档位中的进度。
          if (showBar) ...[
            const SizedBox(width: 6),
            Container(
              width: 4,
              height: 18,
              decoration: BoxDecoration(
                color: chipColor.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(2),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: widget.barFill!.clamp(0.0, 1.0),
                    child: Container(color: ZColors.success),
                  ),
                ),
              ),
            ),
          ],
          if (!widget.iconOnly && widget.barFill == null) ...[
            const SizedBox(width: 5),
            Text(widget.label,
                style: TextStyle(
                    fontSize: widget.fontSize, color: chipColor)),
            const SizedBox(width: 2),
            Icon(Icons.expand_more, size: 14, color: chipColor),
          ],
        ],
      ),
    );
    return CompositedTransformTarget(
      link: _link,
      child: Tooltip(
        message: widget.tooltip ?? '',
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: widget.enabled ? _toggle : null,
          child: chip,
        ),
      ),
    );
  }
}

/// Dropdown card container (dark: near-black, light: white — panel tones).
class ComposerMenuCard extends StatelessWidget {
  final Widget child;

  const ComposerMenuCard({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 288,
      constraints: const BoxConstraints(maxHeight: 420),
      decoration: BoxDecoration(
        color: ZInk.panel(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZInk.panelBorder(context)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [child],
          ),
        ),
      ),
    );
  }
}

class ComposerMenuRow extends StatelessWidget {
  final ComposerMenuEntry entry;
  final VoidCallback onTap;
  final Widget? trailing;

  const ComposerMenuRow({
    super.key,
    required this.entry,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final ink = entry.selected ? ZColors.primary : ZInk.soft(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            if (entry.icon != null) ...[
              Icon(entry.icon, size: 17, color: ink),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.title,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: entry.selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: ink)),
                  if (entry.subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(entry.subtitle!,
                        style: TextStyle(
                            fontSize: 11.5, color: ZInk.faint(context))),
                  ],
                ],
              ),
            ),
            if (entry.trailingTag != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: ZInk.tile(context),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(entry.trailingTag!,
                    style:
                        TextStyle(fontSize: 10.5, color: ZInk.muted(context))),
              ),
            ],
            if (entry.selected) ...[
              const SizedBox(width: 8),
              Icon(Icons.check, size: 16, color: ZColors.primary),
            ] else ...[
              if (trailing != null) trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Two-level model menu: level 1 always lists every provider (the current
/// one highlighted with its model name), tapping a provider drills into an
/// in-card second page. Every provider keeps a visible row — collapsing the
/// current provider's models into an unlabeled flat list hid its provider
/// entry entirely after a switch.
class ComposerModelMenuBody extends StatefulWidget {
  final List<ConfigOptionValue> options;
  final String currentModelValue;
  final void Function(ConfigOptionValue value) onSelect;

  const ComposerModelMenuBody({
    super.key,
    required this.options,
    required this.currentModelValue,
    required this.onSelect,
  });

  @override
  State<ComposerModelMenuBody> createState() => _ComposerModelMenuBodyState();
}

class _ComposerModelMenuBodyState extends State<ComposerModelMenuBody> {
  String? _openProvider;

  @override
  Widget build(BuildContext context) {
    final groups = groupModelOptions(widget.options);
    if (groups.length < 2 || groups.length >= widget.options.length) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: _modelRows(groups.values.expand((m) => m).toList(),
            withProviderTags: true),
      );
    }
    final open = _openProvider;
    if (open != null && groups.containsKey(open)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _openProvider = null),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Row(
                children: [
                  Icon(Icons.arrow_back_ios_new,
                      size: 12, color: ZInk.ghost(context)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(open,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          ),
          ..._modelRows(groups[open]!, withProviderTags: false),
        ],
      );
    }
    final rows = <Widget>[];
    groups.forEach((provider, models) {
      ConfigOptionValue? current;
      for (final v in models) {
        if (v.value == widget.currentModelValue) current = v;
      }
      rows.add(ComposerMenuRow(
        entry: ComposerMenuEntry(
          icon: Icons.album_outlined,
          title: provider,
          subtitle: current != null
              ? '当前 · ${current.name}'
              : '${models.length} 个模型',
          selected: current != null,
        ),
        onTap: () => setState(() => _openProvider = provider),
        trailing: const Icon(Icons.chevron_right, size: 16),
      ));
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }

  List<Widget> _modelRows(List<ConfigOptionValue> models,
      {required bool withProviderTags}) {
    return [
      for (final v in models)
        ComposerMenuRow(
          entry: ComposerMenuEntry(
            title: v.name,
            trailingTag: withProviderTags ? v.modelProviderName : null,
            selected: v.value == widget.currentModelValue,
          ),
          onTap: () => widget.onSelect(v),
        ),
    ];
  }
}
