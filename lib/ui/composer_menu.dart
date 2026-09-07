import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../protocol/conversation.dart';
import 'official_icons.dart';
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
/// Narrow-composer variants (official container-query behavior, decoded from
/// the OF/VI components): [iconOnly] renders a 28px square centered icon
/// button (`@max-sm:size-7 justify-center gap-0 p-0`); [showIcon]=false
/// reproduces the model chip's `triggerIconClassName:hidden @sm/composer:hidden`
/// (icon only below 384px, label+chevron above); [barFill] renders the
/// thought-level vertical bar (official VI: full-height 4px track
/// `bg-current/10`, success fill growing from the bottom with a 300ms
/// spring curve, 4px minimum visible fill, shown 384–576px only).
class ComposerChip extends StatefulWidget {
  final IconData icon;

  /// Official lucide glyph name (kOfficialIcons) — takes precedence over
  /// [icon] when set, so the toolbar uses the exact official artwork.
  final String? lucideIcon;
  final String label;

  /// Optional provider prefix rendered before [label] (official model chip
  /// `triggerLabelPrefix`, e.g. `供应商/` — shown ≥672px only by the caller).
  final String? prefixLabel;
  final Color? labelColor;
  final double iconSize;
  final double fontSize;
  final bool enabled;
  final bool iconOnly;

  /// false = official model-chip text form (no leading icon at all).
  final bool showIcon;

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
    this.lucideIcon,
    this.prefixLabel,
    this.labelColor,
    this.iconSize = 16,
    this.fontSize = 13,
    this.enabled = true,
    this.iconOnly = false,
    this.showIcon = true,
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
    // 官方 radix popper 的碰撞翻转：chip 落在屏幕右半时菜单改为右对齐，
    // 卡片宽度钳制到屏宽内，避免模型/思考菜单从右侧溢出。
    final box = context.findRenderObject() as RenderBox?;
    final screenW = MediaQuery.sizeOf(context).width;
    final rightEdge = box != null ? box.localToGlobal(Offset.zero).dx + box.size.width : 0.0;
    final alignRight = screenW - rightEdge < 180;
    final cardWidth = math.min(288.0, screenW - 16);
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
            targetAnchor: alignRight ? Alignment.topRight : Alignment.topLeft,
            followerAnchor:
                alignRight ? Alignment.bottomRight : Alignment.bottomLeft,
            offset: const Offset(0, -6),
            showWhenUnlinked: false,
            child: Material(
              color: Colors.transparent,
              child: ComposerMenuCard(
                  maxWidth: cardWidth,
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
      // 官方 <384px 触发器：size-7(28px) 方形、居中、gap-0、p-0。
      padding: widget.iconOnly
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      height: widget.iconOnly ? 28 : null,
      width: widget.iconOnly ? 28 : null,
      alignment: widget.iconOnly ? Alignment.center : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.showIcon)
            widget.lucideIcon != null
                ? LucideIcon(widget.lucideIcon!,
                    size: widget.iconSize, color: chipColor)
                : Icon(widget.icon, size: widget.iconSize, color: chipColor),
          // 官方思考强度竖条（VI，@sm..@xl）：w-1 全高圆角轨道
          // bg-current/10，success 填充自底部长出，300ms 弹性曲线，
          // 填充 >0 时至少 4px 可见（min-h-1）。
          if (showBar) ...[
            SizedBox(width: widget.showIcon ? 6 : 0),
            _ThoughtLevelBar(fill: widget.barFill!),
          ],
          if (!widget.iconOnly && widget.barFill == null) ...[
            if (widget.prefixLabel != null) ...[
              SizedBox(width: widget.showIcon ? 5 : 0),
              Text(widget.prefixLabel!,
                  style: TextStyle(
                      fontSize: widget.fontSize, color: chipColor)),
            ],
            SizedBox(width: widget.showIcon || widget.prefixLabel != null ? 5 : 0),
            Text(widget.label,
                style: TextStyle(
                    fontSize: widget.fontSize, color: chipColor)),
            const SizedBox(width: 2),
            LucideIcon('chevron-down', size: 14, color: chipColor),
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

/// 思考强度竖条：官方 `transition-[height] duration-300
/// ease-[cubic-bezier(0.34,1.56,0.64,1)]`——300ms 回弹曲线（Flutter 的
/// Cubic 同参），填充 >0 时最小 4px（min-h-1）。
class _ThoughtLevelBar extends StatelessWidget {
  final double fill;

  const _ThoughtLevelBar({required this.fill});

  @override
  Widget build(BuildContext context) {
    const trackColor = Color(0x1A000000);
    return Container(
      width: 4,
      height: 15,
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.light
            ? trackColor
            : const Color(0x1AFFFFFF),
        borderRadius: BorderRadius.circular(2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: AnimatedFractionallySizedBox(
            duration: const Duration(milliseconds: 300),
            curve: const Cubic(0.34, 1.56, 0.64, 1),
            alignment: Alignment.bottomCenter,
            heightFactor: fill <= 0
                ? 0
                : (fill.clamp(0.0, 1.0) < 4 / 15 ? 4 / 15 : fill)
                    .clamp(0.0, 1.0),
            child: Container(color: ZColors.success),
          ),
        ),
      ),
    );
  }
}

/// Dropdown card container (dark: near-black, light: white — panel tones).
/// [maxWidth] clamps the card to the available screen width so menus never
/// overflow narrow composers.
class ComposerMenuCard extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const ComposerMenuCard(
      {super.key, required this.child, this.maxWidth = 288});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: math.min(288.0, maxWidth),
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
