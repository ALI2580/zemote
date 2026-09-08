import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../protocol/conversation.dart';
import '../protocol/entitlement.dart';
import 'official_icons.dart';
import 'theme.dart';

/// Groups model options by provider and orders the groups the way the
/// official model menu does (bundle `KI`/`GI`, 2026-09-08 decryption):
/// `builtin:*` preset providers come first in a fixed priority order
/// (Z.ai start/coding/api-key, BigModel start/coding/api-key, ZAPI),
/// everything else keeps its wire order after them (stable sort at
/// priority 200). Key prefers the desktop-provided `modelProviderName`;
/// falls back to the provider segment of the value
/// (`builtin:zai/GLM-5.2` → `builtin:zai`).
///
/// Inside a first-party group the recommended models (`GLM-5.2`,
/// `GLM-5-Turbo` — official `Ed` set) are pinned to the top in that
/// order; the rest keep their wire order.
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

  // Group priority = best (lowest) priority among its options' provider
  // ids; ties keep first-appearance order (the official sort is stable).
  int priorityOf(List<ConfigOptionValue> members) {
    var best = 200;
    for (final v in members) {
      best = math.min(best, officialProviderPriority(_providerIdOf(v)));
    }
    return best;
  }

  final order = <String, int>{};
  var index = 0;
  for (final entry in groups.entries) {
    order[entry.key] = index++;
  }
  final sortedKeys = groups.keys.toList()
    ..sort((a, b) {
      final p = priorityOf(groups[a]!).compareTo(priorityOf(groups[b]!));
      return p != 0 ? p : order[a]!.compareTo(order[b]!);
    });

  return {
    for (final key in sortedKeys) key: _pinRecommended(groups[key]!),
  };
}

/// Stable pin of the official recommended models inside one provider
/// group; non-first-party groups are returned untouched.
List<ConfigOptionValue> _pinRecommended(List<ConfigOptionValue> members) {
  final firstParty = members.any((v) => isBuiltinProviderId(_providerIdOf(v)));
  if (!firstParty) return members;
  int rankOf(ConfigOptionValue v) {
    final idx = v.value.lastIndexOf('/');
    final model = idx < 0 ? v.value : v.value.substring(idx + 1);
    final rank = kRecommendedModels.indexOf(model);
    return rank < 0 ? kRecommendedModels.length : rank;
  }

  final indexed = [for (var i = 0; i < members.length; i++) (i, members[i])];
  indexed.sort((a, b) {
    final r = rankOf(a.$2).compareTo(rankOf(b.$2));
    return r != 0 ? r : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// Provider id of an option: the schema field when present, else the
/// provider segment of the value (`builtin:zai/GLM-5.2` → `builtin:zai`)
/// so older desktops that omit `modelProviderId` still get pinned.
String? _providerIdOf(ConfigOptionValue v) {
  final id = v.modelProviderId?.trim();
  if (id != null && id.isNotEmpty) return id;
  final idx = v.value.lastIndexOf('/');
  return idx <= 0 ? null : v.value.substring(0, idx);
}

/// One row inside a composer menu card.
class ComposerMenuEntry {
  final IconData? icon;

  /// Official lucide glyph (takes precedence over [icon]).
  final String? lucideIcon;
  final String title;
  final String? subtitle;
  final bool selected;
  final String? trailingTag;

  const ComposerMenuEntry({
    this.icon,
    this.lucideIcon,
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

  /// Trigger inner padding. Official OF/VI/S2e triggers differ per chip:
  /// model `pl-2 pr-1.5` (8/6), thought `px-1.5 py-1.5` (6/6), mode
  /// `pl-2 pr-1.5` when expanded. null = the model form (8/6).
  final EdgeInsetsGeometry? padding;

  /// Dropdown card width in px (official: model w-48 flat / w-max grouped,
  /// mode w-64, plus-menu w-52). Clamped to screen width internally.
  final double menuWidth;

  /// Vertical gap between trigger top and card bottom (official radix
  /// sideOffset: model/plus menus 0, thought/mode menus 4).
  final double sideOffset;

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
    this.padding,
    this.menuWidth = 288,
    this.sideOffset = 4,
  });

  @override
  State<ComposerChip> createState() => _ComposerChipState();
}

/// Narrow-screen cutoff for the mobile menu form. Matches the app-shell
/// breakpoint (below 640 there is no side nav / master-detail) — on phones
/// the anchored popper is awkward so chips open a bottom sheet instead;
/// wide screens keep the official top-anchored popover.
const double kMobileMenuWidth = 640;

/// Opens [builder] as a Material bottom sheet in the official popover
/// palette — shared by ComposerChip and the plus menu on narrow screens.
void showComposerMenuSheet(
  BuildContext context, {
  required Widget Function(BuildContext context, VoidCallback close) builder,
}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: ZInk.panel(context),
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.6,
    ),
    builder: (sheetContext) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
        child: builder(
          sheetContext,
          () => Navigator.of(sheetContext).pop(),
        ),
      ),
    ),
  );
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
    // 窄屏（手机）走底部弹窗 —— 官方 popper 是 PC 大屏交互，移动端
    // 锚定浮窗不好按也不好转屏适配；宽屏保持官方浮窗。
    if (MediaQuery.sizeOf(context).width < kMobileMenuWidth) {
      setState(() {});
      showComposerMenuSheet(context, builder: widget.menuBuilder);
      return;
    }
    final overlay = Overlay.of(context, rootOverlay: true);
    // 官方 radix popper 的碰撞翻转（avoidCollisions + collisionPadding 8）：
    // 菜单从 chip 左缘向右展开，卡片会越出右缘时翻转为右对齐，宽度钳制
    // 到屏宽内。
    final box = context.findRenderObject() as RenderBox?;
    final screenW = MediaQuery.sizeOf(context).width;
    final rightEdge = box != null ? box.localToGlobal(Offset.zero).dx + box.size.width : 0.0;
    final cardWidth = math.min(widget.menuWidth, screenW - 16);
    final alignRight = screenW - rightEdge < cardWidth / 2 + 8;
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
            offset: Offset(0, -widget.sideOffset),
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
    final showBar = widget.barFill != null;
    // 官方 <384px 触发器：size-7(28px) 方形、居中、gap-0、p-0（有竖条时
    // 保持流式布局，方形会截断竖条）。
    final square = widget.iconOnly && widget.barFill == null;
    final chip = Container(
      decoration: BoxDecoration(
        color: _open ? ZInk.tile(context) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: square
          ? EdgeInsets.zero
          : (widget.padding ?? const EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
      height: square ? 28 : null,
      width: square ? 28 : null,
      alignment: square ? Alignment.center : null,
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
            // 官方 label `min-w-0 truncate`：长模型名在窄 composer 内
            // 优先被压缩省略，不把工具栏行撑爆。
            Flexible(
              child: Text(widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: widget.fontSize, color: chipColor)),
            ),
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

/// Dropdown card container — official radix menu/popover surface:
/// `rounded-xl border border-popover-border bg-menu p-1 !shadow-md`.
/// [maxWidth] is the card width (already clamped to screen by the chip).
class ComposerMenuCard extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const ComposerMenuCard(
      {super.key, required this.child, this.maxWidth = 288});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: maxWidth,
      constraints: const BoxConstraints(maxHeight: 420),
      decoration: BoxDecoration(
        color: ZInk.panel(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZInk.panelBorder(context)),
        boxShadow: [
          // tailwind shadow-md（双层）
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 6,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          // 官方 p-1：卡内 4px，菜单行自带 pl-2(8)。
          padding: const EdgeInsets.all(4),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [child],
            ),
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
    // 官方菜单项（select item / dropdown item）：正文正常墨色（选中不变
    // 蓝），check 图标 subtle；min-h-8、pl-2 pr-8、图标 size-4。
    final ink = ZInk.soft(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            if (entry.lucideIcon != null) ...[
              LucideIcon(entry.lucideIcon!, size: 16, color: ink),
              const SizedBox(width: 10),
            ] else if (entry.icon != null) ...[
              Icon(entry.icon, size: 16, color: ink),
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
                              ? FontWeight.w500
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
              LucideIcon('check', size: 16, color: ZInk.muted(context)),
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
