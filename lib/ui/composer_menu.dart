import 'dart:collection';

import 'package:flutter/material.dart';

import '../protocol/conversation.dart';
import 'theme.dart';

/// Groups model options by provider, preserving first-appearance order.
/// Key prefers the desktop-provided `modelProviderName`; falls back to the
/// provider segment of the value (`builtin:plan/GLM-5.2` → `builtin:plan`).
LinkedHashMap<String, List<ConfigOptionValue>> groupModelOptions(
    List<ConfigOptionValue> options) {
  String keyOf(ConfigOptionValue v) {
    if (v.modelProviderName != null && v.modelProviderName!.isNotEmpty) {
      return v.modelProviderName!;
    }
    final idx = v.value.lastIndexOf('/');
    return idx <= 0 ? v.value : v.value.substring(0, idx);
  }

  final groups = LinkedHashMap<String, List<ConfigOptionValue>>();
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
class ComposerChip extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color? labelColor;
  final double iconSize;
  final double fontSize;
  final bool enabled;
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
    final chip = Container(
      decoration: BoxDecoration(
        color: _open ? ZInk.tile(context) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(widget.icon, size: widget.iconSize, color: chipColor),
          const SizedBox(width: 5),
          Text(widget.label,
              style: TextStyle(fontSize: widget.fontSize, color: chipColor)),
          const SizedBox(width: 2),
          Icon(Icons.expand_more, size: 14, color: chipColor),
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

/// Two-level model menu: the current provider's models list flat; other
/// providers drill into an in-card second page (official web uses a side
/// flyout — an in-card drill reads better on narrow screens).
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
      return _modelRows(groups.values.expand((m) => m).toList(),
          withProviderTags: true);
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
    String? currentProvider;
    groups.forEach((provider, models) {
      if (models.any((v) => v.value == widget.currentModelValue)) {
        currentProvider = provider;
      }
    });
    final rows = <Widget>[];
    groups.forEach((provider, models) {
      if (provider == currentProvider) {
        rows.addAll(_modelRows(models, withProviderTags: false));
      } else {
        final isCurrent =
            models.any((v) => v.value == widget.currentModelValue);
        rows.add(ComposerMenuRow(
          entry: ComposerMenuEntry(
            title: provider,
            subtitle: '${models.length} 个模型',
            selected: isCurrent,
          ),
          onTap: () => setState(() => _openProvider = provider),
          trailing: const Icon(Icons.chevron_right, size: 16),
        ));
      }
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
