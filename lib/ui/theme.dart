import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Design tokens + theme controller (dark / light / system, persisted).
class ThemeController extends ChangeNotifier {
  static const _prefsKey = 'zemote_theme_mode';

  ThemeMode _mode = ThemeMode.dark;
  ThemeMode get mode => _mode;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    _mode = switch (saved) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.system => 'system',
        _ => 'dark',
      },
    );
  }
}

class ZColors {
  static const primary = Color(0xFF3B82F6);
  static const primaryDim = Color(0xFF2563EB);

  // ---- Official web palette (theme-zai-dark / theme-zai-light CSS
  // variables, extracted from the remote v4 bundle 2026-09-07):
  //   dark  background #161616 · header/panel/sidebar #202020 ·
  //         card/popover/input #2B2B2B · border #FFFFFF1A ·
  //         border-hover #FFFFFF26 · hover/surface #FFFFFF0D · text #DEDEDE
  //   light background #F8F8F8 · chrome white · border #0D0D0D1A ·
  //         text #3A3A3A
  static const darkBg = Color(0xFF161616);
  static const darkSurface = Color(0xFF202020);
  static const darkCard = Color(0xFF2B2B2B);
  static const darkBorder = Color(0x1AFFFFFF);
  static const darkBorderHover = Color(0x26FFFFFF);
  static const darkHover = Color(0x0DFFFFFF);

  static const success = Color(0xFF22C55E);
  static const warning = Color(0xFFF59E0B);
  static const danger = Color(0xFFEF4444);
  static const running = Color(0xFF38BDF8);

  /// Full Access accent, calibrated against the official web client:
  /// dark #FF8A30, light #E07B00.
  static const fullAccess = Color(0xFFFF8A30);
  static const fullAccessDeep = Color(0xFFE07B00);

  /// Composer container surface (official web parity):
  /// dark #2B2B2B, light white — 16px radius, hairline border.
  static const composerDark = Color(0xFF2B2B2B);
  static const composerLight = Color(0xFFFFFFFF);

  /// Sidebar surface (official web `--color-sidebar`: #202020 on dark;
  /// the light theme stays white like the rest of the chrome).
  static const sidebarDark = Color(0xFF202020);

  /// `--color-surface`: dark white@5%, light black@4% — user bubble and
  /// reasoning tile fill.
  static const messageSurfaceDark = Color(0x0DFFFFFF);
  static const messageSurfaceLight = Color(0x0A0D0D0D);

  /// `--color-border`: dark white@10%, light black@10%.
  static const messageBorderDark = Color(0x1AFFFFFF);
  static const messageBorderLight = Color(0x1A0D0D0D);

  /// `--color-trajectory-*` timeline accents.
  static const trajectoryUser = Color(0xFF60A5FA);
  static const trajectoryAssistant = Color(0xFF2DD4BF);
  static const trajectoryReasoning = Color(0xFFA78BFA);
  static const trajectoryToolCall = Color(0xFFF59E0B);
  static const trajectoryToolResult = Color(0xFF38BDF8);

  /// `--color-diff-added/removed` line accents (dark #46BF72/#FF5C5C,
  /// light #1E8A3E/#E03131).
  static const diffAddedDark = Color(0xFF46BF72);
  static const diffRemovedDark = Color(0xFFFF5C5C);
  static const diffAddedLight = Color(0xFF1E8A3E);
  static const diffRemovedLight = Color(0xFFE03131);

  /// `--color-interaction-confirmation-*` (permission/approval cards).
  static const confirmSurfaceDark = Color(0x2946BF72);
  static const confirmSurfaceLight = Color(0xFFEAF7EE);
  static const confirmForegroundDark = Color(0xFF87D9A4);
  static const confirmForegroundLight = Color(0xFF166B32);

  static const lightBg = Color(0xFFF8F8F8);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightBorder = Color(0x1A0D0D0D);
}

/// Theme-aware ink colors. Replaces hardcoded `Colors.white*` (dark-theme
/// ink) which become illegible on the light surfaces. The dark theme keeps
/// the existing white ramp; the light theme maps it onto a slate ramp so
/// text/icons stay readable on white backgrounds.
class ZInk {
  static bool _isLight(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light;

  // Neutral (blue-free) ink ramps matching the official palette:
  // dark text #DEDEDE with alpha steps, light #262626 ramp.
  static const _inkDark = Color(0xFFDEDEDE);
  static const _inkLight = Color(0xFF262626);
  static const _inkLight700 = Color(0xFF404040);
  static const _inkLight600 = Color(0xFF595959);
  static const _inkLight500 = Color(0xFF8C8C8C);
  static const _inkLight300 = Color(0xFFD9D9D9);

  /// Primary text/ink (dark: #DEDEDE, light: #262626).
  static Color solid(BuildContext context) =>
      _isLight(context) ? _inkLight : _inkDark;

  /// Secondary ink (dark: #DEDEDE@70%, light: #404040).
  static Color soft(BuildContext context) => _isLight(context)
      ? _inkLight700
      : const Color(0xB3DEDEDE);

  /// Muted ink (dark: #DEDEDE@54%, light: #595959).
  static Color muted(BuildContext context) => _isLight(context)
      ? _inkLight600
      : const Color(0x8ADEDEDE);

  /// Faint ink (dark: #DEDEDE@38%, light: #8C8C8C).
  static Color faint(BuildContext context) => _isLight(context)
      ? _inkLight500
      : const Color(0x61DEDEDE);

  /// Ghost ink (dark: #DEDEDE@28%, light: #8C8C8C).
  static Color ghost(BuildContext context) => _isLight(context)
      ? _inkLight500
      : const Color(0x47DEDEDE);

  /// Hairline ink (dark: white12, light: #D9D9D9).
  static Color hairline(BuildContext context) => _isLight(context)
      ? _inkLight300
      : const Color(0x1FFFFFFF);

  /// Subtle tile fill (official hover/surface 5%: dark white@5%, light
  /// black@5%).
  static Color tile(BuildContext context) => _isLight(context)
      ? const Color(0x0D000000)
      : ZColors.darkHover;

  /// Tile hairline border (dark: white@6%, light: black@6%).
  static Color tileBorder(BuildContext context) => _isLight(context)
      ? const Color(0x0F000000)
      : Colors.white.withValues(alpha: 0.06);

  /// Popover/card fill (official `--color-popover`: dark #2B2B2B, light
  /// white) — menu cards, status panel, dropdowns.
  static Color panel(BuildContext context) => _isLight(context)
      ? Colors.white
      : ZColors.darkCard;

  /// Popover outline (official 10% border token).
  static Color panelBorder(BuildContext context) => _isLight(context)
      ? ZColors.messageBorderLight
      : ZColors.messageBorderDark;

  /// Sidebar surface (official `--color-sidebar` token).
  static Color sidebar(BuildContext context) =>
      _isLight(context) ? Colors.white : ZColors.sidebarDark;

  /// Reasoning-specific fill, visually distinct from tool output.
  static Color reasoningPanel(BuildContext context) => _isLight(context)
      ? const Color(0xFFF5F5F5)
      : const Color(0xFF242424);

  /// Official message-surface fill (`--color-surface` token).
  static Color messageSurface(BuildContext context) => _isLight(context)
      ? ZColors.messageSurfaceLight
      : ZColors.messageSurfaceDark;

  /// Official hairline border (`--color-border` token, white/black@10%).
  static Color messageBorder(BuildContext context) => _isLight(context)
      ? ZColors.messageBorderLight
      : ZColors.messageBorderDark;

  /// Diff line accents (`--color-diff-added/removed` tokens).
  static Color diffAdded(BuildContext context) => _isLight(context)
      ? ZColors.diffAddedLight
      : ZColors.diffAddedDark;

  static Color diffRemoved(BuildContext context) => _isLight(context)
      ? ZColors.diffRemovedLight
      : ZColors.diffRemovedDark;

  /// Permission/approval confirmation accents.
  static Color confirmSurface(BuildContext context) => _isLight(context)
      ? ZColors.confirmSurfaceLight
      : ZColors.confirmSurfaceDark;

  static Color confirmForeground(BuildContext context) => _isLight(context)
      ? ZColors.confirmForegroundLight
      : ZColors.confirmForegroundDark;

  static Color reasoningBorder(BuildContext context) => _isLight(context)
      ? const Color(0xFFE5E5E5)
      : ZColors.darkBorderHover;

  /// Code block background (neutral: dark #1E1E1E, light #F0F0F0).
  static Color codeBlockBg(BuildContext context) => _isLight(context)
      ? const Color(0xFFF0F0F0)
      : const Color(0xFF1E1E1E);

  /// Inline code background.
  static Color codeInlineBg(BuildContext context) => _isLight(context)
      ? const Color(0x14000000)
      : Colors.white.withValues(alpha: 0.08);

  /// Code text (light: neutral dark; dark: soft sky accent).
  static Color codeText(BuildContext context) => _isLight(context)
      ? const Color(0xFF333333)
      : const Color(0xFF93C5FD);

  /// Official `--color-surface-hover` (bar tracks): white@10% dark,
  /// black@5% light (theme-zai-* values).
  static Color surfaceHover(BuildContext context) => _isLight(context)
      ? const Color(0x0D0D0D0D)
      : const Color(0x1AFFFFFF);

  /// Official `--color-usage-chart-N` (theme-zai-* values): 1 blue,
  /// 2 green, 3 violet, 5 orange. Index is 1-based; unknown indexes fall
  /// back to chart-1 (the bundle does `DI[min(i, len-1)] ?? DI[0]`).
  static Color usageChart(BuildContext context, int index) {
    final light = _isLight(context);
    switch (index) {
      case 2:
        return light ? const Color(0xFF1E8A3E) : const Color(0xFF46BF72);
      case 3:
        return light ? const Color(0xFF9E77ED) : const Color(0xFF7B5CE5);
      case 4:
        return light ? const Color(0xFFE03131) : const Color(0xFFFF5C5C);
      case 5:
        return light ? const Color(0xFFE07B00) : const Color(0xFFFF8A30);
      case 6:
        return light ? const Color(0xFF0AA7A7) : const Color(0xFF42C8C8);
      default:
        return light ? const Color(0xFF0B7FFF) : const Color(0xFF4099FF);
    }
  }
}

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: ZColors.primary,
    brightness: Brightness.dark,
  ).copyWith(
    primary: ZColors.primary,
    surface: ZColors.darkSurface,
    surfaceContainerHighest: ZColors.darkCard,
    outline: ZColors.darkBorder,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: ZColors.darkBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: ZColors.darkBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: Color(0xFFDEDEDE),
      ),
      iconTheme: IconThemeData(color: Color(0xFFB3B3B3)),
    ),
    cardTheme: CardThemeData(
      color: ZColors.darkCard,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: ZColors.darkBorder),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ZColors.darkSurface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.darkBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.darkBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.primary, width: 1.5),
      ),
      hintStyle: const TextStyle(color: Color(0xFF8C8C8C), fontSize: 14),
    ),
    dividerTheme: const DividerThemeData(
      color: ZColors.darkBorder,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: ZColors.darkCard,
      contentTextStyle: const TextStyle(color: Color(0xFFDEDEDE)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: ZColors.darkSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: ZColors.darkSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: ZColors.primary,
      unselectedLabelColor: Color(0xFF8C8C8C),
      indicatorColor: ZColors.primary,
      dividerColor: ZColors.darkBorder,
      labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      unselectedLabelStyle: TextStyle(fontSize: 13),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      backgroundColor: ZColors.darkSurface,
      indicatorColor: ZColors.primary.withValues(alpha: 0.18),
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          )),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.white.withValues(alpha: 0.04),
      selectedColor: ZColors.primary.withValues(alpha: 0.18),
      side: const BorderSide(color: ZColors.darkBorder),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      labelStyle: const TextStyle(fontSize: 12),
      padding: const EdgeInsets.symmetric(horizontal: 6),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: Color(0xFFDEDEDE), fontSize: 14, height: 1.5),
      bodySmall: TextStyle(color: Color(0xFF8C8C8C), fontSize: 12, height: 1.4),
      titleMedium: TextStyle(
          color: Color(0xFFDEDEDE), fontSize: 15, fontWeight: FontWeight.w600),
      labelSmall: TextStyle(color: Color(0xFF8C8C8C), fontSize: 11),
    ),
  );
}

ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: ZColors.primary,
    brightness: Brightness.light,
  ).copyWith(
    primary: ZColors.primaryDim,
    surface: ZColors.lightSurface,
    outline: ZColors.lightBorder,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: ZColors.lightBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: ZColors.lightBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: Color(0xFF262626),
      ),
      iconTheme: IconThemeData(color: Color(0xFF595959)),
    ),
    cardTheme: CardThemeData(
      color: ZColors.lightCard,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: ZColors.lightBorder),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ZColors.lightSurface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.lightBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.lightBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.primary, width: 1.5),
      ),
      hintStyle: const TextStyle(color: Color(0xFF737373), fontSize: 14),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: ZColors.lightSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: ZColors.lightSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: ZColors.primaryDim,
      unselectedLabelColor: Color(0xFF595959),
      indicatorColor: ZColors.primaryDim,
      dividerColor: ZColors.lightBorder,
      labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      unselectedLabelStyle: TextStyle(fontSize: 13),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      backgroundColor: ZColors.lightSurface,
      indicatorColor: ZColors.primary.withValues(alpha: 0.12),
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          )),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: const Color(0xFFF1F5F9),
      selectedColor: ZColors.primary.withValues(alpha: 0.12),
      side: const BorderSide(color: ZColors.lightBorder),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      labelStyle: const TextStyle(fontSize: 12),
      padding: const EdgeInsets.symmetric(horizontal: 6),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
  );
}

/// Provides the app-wide [ThemeController] down the tree.
class ThemeControllerProvider extends InheritedWidget {
  final ThemeController controller;

  const ThemeControllerProvider({
    super.key,
    required this.controller,
    required super.child,
  });

  static ThemeController? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ThemeControllerProvider>()
      ?.controller;

  @override
  bool updateShouldNotify(ThemeControllerProvider oldWidget) =>
      controller != oldWidget.controller;
}

/// Status color mapping shared by task/chat UIs. The unknown-status fallback
/// is theme-aware so it stays visible on light surfaces too.
Color statusColor(String status, BuildContext context) {
  final light = Theme.of(context).brightness == Brightness.light;
  switch (status) {
    case 'running':
    case 'prewarming':
      return light ? const Color(0xFF0369A1) : ZColors.running;
    case 'error':
    case 'failed':
      return light ? const Color(0xFFB91C1C) : ZColors.danger;
    case 'completed':
    case 'completedSuccess':
      return light ? const Color(0xFF15803D) : ZColors.success;
    case 'completedInterrupted':
    case 'cancelled':
      return light ? const Color(0xFFB45309) : ZColors.warning;
    default:
      return ZInk.faint(context);
  }
}

/// Human relative time, e.g. `刚刚` / `5分钟前` / `昨天` / `3天前`.
String relativeTime(int? millis) {
  if (millis == null || millis <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
  if (diff.inHours < 24) return '${diff.inHours}小时前';
  if (diff.inDays == 1) return '昨天';
  if (diff.inDays < 30) return '${diff.inDays}天前';
  return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')}';
}
