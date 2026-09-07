import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../protocol/conversation.dart';
import '../protocol/zemote_client.dart';
import '../state/log_store.dart';
import 'composer_menu.dart';
import 'diff_view.dart';
import 'markdown_view.dart';
import 'mention_menu.dart';
import 'official_icons.dart';
import 'theme.dart';
import 'structured_data_view.dart';
import '../voice/voice_model_store.dart';
import '../voice/voice_model_events.dart';
import '../voice/voice_transcriber.dart';

class PlanStep {
  final String content;
  final String status;

  const PlanStep({required this.content, this.status = 'pending'});

  bool get completed =>
      status == 'completed' || status == 'done' || status == 'complete';
}

/// Extracts the latest plan from the live snapshot or plan-writing tool rows.
List<PlanStep>? derivePlanSteps({
  required List<Map<String, dynamic>> rows,
  Object? snapshotPlan,
}) {
  final candidates = <Object?>[
    snapshotPlan,
    for (final row in rows.reversed)
      if (_isPlanTool(row)) ...[
        row['input'],
        row['inputText'],
        row['arguments'],
        row['output'],
      ],
  ];
  for (final candidate in candidates) {
    final parsed = _parsePlanValue(candidate);
    if (parsed != null && parsed.isNotEmpty) return parsed;
  }
  return null;
}

bool _isPlanTool(Map<String, dynamic> row) {
  final name = '${row['toolName'] ?? row['name'] ?? ''}'.toLowerCase();
  return name.contains('todowrite') ||
      name.contains('todo_write') ||
      name.contains('update_plan') ||
      name.contains('update-plan');
}

List<PlanStep>? _parsePlanValue(Object? value) {
  Object? decoded = value;
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } catch (_) {
      return null;
    }
  }
  if (decoded is Map) {
    for (final key in const ['todos', 'plan', 'plans', 'steps', 'items']) {
      final result = _parsePlanValue(decoded[key]);
      if (result != null) return result;
    }
    return null;
  }
  if (decoded is! List) return null;
  for (final item in decoded.reversed) {
    if (item is Map) {
      for (final key in const ['todos', 'plan', 'steps', 'items']) {
        final nested = _parsePlanValue(item[key]);
        if (nested != null) return nested;
      }
    }
  }
  final steps = <PlanStep>[];
  for (final item in decoded) {
    if (item is String && item.trim().isNotEmpty) {
      steps.add(PlanStep(content: item.trim()));
    } else if (item is Map) {
      final content =
          '${item['content'] ?? item['step'] ?? item['title'] ?? item['text'] ?? item['activeForm'] ?? item['label'] ?? ''}'
              .trim();
      if (content.isEmpty) continue;
      final status =
          '${item['status'] ?? (item['completed'] == true || item['done'] == true ? 'completed' : 'pending')}';
      steps.add(PlanStep(content: content, status: status));
    }
  }
  return steps.isEmpty ? null : steps;
}

/// Context-window usage of one session, parsed from the conversation
/// snapshot's `usage.contextWindow`:
/// `{usedTokens, maxTokens, cache?: {hitRate}, breakdown?: [{source, chars}]}`.
class ContextWindowInfo {
  final int usedTokens;
  final int maxTokens;

  /// Average cache hit rate (0..1), when the desktop reports it.
  final double? cacheHitRate;

  /// Per-source context composition in characters, official sources:
  /// messages / system_prompt / tool_prompt / system_tool_schemas /
  /// mcp_tool_schemas / skills / meta_user_context.
  final List<({String source, int chars})> breakdown;

  const ContextWindowInfo({
    required this.usedTokens,
    required this.maxTokens,
    this.cacheHitRate,
    this.breakdown = const [],
  });

  double get ratio =>
      maxTokens > 0 ? (usedTokens / maxTokens).clamp(0.0, 1.0) : 0.0;
}

/// Official breakdown source → label (chat.contextUsage.breakdown.*).
const _contextSourceLabels = {
  'messages': '消息',
  'system_prompt': '系统提示词',
  'tool_prompt': '工具提示词',
  'system_tool_schemas': '系统工具',
  'mcp_tool_schemas': 'MCP 工具',
  'skills': '技能',
  'meta_user_context': '其他',
};

/// Official tie-break order when two sources have equal chars.
const _contextSourceOrder = {
  'messages': 0,
  'system_prompt': 1,
  'meta_user_context': 2,
  'skills': 3,
  'tool_prompt': 4,
  'system_tool_schemas': 5,
  'mcp_tool_schemas': 6,
};

/// Lenient parse: desktops without cache/breakdown fields still yield the
/// basic used/max ring; unknown shapes yield null (ring hidden).
ContextWindowInfo? parseContextWindowInfo(Object? usage) {
  if (usage is! Map) return null;
  final window = usage['contextWindow'];
  if (window is! Map) return null;
  final used = (window['usedTokens'] as num?)?.toInt();
  final max = (window['maxTokens'] as num?)?.toInt();
  if (used == null || max == null || max <= 0) return null;
  double? hitRate;
  final cache = window['cache'];
  if (cache is Map && cache['hitRate'] is num) {
    hitRate = (cache['hitRate'] as num).toDouble().clamp(0.0, 1.0);
  }
  final bySource = <String, int>{};
  final breakdown = window['breakdown'];
  if (breakdown is List) {
    for (final entry in breakdown) {
      if (entry is! Map) continue;
      final source = '${entry['source'] ?? ''}';
      final chars = (entry['chars'] as num?)?.toInt() ?? 0;
      if (source.isEmpty || chars <= 0) continue;
      bySource[source] = (bySource[source] ?? 0) + chars;
    }
  }
  final rows = bySource.entries
      .map((e) => (source: e.key, chars: e.value))
      .toList()
    ..sort((a, b) {
      final byChars = b.chars.compareTo(a.chars);
      if (byChars != 0) return byChars;
      return (_contextSourceOrder[a.source] ?? 99)
          .compareTo(_contextSourceOrder[b.source] ?? 99);
    });
  return ContextWindowInfo(
    usedTokens: used,
    maxTokens: max,
    cacheHitRate: hitRate,
    breakdown: rows,
  );
}

/// zh-style compact token count (official uses Intl compact notation):
/// 1.2万 / 3亿 / 980.
String formatCompactTokens(int v) {
  if (v >= 100000000) {
    final y = v / 100000000;
    return '${y % 1 == 0 ? y.toStringAsFixed(0) : y.toStringAsFixed(1)}亿';
  }
  if (v >= 10000) {
    final w = v / 10000;
    return '${w % 1 == 0 ? w.toStringAsFixed(0) : w.toStringAsFixed(1)}万';
  }
  return '$v';
}

/// Official percent formatting: no decimals once >=10%, one decimal below.
String formatUsagePercent(double ratio) {
  final p = (ratio * 100).clamp(0.0, 100.0);
  return p >= 10 ? '${p.toStringAsFixed(0)}%' : '${p.toStringAsFixed(1)}%';
}

/// Chat view for one task (session), backed by Conversation V4 subscription.
/// Draft mode (no [sessionId]): the first message issues `createSession`.
class ChatPage extends StatefulWidget {
  final BridgeSession session;
  final Map<String, dynamic> scope;
  final String workspaceKey;
  final String? sessionId;
  final String title;

  /// Auxiliary (side) chats reuse the parent session's usage figures in
  /// their snapshot, so the context bar would show the main session's
  /// percentage — hide it there.
  final bool isSideChat;

  /// Notified once a draft session materializes via `createSession` — the
  /// tablet master-detail host uses it to bind the detail pane to the real
  /// session and refresh the list.
  final ValueChanged<String>? onSessionCreated;

  /// Embedded hosts (tablet detail pane) set false so the AppBar doesn't
  /// imply a back arrow that would pop the host shell.
  final bool automaticallyImplyLeading;

  /// Pretty workspace name for the draft (empty) state description.
  final String? workspaceName;

  const ChatPage({
    super.key,
    required this.session,
    required this.scope,
    required this.workspaceKey,
    this.sessionId,
    required this.title,
    this.isSideChat = false,
    this.onSessionCreated,
    this.automaticallyImplyLeading = true,
    this.workspaceName,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _PendingFile {
  final String fileName;
  final String mime;
  final Uint8List bytes;

  _PendingFile(this.fileName, this.mime, this.bytes);
}

/// Official-web naming/presentation for the four collaboration modes
/// (scraped from the desktop web remote control composer).
const _modePresentation = <String, (IconData, String, String)>{
  'default': (Icons.tune, '默认模式', '使用默认确认策略。'),
  'build': (Icons.back_hand, '变更前确认', '改文件前先问我。'),
  'edit': (Icons.edit_note, '自动编辑', '自动编辑文件。'),
  'plan': (Icons.checklist, '计划模式', '编辑前先出计划。'),
  'yolo': (Icons.gpp_maybe, '完全访问', '减少确认次数。'),
};

String _modeTitleOf(String value, String fallbackName) {
  final hit = _modePresentation[value.trim().toLowerCase()];
  return hit?.$2 ?? (fallbackName.isNotEmpty ? fallbackName : value);
}

String? _modeSubtitleOf(String value, String? desktopDescription) {
  // 官方模式菜单无英文描述：丢弃桌面下发的英文 description，
  // 只保留本地中文文案。
  return _modePresentation[value.trim().toLowerCase()]?.$3;
}

IconData? _modeIconOf(String value) =>
    _modePresentation[value.trim().toLowerCase()]?.$1;

String _thoughtTitleOf(String value, String fallbackName) {
  switch (value.trim().toLowerCase()) {
    case 'low':
      return '低';
    case 'high':
      return '高';
    case 'max':
      return '最高';
    case 'enabled':
      return '开启';
    case 'off':
      return '关闭';
    default:
      return fallbackName.isNotEmpty ? fallbackName : value;
  }
}

/// Full Access ink: deep orange on light theme, light orange on dark
/// (official web: #E07B00 light / #FF8A30 dark).
Color _fullAccessInkFor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.light
        ? ZColors.fullAccessDeep
        : ZColors.fullAccess;

/// Composer container-query breakpoints (official Tailwind v4 tiers, in
/// logical px): below @sm everything is icon-only; the thought chip shows
/// its green level bar between @sm and @xl; text labels return at @xl.
const double _composerSm = 384;
const double _composerXl = 576;
const double _composer2xl = 672;

/// Official thought-level intensity rank (`HZe`): off-family 0 → max 6.
/// Unknown values sort last (99).
int thoughtLevelRank(String raw) {
  final v = raw.trim().toLowerCase();
  const ranks = {
    'disabled': 0,
    'false': 0,
    'no': 0,
    'none': 0,
    'nothink': 0,
    'no-think': 0,
    'no_think': 0,
    'off': 0,
    'low': 1,
    'light': 1,
    'minimal': 1,
    'shallow': 1,
    'balanced': 2,
    'default': 2,
    'medium': 2,
    'normal': 2,
    'standard': 2,
    'deep': 3,
    'high': 3,
    'enable': 4,
    'enabled': 4,
    'on': 4,
    'true': 4,
    'extra-high': 5,
    'extra_high': 5,
    'very-high': 5,
    'very_high': 5,
    'xhigh': 5,
    'max': 6,
    'maximum': 6,
  };
  return ranks[v] ?? 99;
}

/// Fill fraction (0..1) of the official thought-level vertical bar: the
/// current level's position among the ENABLED options, after sorting by
/// rank (off options contribute zero). Mirrors the official `F` formula.
double thoughtBarFill(List<String> optionValues, String current) {
  if (optionValues.isEmpty) return 0;
  final ranked = [...optionValues]
    ..sort((a, b) => thoughtLevelRank(a).compareTo(thoughtLevelRank(b)));
  final idx = ranked.indexOf(current);
  if (idx < 0) return 0;
  final offCount = ranked.where((e) => thoughtLevelRank(e) == 0).length;
  final enabled = (ranked.length - offCount).clamp(1, ranked.length);
  final filled = (idx + 1 - offCount) / enabled;
  return filled.clamp(0.0, 1.0);
}

/// 官方 turnHeader 时长解析（bundle BX 函数）：activeMs 优先，其次
/// endedAt-startedAt，运行中用 nowMs-startedAt。
int? turnDurationMs(Map<String, dynamic> row, {required bool running}) {
  final active = (row['activeMs'] as num?)?.toInt();
  if (active != null) return active;
  final startedAt = (row['startedAt'] as num?)?.toInt();
  final endedAt = (row['endedAt'] as num?)?.toInt();
  if (startedAt != null && endedAt != null) {
    return (endedAt - startedAt).clamp(0, 1 << 40);
  }
  if (running && startedAt != null) {
    return (DateTime.now().millisecondsSinceEpoch - startedAt)
        .clamp(0, 1 << 40);
  }
  return null;
}

/// 顶部会话状态中文标签（协议 phase 枚举 → 中文，与任务列表文案一致）。
String phaseLabel(String phase) => switch (phase) {
  'running' || 'prewarming' => '运行中',
  'completed' || 'completedSuccess' => '已完成',
  'completedInterrupted' || 'cancelled' => '已停止',
  'failed' || 'error' => '失败',
  _ => phase,
};

/// Official turn work-status label (chat.history.*): running = 工作中
/// {duration}, interrupted/failed = 已停止, completed = 已工作 {duration}
/// (or 已处理 when no duration was reported).
String turnWorkLabel({required String state, int? durationMs}) {
  switch (state) {
    case 'running':
    case 'inputStreaming':
      return durationMs == null || durationMs <= 0
          ? '工作中'
          : '工作中 ${formatTurnDuration(durationMs)}';
    case 'completedInterrupted':
    case 'cancelled':
    case 'interrupted':
    case 'failed':
    case 'error':
      return '已停止';
    default:
      return durationMs == null || durationMs <= 0
          ? '已处理'
          : '已工作 ${formatTurnDuration(durationMs)}';
  }
}

/// zh compact duration (chat.history.duration.*): 秒/分/时/天, zero-value
/// trailing units dropped, everything-zero collapses to 0秒.
String formatTurnDuration(int ms) {
  if (ms < 0) ms = 0;
  final duration = Duration(milliseconds: ms);
  final days = duration.inDays;
  final hours = duration.inHours % 24;
  final minutes = duration.inMinutes % 60;
  final seconds = duration.inSeconds % 60;
  final parts = <String>[
    if (days > 0) '$days天',
    if (hours > 0) '$hours时',
    if (minutes > 0) '$minutes分',
    if (seconds > 0) '$seconds秒',
  ];
  return parts.isEmpty ? '0秒' : parts.join();
}

/// Official default-open rule for a turn's collapsible history:
/// the latest turn stays open while running; a lone turn with no assistant
/// text yet stays open; everything else defaults to collapsed.
/// 折叠时保留的内容（官方语义）：收起的只是前置的思考/工具执行流程，
/// 最后的总结正文不收起。
bool turnKeepsFinalText({required bool expanded}) => !expanded;

bool turnDefaultOpen({
  required bool isLastTurn,
  required bool running,
  required bool isOnlyTurn,
  required bool hasAssistantText,
}) {
  return (isLastTurn && running) || (isOnlyTurn && !hasAssistantText);
}

/// Time-of-day greeting for the draft (empty) chat, official chat.empty
/// greeting copy.
String emptyGreeting(DateTime now) {
  final h = now.hour;
  if (h >= 5 && h < 8) return '早上好呀，新的一天开始啦';
  if (h >= 8 && h < 11) return '上午好呀，有什么想让我帮忙的吗';
  if (h >= 11 && h < 13) return '中午好呀，要不要先休息一下';
  if (h >= 13 && h < 18) return '下午好呀，接下来交给我吧';
  if (h >= 18 && h < 23) return '晚上好呀，今天辛苦啦';
  return '夜深啦，别忘了照顾好自己哦';
}

/// Composer drafts survive leaving the chat page: keyed by session id, or
/// by workspace for not-yet-created sessions. Cleared implicitly when the
/// message is sent (the controller is cleared, which saves the empty text).
final Map<String, String> _composerDrafts = {};

/// Removes only the number of confirmed echoes matching each user message.
/// Failed echoes remain visible so the user can retry them.
List<Map<String, dynamic>> removeEchoedTexts(
    List<Map<String, dynamic>> echoes, List<Map<String, dynamic>> rows) {
  final confirmed = <String, int>{};
  for (final row in rows) {
    if (row['kind'] != 'userInput') continue;
    final text = '${row['text'] ?? ''}'.trim();
    confirmed[text] = (confirmed[text] ?? 0) + 1;
  }
  final remaining = <String, int>{...confirmed};
  return echoes.where((echo) {
    if (echo['status'] == 'failed') return true;
    final text = '${echo['text'] ?? ''}'.trim();
    final count = remaining[text] ?? 0;
    if (count == 0) return true;
    remaining[text] = count - 1;
    return false;
  }).toList();
}

class _ChatPageState extends State<ChatPage> {
  late final ConversationTransport _transport;
  ConversationSubscription? _subscription;
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  String? _sessionId;
  String? _error;
  bool _sending = false;
  final List<Map<String, dynamic>> _echoes = [];

  /// Turn collapse state (official model): user override per turn, plus the
  /// previously seen default so a running→completed flip clears the
  /// override and the turn auto-collapses.
  final Map<String, bool> _turnExpandedOverrides = {};
  final Map<String, bool> _turnPrevDefault = {};

  void _dedupeEchoes() {
    final state = _state;
    if (state == null || _echoes.isEmpty) return;
    final kept = removeEchoedTexts(_echoes, state.rows);
    if (kept.length != _echoes.length && mounted) {
      setState(() {
        _echoes
          ..clear()
          ..addAll(kept);
      });
    }
  }

  bool _loadingOlder = false;
  bool _showSlash = false;

  /// Composer mention state (`@` files / `#` sessions). The trigger token is
  /// the word ending at the cursor: `@query` / `#query` after line start or
  /// whitespace (official rule `(^|\s)[/@$#]`). Null trigger = menu closed.
  String? _mentionTrigger;
  String _mentionQuery = '';
  List<MentionItem>? _mentionFiles;
  bool _mentionFilesFailed = false;
  List<MentionItem>? _mentionSessions;
  SessionsIndexSubscription? _mentionSessionsSub;
  String? _progress;
  final List<_PendingFile> _pendingFiles = [];
  double? _uploadProgress;
  WorkspacePrep? _prep;
  List<SkillEntry> _skills = [];
  bool _skillsLoading = false;
  Object? _planData;
  bool _planLoading = false;
  int _planRevision = -1;
  final _voiceStore = VoiceModelStore();
  VoiceTranscriber? _voiceTranscriber;
  bool _voiceAvailable = false;
  bool _voiceRecording = false;
  bool _voiceWorking = false;
  String _voiceDraftPrefix = '';

  /// Cache key for the composer draft of THIS chat view.
  String get _draftKey => _sessionId ?? 'draft:${widget.workspaceKey}';

  /// Draft-mode (no session yet) model/mode/thought selection, passed as
  /// `config` to createSession on first send.
  final Map<String, String> _draftConfig = {};

  /// Whether to keep the view pinned to the newest message. Starts true so
  /// opening the chat lands at the bottom; the user scrolling up unpins it.
  bool _stickToBottom = true;

  ConversationState? get _state => _subscription?.state;

  @override
  void initState() {
    super.initState();
    VoiceModelEvents.changed.addListener(_loadVoiceAvailability);
    _sessionId = widget.sessionId;
    _transport = widget.session.conversation(widget.scope);
    _scrollController.addListener(_onScroll);
    if (_sessionId != null) {
      _subscribe();
    }
    _loadPrep();
    _loadVoiceAvailability();
    _inputController.text = _composerDrafts[_draftKey] ?? '';
    _inputController.addListener(() {
      final text = _inputController.text;
      _composerDrafts[_draftKey] = text;
      final show = (text.startsWith('/') || text.startsWith('\$')) &&
          !text.contains(' ');
      if (show != _showSlash && mounted) {
        setState(() => _showSlash = show);
      }
      _updateMentionState(text);
    });
  }

  /// Recomputes the mention trigger from the text ending at the cursor.
  /// `@`/`#` must follow line start or whitespace (official rule), and the
  /// query carries no whitespace of its own. Fires only on state change.
  void _updateMentionState(String text) {
    String? trigger;
    var query = '';
    final sel = _inputController.selection;
    if (sel.isValid &&
        sel.baseOffset >= 0 &&
        sel.baseOffset <= text.length) {
      final before = text.substring(0, sel.baseOffset);
      final m = RegExp(r'(?:^|\s)([@#])([^\s@#]*)$').firstMatch(before);
      if (m != null) {
        trigger = m.group(1);
        query = m.group(2) ?? '';
      }
    }
    if (trigger == _mentionTrigger && query == _mentionQuery) return;
    if (mounted) {
      setState(() {
        _mentionTrigger = trigger;
        _mentionQuery = query;
      });
    }
    if (trigger != null) _ensureMentionData(trigger);
  }

  /// Lazily loads the mention data sources. Sources degrade independently:
  /// a failed directory listing only hides the files section, never the
  /// sessions or skills sections (double-source independence, lesson #4).
  void _ensureMentionData(String trigger) {
    if (trigger == '@' && _mentionFiles == null && !_mentionFilesFailed) {
      _loadMentionFiles();
    }
    if (_mentionSessions == null) _loadMentionSessions();
  }

  Future<void> _loadMentionFiles() async {
    try {
      final root = _transport.scope['workspacePath'];
      if (root is! String || root.isEmpty) throw StateError('no workspacePath');
      final entries = await _transport.readdir(root, includeHidden: false);
      if (!mounted) return;
      final items = <MentionItem>[];
      for (final e in entries) {
        final name = '${e['name'] ?? e['fileName'] ?? e['path'] ?? ''}';
        if (name.isEmpty || name == '.' || name == '..') continue;
        final isDir = e['isDirectory'] == true ||
            e['isDir'] == true ||
            e['type'] == 'directory';
        // 相对 workspace 根的路径注入（官方格式 `./name`），避免泄露
        // 桌面端绝对路径。
        items.add(MentionItem(
          category: MentionCategory.files,
          title: name,
          subtitle: isDir ? '目录' : '文件',
          isDirectory: isDir,
          insertMarkdown: fileMentionMarkdown(name, name, directory: isDir),
        ));
      }
      setState(() => _mentionFiles = items);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _mentionFilesFailed = true;
        _mentionFiles = const [];
      });
    }
  }

  Future<void> _loadMentionSessions() async {
    try {
      final sub = await _transport.subscribeSessionsIndex();
      if (!mounted) {
        await sub.dispose();
        return;
      }
      _mentionSessionsSub = sub;
      void pull() {
        final sessions = sub.state.sessions.values.toList()
          ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
        final items = [
          for (final s in sessions.take(30))
            if (s.sessionId.isNotEmpty && s.sessionId != _sessionId)
              MentionItem(
                category: MentionCategory.sessions,
                title: s.title.isEmpty ? '未命名会话' : s.title,
                subtitle: s.lastAssistantPreview ?? '',
                insertMarkdown:
                    sessionMentionMarkdown(s.sessionId, s.title),
              ),
        ];
        if (mounted) setState(() => _mentionSessions = items);
      }

      sub.state.addListener(pull);
      pull();
    } catch (_) {
      if (mounted) setState(() => _mentionSessions = const []);
    }
  }

  /// Replaces the trigger token (from its start to the cursor) with the
  /// selected mention markdown plus a trailing space, cursor at the end.
  void _insertMention(MentionItem item) {
    final text = _inputController.text;
    final sel = _inputController.selection;
    var start = sel.baseOffset;
    if (start < 0 || start > text.length) start = text.length;
    final before = text.substring(0, start);
    final m = RegExp(r'(?:^|\s)([@#])([^\s@#]*)$').firstMatch(before);
    final tokenStart = m?.start ?? start - 1 - _mentionQuery.length;
    final merged = text.replaceRange(
        tokenStart < 0 ? 0 : tokenStart, start, '${item.insertMarkdown} ');
    _inputController.text = merged;
    _inputController.selection = TextSelection.collapsed(
        offset: tokenStart + item.insertMarkdown.length + 1);
    setState(() {
      _mentionTrigger = null;
      _mentionQuery = '';
    });
  }

  /// Follow/unpin decisions are made ONLY while the scroll is user-driven
  /// (drag or fling). `userScrollDirection` is idle during the programmatic
  /// follow animation, so streaming output cannot flip the flag — the view
  /// stays put while the user reads older messages.
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.userScrollDirection == ScrollDirection.idle) return;
    final max = pos.maxScrollExtent;
    _stickToBottom = pos.pixels >= max - 40;
  }

  Future<void> _loadPrep() async {
    try {
      final prep = await _transport.prepareWorkspace();
      if (mounted) setState(() => _prep = prep);
    } catch (_) {}
    setState(() => _skillsLoading = true);
    try {
      final skills = await _transport.skills();
      if (mounted) setState(() => _skills = skills);
    } catch (_) {
      if (mounted) setState(() => _skills = const []);
    } finally {
      if (mounted) setState(() => _skillsLoading = false);
    }
  }

  @override
  void dispose() {
    _subscription?.dispose();
    _mentionSessionsSub?.dispose();
    VoiceModelEvents.changed.removeListener(_loadVoiceAvailability);
    _voiceTranscriber?.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadVoiceAvailability() async {
    try {
      final id = await _voiceStore.enabledModelId();
      if (!mounted) return;
      setState(() {
        _voiceAvailable = id != null;
        if (id != null) {
          _voiceTranscriber = VoiceTranscriber(store: _voiceStore);
        }
      });
    } catch (_) {}
  }

  Future<void> _toggleVoiceInput() async {
    final transcriber = _voiceTranscriber;
    if (transcriber == null || _sending || _voiceWorking) return;
    if (_voiceRecording) {
      setState(() {
        _voiceRecording = false;
        _voiceWorking = true;
      });
      try {
        final text = await transcriber.stop();
        if (mounted && text.isNotEmpty) {
          _inputController.text =
              _voiceDraftPrefix.isEmpty ? text : '$_voiceDraftPrefix $text';
          _inputController.selection =
              TextSelection.collapsed(offset: _inputController.text.length);
        }
      } catch (e) {
        if (mounted) _toast('语音识别失败: $e');
      } finally {
        if (mounted) setState(() => _voiceWorking = false);
      }
      return;
    }
    try {
      _voiceDraftPrefix = _inputController.text.trim();
      if (mounted) setState(() => _voiceRecording = true);
      await transcriber.start(onPartial: (text) {
        if (!mounted || !_voiceRecording) return;
        _inputController.text =
            _voiceDraftPrefix.isEmpty ? text : '$_voiceDraftPrefix $text';
        _inputController.selection =
            TextSelection.collapsed(offset: _inputController.text.length);
      });
    } catch (e) {
      _voiceDraftPrefix = '';
      if (mounted) setState(() => _voiceRecording = false);
      if (mounted) _toast('无法开始录音: $e');
    }
  }

  Future<void> _subscribe() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final sub = await _transport
          .subscribe(sessionId)
          .timeout(const Duration(seconds: 60));
      if (!mounted) {
        await sub.dispose();
        return;
      }
      setState(() {
        _subscription = sub;
        _error = null;
      });
      sub.state.addListener(_scrollToBottom);
      sub.state.addListener(_dedupeEchoes);
      sub.state.addListener(_refreshPlanIfNeeded);
      // The server snapshot is a tail window (can be as few as 3 rows).
      // The official client shows the full history immediately, so
      // auto-load the missing older rows once on open.
      if (sub.state.canLoadOlder) {
        await _loadOlder();
      }
      _refreshPlanIfNeeded();
      // Initial snapshots and auto-loaded history can change the list height
      // over multiple frames. Force the first open to the newest message;
      // later streaming updates still use the conditional follow behavior.
      _jumpToLatest();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      // Follow ONLY while the user is pinned to the bottom. There is no
      // "near bottom" heuristic: during streaming maxScrollExtent grows, so
      // a distance-based check keeps dragging the reader down. Once the
      // user scrolls up, the view stays put until they return to the
      // bottom themselves.
      if (_stickToBottom) {
        _scrollController.animateTo(
          max,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _jumpToLatest() {
    _stickToBottom = true;
    void jump() {
      if (!mounted || !_stickToBottom || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      jump();
      WidgetsBinding.instance.addPostFrameCallback((_) => jump());
    });
    Future<void>.delayed(const Duration(milliseconds: 100), jump);
    Future<void>.delayed(const Duration(milliseconds: 300), jump);
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _run(String errorPrefix, Future<dynamic> Function() run) async {
    try {
      final res = await run();
      if (res is Map &&
          res['status'] != null &&
          res['status'] != 'accepted' &&
          res['status'] != 'noop') {
        _toast('$errorPrefix: ${res['reasonCode'] ?? res['status']}');
      }
    } catch (e) {
      _toast('$errorPrefix: $e');
    }
  }

  /// Opens an auxiliary (side) chat attached to the current session
  /// (`createSelectionSideSession`). On wide screens (tablet / unfolded
  /// foldable) it slides in as a right-side panel so the main chat stays
  /// visible; narrow screens push a full ChatPage as before.
  Future<void> _openSideChat() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final sideId = await _transport.createSelectionSideSession(sessionId);
      if (!mounted) return;
      final width = MediaQuery.sizeOf(context).width;
      if (width >= 640) {
        await _showSideChatPanel(sideId);
      } else {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatPage(
              session: widget.session,
              scope: widget.scope,
              workspaceKey: widget.workspaceKey,
              sessionId: sideId,
              title: '辅助对话',
              isSideChat: true,
            ),
          ),
        );
      }
    } catch (e) {
      _toast('打开辅助对话失败: $e');
    }
  }

  /// Right-anchored side panel hosting the auxiliary ChatPage. Tapping the
  /// scrim or the header close button dismisses it.
  Future<void> _showSideChatPanel(String sideId) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭辅助对话',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final width = MediaQuery.sizeOf(dialogContext).width;
        final panelWidth = (width * 0.55).clamp(360.0, 560.0);
        return Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Theme.of(dialogContext).scaffoldBackgroundColor,
            elevation: 16,
            child: SizedBox(
              width: panelWidth,
              child: SafeArea(
                child: Column(
                  children: [
                    Container(
                      height: 52,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: ZInk.hairline(dialogContext)),
                        ),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('辅助对话',
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: ZInk.solid(dialogContext))),
                          ),
                          IconButton(
                            tooltip: '关闭',
                            icon: Icon(Icons.close,
                                size: 20, color: ZInk.muted(dialogContext)),
                            onPressed: () => Navigator.pop(dialogContext),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ChatPage(
                        session: widget.session,
                        scope: widget.scope,
                        workspaceKey: widget.workspaceKey,
                        sessionId: sideId,
                        title: '辅助对话',
                        isSideChat: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final slide = Tween(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
        return SlideTransition(position: slide, child: child);
      },
    );
  }

  // ------------------------------------------------------------ sending

  String _guessMime(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'svg' => 'image/svg+xml',
      'pdf' => 'application/pdf',
      'txt' || 'md' || 'log' => 'text/plain',
      'json' => 'application/json',
      'zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }

  Future<void> _pickFiles() async {
    try {
      final result =
          await FilePicker.pickFiles(withData: true, allowMultiple: true);
      if (result == null) return;
      setState(() {
        for (final file in result.files) {
          final bytes = file.bytes;
          if (bytes == null) continue;
          _pendingFiles
              .add(_PendingFile(file.name, _guessMime(file.name), bytes));
        }
      });
    } catch (e) {
      _toast('选择文件失败: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _uploadFiles(
      List<_PendingFile> files, String sessionId) async {
    final uploaded = <Map<String, dynamic>>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      uploaded.add(await _transport.attachmentPut(
        sessionId,
        fileName: file.fileName,
        mime: file.mime,
        bytes: file.bytes,
        onProgress: (progress) {
          if (mounted) {
            setState(() => _uploadProgress = (i + progress) / files.length);
          }
        },
      ));
    }
    return uploaded;
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if ((text.isEmpty && _pendingFiles.isEmpty) || _sending) return;

    // Slash commands (mirrors the web composer).
    if (text == '/compact' || text.startsWith('/compact ')) {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run('压缩失败', () => _transport.compact(_requireSession()));
      return;
    }
    if (text == '/goal pause') {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run('暂停目标失败', () => _transport.pauseGoal(_requireSession()));
      return;
    }
    if (text == '/goal resume') {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run('恢复目标失败', () => _transport.resumeGoal(_requireSession()));
      return;
    }

    // held-queue confirmation: when inputRouting is `choice` the user
    // picks whether to clear the held queue or keep it.
    String? heldDisposition;
    final state = _state;
    if (state != null &&
        state.inputRoutingMode == 'choice' &&
        state.queueItems.isNotEmpty) {
      heldDisposition = await _askHeldQueueDisposition();
      if (heldDisposition == null) return; // cancelled
    }

    final echo = <String, dynamic>{
      'text': text,
      'isGoal': text.startsWith('/goal '),
      'status': 'sending',
      'ts': DateTime.now().millisecondsSinceEpoch,
      'files': List<_PendingFile>.from(_pendingFiles),
      'attachments': null,
    };
    setState(() {
      _echoes.add(echo);
      _sending = true;
      _uploadProgress = null;
      _showSlash = false;
      _progress = null;
    });
    try {
      var sessionId = _sessionId;
      if (sessionId == null) {
        // 1) create the session (can take a while when the runtime warms)
        setState(() => _progress = '正在创建会话（首次可能需要预热）…');
        final sw = Stopwatch()..start();
        // Plain text first message is sent WITH createSession (firstInput,
        // mirrors the official composer). This avoids a send-before-subscribe
        // race where the first command can be dropped on a fresh session.
        final echoFiles = echo['files'] as List<_PendingFile>;
        final canUseFirstInput = text.isNotEmpty &&
            echoFiles.isEmpty &&
            !text.startsWith('/goal ') &&
            heldDisposition == null;
        try {
          sessionId = await _transport.createSession(
            widget.workspaceKey,
            firstText: canUseFirstInput ? text : null,
            config: _buildDraftConfig(),
            timeout: const Duration(seconds: 90),
          );
          if (!mounted) return;
        } catch (e) {
          log('[chat] createSession failed after '
              '${sw.elapsedMilliseconds}ms: $e');
          rethrow;
        }
        log('[chat] createSession ok in ${sw.elapsedMilliseconds}ms');
        _sessionId = sessionId;
        widget.onSessionCreated?.call(sessionId);
        // The draft was consumed by the first send; drop it so backing out
        // and starting another new session doesn't resurface the sent text.
        _composerDrafts.remove('draft:${widget.workspaceKey}');
        // 2) subscribe in the background — must NOT block sending
        setState(() => _progress = null);
        if (canUseFirstInput) {
          // Message already sent with the session; just display history.
          echo['status'] = 'sent';
          _inputController.clear();
          setState(() => _pendingFiles.clear());
          _subscribe();
          return;
        }
        // Attachments / goal commands: the follow-up command needs an active
        // subscription, so wait for it before proceeding.
        await _subscribe();
      }
      if (text.startsWith('/goal ')) {
        final res = await _transport.sendGoalCommand(
          sessionId,
          text.substring('/goal '.length).trim(),
          heldQueueDisposition: heldDisposition,
        );
        if (_ackRejected(res)) {
          echo['status'] = 'failed';
          echo['error'] = _ackReason(res);
          _toast('发送失败: ${_ackReason(res)}');
          return;
        }
        echo['status'] = 'sent';
        _inputController.clear();
        return;
      }
      List<Map<String, dynamic>>? attachments;
      final echoFiles = echo['files'] as List<_PendingFile>;
      if (echoFiles.isNotEmpty) {
        setState(() => _progress = '正在上传附件…');
        attachments = await _uploadFiles(echoFiles, sessionId);
        echo['attachments'] = attachments;
        setState(() => _progress = null);
      }
      final res = await _transport.sendText(
        sessionId,
        text,
        attachments: attachments,
        heldQueueDisposition: heldDisposition,
      );
      if (_ackRejected(res)) {
        echo['status'] = 'failed';
        echo['error'] = _ackReason(res);
        _toast('发送失败: ${_ackReason(res)}');
        return;
      }
      echo['status'] = 'sent';
      _inputController.clear();
      setState(() => _pendingFiles.clear());
    } catch (e) {
      echo['status'] = 'failed';
      echo['error'] = '$e';
      _toast('发送失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _uploadProgress = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _retryEcho(Map<String, dynamic> echo) async {
    if (_sending) return;
    setState(() {
      echo['status'] = 'sending';
      echo['error'] = null;
      _sending = true;
    });
    try {
      final sessionId = _sessionId;
      if (sessionId == null) throw StateError('尚无会话');
      final files =
          (echo['files'] as List?)?.whereType<_PendingFile>().toList() ??
              const <_PendingFile>[];
      List<Map<String, dynamic>>? attachments = (echo['attachments'] as List?)
          ?.whereType<Map>()
          .map(
            (item) => item.cast<String, dynamic>(),
          )
          .toList();
      if (files.isNotEmpty && attachments == null) {
        attachments = await _uploadFiles(files, sessionId);
        echo['attachments'] = attachments;
      }
      final text = '${echo['text'] ?? ''}';
      final res = echo['isGoal'] == true
          ? await _transport.sendGoalCommand(
              sessionId,
              text.substring('/goal '.length).trim(),
            )
          : await _transport.sendText(
              sessionId,
              text,
              attachments: attachments,
            );
      if (_ackRejected(res)) {
        throw StateError(_ackReason(res));
      }
      if (mounted) setState(() => echo['status'] = 'sent');
    } catch (e) {
      if (mounted) {
        setState(() {
          echo['status'] = 'failed';
          echo['error'] = '$e';
        });
        _toast('重试失败: $e');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  bool _ackRejected(dynamic res) =>
      res is Map &&
      res['status'] != null &&
      res['status'] != 'accepted' &&
      res['status'] != 'noop' &&
      res['status'] != 'duplicate';

  String _ackReason(dynamic res) {
    if (res is! Map) return '$res';
    return '${res['reasonCode'] ?? res['message'] ?? res['status']}';
  }

  String _requireSession() {
    final sessionId = _sessionId;
    if (sessionId == null) throw StateError('尚无会话');
    return sessionId;
  }

  /// Builds the createSession `config` payload from the draft selection.
  Map<String, dynamic>? _buildDraftConfig() {
    if (_draftConfig.isEmpty) return null;
    final config = <String, dynamic>{};
    final modelValue = _draftConfig['model'];
    if (modelValue != null && modelValue.isNotEmpty) {
      final idx = modelValue.lastIndexOf('/');
      if (idx > 0) {
        config['provider'] = modelValue.substring(0, idx);
        config['model'] = modelValue.substring(idx + 1);
      }
    }
    if (_draftConfig['thought'] != null) {
      config['thought'] = _draftConfig['thought'];
    }
    if (_draftConfig['mode'] != null) {
      config['mode'] = _draftConfig['mode'];
    }
    return config.isEmpty ? null : config;
  }

  Future<String?> _askHeldQueueDisposition() {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('有排队中的消息'),
        content: const Text('立即发送将清空排队消息并插队执行'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'keepQueueAndSend'),
            child: const Text('排队发送'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'clearQueueAndSend'),
            child: const Text('立即发送'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ history

  Future<void> _loadOlder() async {
    final state = _state;
    final sessionId = _sessionId;
    if (state == null || sessionId == null || _loadingOlder) return;
    setState(() => _loadingOlder = true);
    try {
      // 官方 loadAllOlder 语义：循环按页拉取直到 hasMore=false（官方
      // 会话展示的历史比单页多）。页大小取 50——官方 schema 对 limit 有
      // max 上限（rowsRangeMaxLimit），一次一页循环补齐。
      for (var page = 0; page < 40; page++) {
        final currentState = _state;
        if (currentState == null || !currentState.canLoadOlder) break;
        final res = await _transport.rowsRange(
          sessionId,
          beforeRowId: currentState.oldestRowId,
          limit: 50,
        );
        List? rows;
        int? firstRowId;
        bool? hasMore;
        if (res is Map) {
          final rowsObj = res['rows'];
          if (rowsObj is Map) {
            rows = rowsObj['window'] as List? ?? rowsObj['rows'] as List?;
            firstRowId = (rowsObj['firstRowId'] as num?)?.toInt();
            hasMore = rowsObj['hasMore'] as bool?;
          } else if (rowsObj is List) {
            rows = rowsObj;
          }
          rows ??= res['items'] as List? ?? res['window'] as List?;
          firstRowId ??= (res['firstRowId'] as num?)?.toInt();
          hasMore ??= res['hasMore'] as bool?;
        } else if (res is List) {
          rows = res;
        }
        final older = rows
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList()
          ?..sort((a, b) =>
              ((a['rowId'] as num?) ?? 0).compareTo((b['rowId'] as num?) ?? 0));
        if (older == null || older.isEmpty) {
          if (hasMore == false) currentState.historyExhausted = true;
          break;
        }
        final before = currentState.rows.length;
        currentState.prependOlderRows(older, firstRowId);
        if (hasMore == false) {
          currentState.historyExhausted = true;
          break;
        }
        // 一页没有任何新增（游标不再前进）就停，避免死循环。
        if (currentState.rows.length == before) break;
      }
      if (_stickToBottom) _scrollToBottom();
    } catch (e) {
      _toast('加载失败: $e');
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  // ------------------------------------------------- composer config chips

  bool get _isDraftSession => _sessionId == null || _sessionId!.isEmpty;

  ConfigOption? get _modelOption => _prep?.option('model');
  ConfigOption? get _modeOption => _prep?.option('mode');
  ConfigOption? get _thoughtOption => _prep?.option('thought_level');

  /// Mirrors _ModelModeSheet's resolution: prefer the LIVE session config,
  /// fall back to prepareWorkspace currentValue / draft.
  String get _currentModelValue {
    final config = _state?.config ?? const {};
    final live = '${config['provider'] ?? ''}/${config['model'] ?? ''}';
    return _isDraftSession ||
            config['model'] == null ||
            '${config['model']}'.isEmpty
        ? (_draftConfig['model'] ?? '${_modelOption?.currentValue ?? ''}')
        : live;
  }

  String get _currentModeValue {
    if (_isDraftSession) return _draftConfig['mode'] ?? 'build';
    return _state?.currentMode ?? 'build';
  }

  String get _currentThoughtValue {
    if (_isDraftSession) {
      return _draftConfig['thought'] ?? '${_thoughtOption?.currentValue ?? ''}';
    }
    return _state?.currentThought.isNotEmpty == true
        ? _state!.currentThought
        : '${_thoughtOption?.currentValue ?? ''}';
  }

  String get _currentModelLabel {
    final v = _currentModelValue;
    for (final o in _modelOption?.options ?? const <ConfigOptionValue>[]) {
      if (o.value == v) return o.name;
    }
    final idx = v.lastIndexOf('/');
    if (idx <= 0) return v.isEmpty ? '模型' : v;
    return v.substring(idx + 1);
  }

  /// 官方模型 chip 文字逻辑（PAe + OF 调用点，2026-09-07 解密）：
  /// ≥384px 显示模型名；≥672px 追加 `{供应商名}/` 前缀（`hidden
  /// @2xl/composer:inline`）。内置/一方供应商（builtin、glm）无前缀
  /// （镜像 ja() 判定）。返回 (前缀, 模型名)。
  (String?, String) get _modelPrefixAndLabel {
    final v = _currentModelValue;
    for (final o in _modelOption?.options ?? const <ConfigOptionValue>[]) {
      if (o.value == v) {
        final provider = o.modelProviderName?.trim();
        final seg = v.contains('/')
            ? v.substring(0, v.lastIndexOf('/'))
            : '';
        final firstParty = seg.isEmpty ||
            seg.startsWith('builtin') ||
            seg == 'glm' ||
            provider == null ||
            provider.isEmpty;
        return (firstParty ? null : '$provider/', o.name);
      }
    }
    return (null, _currentModelLabel);
  }

  String get _currentModeLabel {
    final option = _modeOption;
    for (final o in option?.options ?? const <ConfigOptionValue>[]) {
      if (o.value == _currentModeValue) {
        return _modeTitleOf(o.value, o.name);
      }
    }
    return _modeTitleOf(_currentModeValue, '');
  }

  String get _currentThoughtLabel {
    final v = _currentThoughtValue;
    for (final o in _thoughtOption?.options ?? const <ConfigOptionValue>[]) {
      if (o.value == v) return _thoughtTitleOf(o.value, o.name);
    }
    return v.isEmpty ? '思考' : _thoughtTitleOf(v, v);
  }

  /// Reason fragments that mean the CAS baseRevision raced a streamed
  /// state bump — safe to retry once, the re-send picks up the freshest
  /// revision (sendCommand recomputes it per call).
  static const _conflictMarkers = ['conflict', 'stale', 'revision'];

  Future<dynamic> _runConfigCommand(Future<dynamic> Function() run) async {
    final res = await run();
    if (res is Map &&
        res['status'] != null &&
        res['status'] != 'accepted' &&
        res['status'] != 'noop') {
      final reason =
          '${res['reasonCode'] ?? res['status']} ${res['message'] ?? ''}'
              .toLowerCase();
      if (_conflictMarkers.any(reason.contains)) {
        return await run();
      }
    }
    return res;
  }

  /// Shared apply path for the inline composer dropdowns (no sheet to pop).
  /// [successMessage] makes the success explicit — silent switches read as
  /// failed switches.
  Future<bool> _applyConfig(
    Future<dynamic> Function() run, {
    void Function()? onAccepted,
    String? successMessage,
  }) async {
    try {
      final res = await _runConfigCommand(run);
      if (res is Map && res['status'] != null && res['status'] != 'accepted') {
        _toast('被拒绝: ${res['reasonCode'] ?? res['status']}');
        return false;
      }
      onAccepted?.call();
      if (mounted) setState(() {}); // 刷新 chip 标签/竖条（He 反馈：切换后文本不变）
      if (successMessage != null) _toast(successMessage);
      return true;
    } catch (e) {
      _toast('失败: $e');
      return false;
    }
  }

  void _switchMode(String value) {
    if (_isDraftSession) {
      setState(() => _draftConfig['mode'] = value);
      return;
    }
    _applyConfig(
      () => _transport.switchCollaborationMode(_sessionId ?? '', value),
      onAccepted: () => _state?.optimisticPatch({
        'config': {...?_state!.config, 'mode': value},
      }),
      successMessage: '协作模式已切换：${_modeTitleOf(value, value)}',
    );
  }

  void _switchThought(String value) {
    if (_isDraftSession) {
      setState(() => _draftConfig['thought'] = value);
      return;
    }
    final modelValue = _currentModelValue;
    final idx = modelValue.lastIndexOf('/');
    final (provider, model) = idx <= 0
        ? (modelValue, modelValue)
        : (
            modelValue.substring(0, idx),
            modelValue.substring(idx + 1),
          );
    _applyConfig(
      () => _transport.switchModelConfig(
        _sessionId ?? '',
        provider: provider,
        model: model,
        thought: value,
      ),
      onAccepted: () => _state?.optimisticPatch({
        'config': {...?_state!.config, 'thought': value},
      }),
      successMessage: '思考强度已切换：${_thoughtTitleOf(value, value)}',
    );
  }

  void _selectModel(ConfigOptionValue v) {
    if (_isDraftSession) {
      setState(() => _draftConfig['model'] = v.value);
      return;
    }
    final idx = v.value.lastIndexOf('/');
    final (provider, model) = idx <= 0
        ? (v.value, v.value)
        : (v.value.substring(0, idx), v.value.substring(idx + 1));
    // thought must be valid for the target model: keep current if supported,
    // else fall back to the thought option's currentValue.
    final currentThought = _state?.currentThought ?? '';
    final thoughtOpt = _thoughtOption;
    final thought = currentThought.isNotEmpty &&
            (thoughtOpt?.options.any((o) => o.value == currentThought) ??
                false)
        ? currentThought
        : '${thoughtOpt?.currentValue ?? (currentThought.isNotEmpty ? currentThought : 'enabled')}';
    _applyConfig(
      () => _transport.switchModelConfig(
        _sessionId ?? '',
        provider: provider,
        model: model,
        thought: thought,
      ),
      onAccepted: () => _state?.optimisticPatch({
        'config': {
          ...?_state!.config,
          'provider': provider,
          'model': model,
          'thought': thought,
        },
      }),
      successMessage: '模型已切换：${v.name}',
    );
  }

  List<(ComposerMenuEntry, String)> _modeMenuEntries() {
    (ComposerMenuEntry, String) build(String value, String fallbackName,
            String? description) =>
        (
          ComposerMenuEntry(
            icon: _modeIconOf(value) ?? Icons.tune,
            title: _modeTitleOf(value, fallbackName),
            subtitle: _modeSubtitleOf(value, description),
            selected: value == _currentModeValue,
          ),
          value,
        );
    final option = _modeOption;
    if (option != null && option.options.isNotEmpty) {
      return [
        for (final v in option.options) build(v.value, v.name, v.description),
      ];
    }
    return [
      for (final m in const ['build', 'edit', 'plan', 'yolo']) build(m, m, null),
    ];
  }

  List<(ComposerMenuEntry, String)> _thoughtMenuEntries() {
    final option = _thoughtOption;
    if (option != null && option.options.isNotEmpty) {
      return [
        for (final v in option.options)
          (
            ComposerMenuEntry(
              title: _thoughtTitleOf(v.value, v.name),
              selected: v.value == _currentThoughtValue,
            ),
            v.value,
          ),
      ];
    }
    final levels = _state?.thoughtLevels ?? const <String>[];
    return [
      for (final l in levels)
        (
          ComposerMenuEntry(title: _thoughtTitleOf(l, l), selected: l == _currentThoughtValue),
          l,
        ),
    ];
  }

  Widget _buildModeChip(double composerWidth) {
    final isFull = _currentModeValue == 'yolo' ||
        _currentModeValue.toLowerCase() == 'fullaccess';
    // 官方模式 chip（II 组件）：宽度按 composer 容器实测（LayoutBuilder），
    // <@xl(576) 只有 icon，≥@xl 恢复图标+文本。
    final iconOnly = composerWidth < _composerXl;
    return ComposerChip(
      icon: isFull ? Icons.gpp_maybe : Icons.shield_outlined,
      lucideIcon: 'sliders-horizontal',
      label: _currentModeLabel,
      labelColor: isFull ? _fullAccessInkFor(context) : null,
      iconOnly: iconOnly,
      tooltip: '协作模式 · $_currentModeLabel',
      menuBuilder: (context, close) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (e, value) in _modeMenuEntries())
            ComposerMenuRow(
              entry: e,
              onTap: () {
                close();
                _switchMode(value);
              },
            ),
        ],
      ),
    );
  }

  Widget _buildModelChip(double composerWidth) {
    final option = _modelOption;
    final available = option != null && option.options.isNotEmpty;
    // 官方模型 chip（OF 调用点）：<384px = size-7 方形纯图标（package）；
    // ≥384px 图标隐藏、显示模型名+chevron；≥672px 模型名前追加供应商
    // 前缀。tooltip 固定「选择模型」（chat.toolbar.model.label）。
    final (prefix, modelLabel) = _modelPrefixAndLabel;
    return ComposerChip(
      icon: Icons.inventory_2_outlined,
      lucideIcon: 'package',
      label: available || _currentModelLabel.isNotEmpty
          ? modelLabel
          : '模型',
      prefixLabel: composerWidth >= _composer2xl ? prefix : null,
      enabled: available,
      iconOnly: composerWidth < _composerSm,
      showIcon: composerWidth < _composerSm,
      tooltip: '选择模型',
      menuBuilder: (context, close) => ComposerModelMenuBody(
        options: option!.options,
        currentModelValue: _currentModelValue,
        onSelect: (v) {
          close();
          _selectModel(v);
        },
      ),
    );
  }

  Widget _buildThoughtChip(double composerWidth) {
    final entries = _thoughtMenuEntries();
    // 官方思考 chip（VI）：<384px 只有 brain 图标（size-7 方形）；
    // 384–576px 图标+绿色竖条（填充高度=档位进度）；≥576px 图标+文本
    // 标签（竖条隐藏）。tooltip：标签不可见时「思考级别」，可见时为
    // 档位文本（官方 N = labelVisible ? label : tooltip 键）。
    final iconOnly = composerWidth < _composerSm;
    final values = <String>[
      for (final o in _thoughtOption?.options ?? const <ConfigOptionValue>[])
        o.value,
      if (_thoughtOption?.options.isEmpty ?? true)
        ...?_state?.thoughtLevels,
    ];
    return ComposerChip(
      icon: Icons.psychology_outlined,
      lucideIcon: 'brain',
      label: _currentThoughtLabel,
      enabled: entries.isNotEmpty,
      iconOnly: iconOnly,
      barFill: composerWidth < _composerXl && values.isNotEmpty
          ? thoughtBarFill(values, _currentThoughtValue)
          : null,
      tooltip: composerWidth >= _composerXl
          ? _currentThoughtLabel
          : '思考级别',
      menuBuilder: (context, close) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (e, value) in entries)
            ComposerMenuRow(
              entry: e,
              onTap: () {
                close();
                _switchThought(value);
              },
            ),
        ],
      ),
    );
  }

  /// Context-usage ring for the composer toolbar (official chat toolbar
  /// parity). Reacts to subscription updates; hidden until the desktop
  /// reports a usable context window.
  Widget _buildUsageRing() {
    final state = _state;
    if (state == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final info = parseContextWindowInfo(state.usage);
        if (info == null) return const SizedBox.shrink();
        return CompositedTransformTarget(
          link: _usageRingLink,
          child: _ContextUsageRing(
            ratio: info.ratio,
            onTap: _toggleUsageOverlay,
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------ sheets

  /// Slash entries = builtin/custom commands from prepareWorkspace plus the
  /// desktop's skills (triggered as `$name` in the composer).
  List<_SlashItem> get _slashItems {
    final items = <_SlashItem>[];
    for (final c in _prep?.slashCommands ?? const <SlashCommand>[]) {
      items.add(_SlashItem(
        name: c.name,
        description: c.description,
        insert: '/${c.name} ',
        isSkill: false,
      ));
    }
    for (final s in _skills) {
      items.add(_SlashItem(
        name: s.name,
        description: s.description ??
            (s.argumentHint != null ? '${s.argumentHint}' : ''),
        insert: '\$${s.name} ',
        isSkill: true,
      ));
    }
    return items;
  }

  /// Skills shown in the `@` mention menu (same trigger text as the slash
  /// bar — the composer sends `$name` either way).
  List<MentionItem> get _mentionSkills => [
        for (final item in _slashItems)
          if (item.isSkill)
            MentionItem(
              category: MentionCategory.skills,
              title: item.name,
              subtitle: item.description,
              insertMarkdown: item.insert,
            ),
      ];

  /// Dedicated skill picker so skills are one tap away (no `/` guessing).
  void _openSkillsPicker() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _SkillsPickerSheet(
        skills: _skills,
        loading: _skillsLoading,
        onSelect: (skill) {
          _inputController.text = '\$${skill.name} ';
          _inputController.selection =
              TextSelection.collapsed(offset: _inputController.text.length);
          Navigator.of(context).pop();
          setState(() => _showSlash = false);
        },
        onRefresh: _loadPrep,
      ),
    );
  }

  final LayerLink _usageRingLink = LayerLink();
  OverlayEntry? _usageOverlay;

  void _toggleUsageOverlay() {
    if (_usageOverlay != null) {
      _usageOverlay?.remove();
      _usageOverlay = null;
      return;
    }
    final state = _state;
    final sessionId = _sessionId;
    if (state == null || sessionId == null) return;
    // 官方为环上方悬浮 popover（非底部卡片）；贴右缘时右对齐防溢出。
    final ringBox =
        (_usageRingLink.leader) as RenderBox?;
    final screenW = MediaQuery.sizeOf(context).width;
    var right = false;
    if (ringBox != null) {
      final r = ringBox.localToGlobal(Offset.zero) & ringBox.size;
      right = screenW - r.right < 340;
    }
    _usageOverlay = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleUsageOverlay,
              child: const SizedBox.expand(),
            ),
          ),
          CompositedTransformFollower(
            link: _usageRingLink,
            targetAnchor: right ? Alignment.topRight : Alignment.topLeft,
            followerAnchor:
                right ? Alignment.bottomRight : Alignment.bottomLeft,
            offset: const Offset(0, -8),
            showWhenUnlinked: false,
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: math.min(320.0, screenW - 16),
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.light
                      ? Colors.white
                      : ZColors.darkCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: ZInk.messageBorder(context)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: _UsageSheet(
                    state: state,
                    session: widget.session,
                    scope: widget.scope,
                    sessionId: sessionId,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_usageOverlay!);
  }

  Future<void> _showPlansSheet() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final plans = await _transport.plans(sessionId);
      if (mounted) setState(() => _planData = plans);
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        builder: (context) => _StructuredSheet(title: '计划', data: plans),
      );
    } catch (e) {
      _toast('获取计划失败: $e');
    }
  }

  Future<void> _loadPlanData(String sessionId) async {
    if (_planLoading) return;
    _planLoading = true;
    try {
      final plans = await _transport.plans(sessionId);
      if (mounted) {
        setState(() {
          _planData = plans;
          _planRevision = _state?.revision ?? _planRevision;
        });
      }
    } catch (e) {
      log('[chat] plans load failed: $e');
    } finally {
      _planLoading = false;
    }
  }

  void _refreshPlanIfNeeded() {
    final state = _state;
    final sessionId = _sessionId;
    if (state == null || sessionId == null || state.currentMode != 'plan') {
      return;
    }
    if (_planRevision == state.revision || _planLoading) return;
    _loadPlanData(sessionId);
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: widget.automaticallyImplyLeading,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15)),
            if (state != null)
              AnimatedBuilder(
                animation: state,
                builder: (context, _) => Text(
                  [
                    if (state.phase.isNotEmpty) phaseLabel(state.phase),
                    state.currentModel,
                    if (state.currentThought.isNotEmpty) state.currentThought,
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
                ),
              ),
          ],
        ),
        actions: [
          // 辅助会话内不再提供辅助会话入口（避免递归）。
          if (_sessionId != null && !widget.isSideChat)
            IconButton(
              icon: const Icon(Icons.quickreply_outlined, size: 20),
              tooltip: '辅助对话',
              onPressed: _openSideChat,
            ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Material(
              color: ZColors.danger.withValues(alpha: 0.15),
              child: ListTile(
                dense: true,
                title:
                    Text('订阅失败: $_error', style: const TextStyle(fontSize: 12)),
                trailing:
                    TextButton(onPressed: _subscribe, child: const Text('重试')),
              ),
            ),
          Expanded(
            child: Stack(
              children: [
            state == null
                ? Center(
                    child: _sessionId == null
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(emptyGreeting(DateTime.now()),
                                  style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600,
                                      color: ZInk.solid(context))),
                              const SizedBox(height: 6),
                              Text(
                                widget.workspaceName == null
                                    ? '开始新的对话'
                                    : '开始在 ${widget.workspaceName} 项目新建任务',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: ZInk.faint(context)),
                              ),
                            ],
                          )
                        : const CircularProgressIndicator(),
                  )
                : !state.ready
                    ? const Center(child: CircularProgressIndicator())
                    : AnimatedBuilder(
                        animation: state,
                        builder: (context, _) {
                          final groups = _groupRows(state.rows);
                          final itemCount = groups.length +
                              _echoes.length +
                              (state.canLoadOlder ? 1 : 0);
                          if (groups.isEmpty &&
                              _echoes.isEmpty &&
                              !state.canLoadOlder) {
                            return Center(
                                child: Text('暂无消息',
                                    style:
                                        TextStyle(color: ZInk.faint(context))));
                          }
                          return ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                            itemCount: itemCount,
                            itemBuilder: (context, index) {
                              if (state.canLoadOlder && index == 0) {
                                return Center(
                                  child: TextButton.icon(
                                    onPressed:
                                        _loadingOlder ? null : _loadOlder,
                                    icon: _loadingOlder
                                        ? const SizedBox(
                                            width: 12,
                                            height: 12,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 1.5),
                                          )
                                        : const Icon(Icons.history, size: 14),
                                    label: const Text('加载更早消息',
                                        style: TextStyle(fontSize: 12)),
                                  ),
                                );
                              }
                              final contentIndex =
                                  index - (state.canLoadOlder ? 1 : 0);
                              if (contentIndex >= groups.length) {
                                final echo =
                                    _echoes[contentIndex - groups.length];
                                return _UserBubble(
                                  row: {
                                    'kind': 'userInput',
                                    'text': echo['text'],
                                    'attachments': echo['attachments'],
                                  },
                                  transport: _transport,
                                  sessionId: _sessionId ?? '',
                                  badge: '${echo['status'] ?? 'sending'}',
                                  onRetry: echo['status'] == 'failed'
                                      ? () => _retryEcho(echo)
                                      : null,
                                );
                              }
                              final group = groups[contentIndex];
                              final turnKey =
                                  't${group.first['rowId'] ?? contentIndex}';
                              final running = group.any((r) {
                                if (r['state'] == 'streaming') return true;
                                if (r['kind'] == 'turnHeader' &&
                                    r['state'] == 'running') {
                                  return true;
                                }
                                final s = r['status'] as String? ?? '';
                                return s == 'running' ||
                                    s == 'inputStreaming' ||
                                    s == 'pendingApproval';
                              });
                              final hasAssistantText =
                                  group.any((r) => r['kind'] == 'assistantText');
                              final defaultOpen = turnDefaultOpen(
                                isLastTurn: contentIndex == groups.length - 1,
                                running: running,
                                isOnlyTurn: groups.length == 1,
                                hasAssistantText: hasAssistantText,
                              );
                              if (_turnPrevDefault[turnKey] != null &&
                                  _turnPrevDefault[turnKey] != defaultOpen) {
                                // default flipped (turn finished) — drop the
                                // user override so the turn auto-collapses.
                                _turnExpandedOverrides.remove(turnKey);
                              }
                              _turnPrevDefault[turnKey] = defaultOpen;
                              return _TurnGroupWidget(
                                rows: group,
                                transport: _transport,
                                sessionId: _sessionId ?? '',
                                onAction: _run,
                                state: state,
                                sideChat: widget.isSideChat,
                                turnExpanded: _turnExpandedOverrides[turnKey] ??
                                    defaultOpen,
                                onToggleExpanded: (open) => setState(
                                    () => _turnExpandedOverrides[turnKey] = open),
                              );
                            },
                          );
                        },
                      ),
                if (!widget.isSideChat && state != null)
                  Positioned(
                    top: 8,
                    right: 12,
                    child: AnimatedBuilder(
                      animation: state,
                      builder: (context, _) => _StatusSummaryOverlay(
                        state: state,
                        transport: _transport,
                        sessionId: _sessionId ?? '',
                        rpcPlan: _planData,
                        onOpenPlan: _showPlansSheet,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _ReconnectBanner(bridge: _transport.session),
          if (state != null)
            AnimatedBuilder(
              animation: state,
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!widget.isSideChat) _GoalBanner(state: state),
                  if (!widget.isSideChat) _ActiveExecutionBar(state: state),
                  if (!widget.isSideChat) _QueueBar(state: state, transport: _transport),
                  _PendingInteractions(state: state, transport: _transport),
                ],
              ),
            ),
          if (_showSlash)
            _SlashCommandBar(
              query: _inputController.text,
              items: _slashItems,
              onSelect: (item) {
                if (item.name == 'compact') {
                  _inputController.text = '/compact';
                  _send();
                } else {
                  _inputController.text = item.insert;
                  _inputController.selection = TextSelection.collapsed(
                      offset: _inputController.text.length);
                  setState(() => _showSlash = false);
                }
              },
            )
          else if (_mentionTrigger != null)
            MentionMenuBar(
              query: _mentionQuery,
              hidden: {
                if (_mentionFilesFailed) MentionCategory.files,
              },
              items: {
                MentionCategory.files:
                    _mentionTrigger == '@' ? _mentionFiles : null,
                MentionCategory.sessions: _mentionSessions,
                MentionCategory.skills: _mentionSkills,
              },
              onSelect: _insertMention,
            ),
          if (_progress != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                  const SizedBox(width: 8),
                  Text(_progress!,
                      style:
                          TextStyle(fontSize: 11, color: ZInk.muted(context))),
                ],
              ),
            ),
          if (_pendingFiles.isNotEmpty)
            _PendingFilesBar(
              files: _pendingFiles,
              uploadProgress: _uploadProgress,
              onRemove: (i) => setState(() => _pendingFiles.removeAt(i)),
            ),
          _InputBar(
            controller: _inputController,
            sending: _sending,
            running: state?.isRunning ?? false,
            onStop: _sessionId == null
                ? null
                : () => _run('停止失败', () => _transport.stop(_sessionId!)),
            voiceAvailable: _voiceAvailable,
            voiceRecording: _voiceRecording,
            voiceWorking: _voiceWorking,
            onSend: _send,
            onAttach: _pickFiles,
            onSkills: _openSkillsPicker,
            onVoice: _toggleVoiceInput,
            modeChip: _buildModeChip,
            modelChip: _buildModelChip,
            thoughtChip: _buildThoughtChip,
            // 辅助对话净化：用量环复用主会话数据，辅助会话不显示。
            usageRing: widget.isSideChat
                ? const SizedBox.shrink()
                : _buildUsageRing(),
            isSideChat: widget.isSideChat,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- rows

/// Shows while the bridge is degraded (relay drop / recovery in progress)
/// so the user knows a send may be paused waiting to reconnect.
class _ReconnectBanner extends StatelessWidget {
  final BridgeSession bridge;

  const _ReconnectBanner({required this.bridge});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: bridge.degraded,
      builder: (context, degraded, _) {
        if (degraded == null) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          color: ZColors.warning.withValues(alpha: 0.15),
          child: Row(
            children: [
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('连接已断开，正在自动重连…',
                    style: TextStyle(fontSize: 12, color: ZInk.soft(context))),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One ordered piece of an assistant turn: either a merged text segment
/// (kind == 'text') or a non-text row (kind == 'row').
typedef AssistantPart = ({
  String kind,
  String? text,
  Map<String, dynamic>? row,
  bool streaming,
});

/// Splits an assistant-turn group into ORDERED parts — consecutive
/// assistantText rows merge into one text segment, while reasoning/tool/
/// subagent rows stay exactly where they occurred in the stream (so
/// "thinking → tool → answer" never renders as "answer → thinking").
typedef AssistantTurnParts = ({
  List<AssistantPart> parts,
  Map<String, dynamic>? header,
  bool streaming,
});

AssistantTurnParts assistantTurnParts(List<Map<String, dynamic>> rows) {
  final parts = <AssistantPart>[];
  Map<String, dynamic>? header;
  StringBuffer? buf;
  Map<String, dynamic>? template;
  var anyStream = false;
  var sawStreaming = false;

  void flushText() {
    if (template != null) {
      final text = buf!.toString().trim();
      if (text.isNotEmpty) {
        parts.add(
            (kind: 'text', text: text, row: template, streaming: anyStream));
      }
      buf = null;
      template = null;
      anyStream = false;
    }
  }

  for (final row in rows) {
    final kind = row['kind'];
    if (kind == 'assistantText') {
      template ??= row;
      buf ??= StringBuffer();
      final t = row['text'] as String? ?? '';
      if (buf!.isNotEmpty) buf!.write('\n\n');
      buf!.write(t);
      if (row['state'] == 'streaming') {
        anyStream = true;
        sawStreaming = true;
      }
    } else if (kind == 'turnHeader') {
      header = row;
    } else {
      flushText();
      parts.add((kind: 'row', text: null, row: row, streaming: false));
    }
  }
  flushText();
  return (parts: parts, header: header, streaming: sawStreaming);
}

/// Groups rows into turns (mirrors the web timeline): a user message starts
/// a new group; assistant text/reasoning/tool rows that follow belong to
/// the same turn and render as ONE message instead of many bubbles.
///
/// A new group starts only on a user message (or the first assistant row
/// after one). Consecutive assistant rows are merged into a single group
/// EVEN IF the server bumps `turnId` mid-response, so one answer never
/// splits into several bubbles each carrying its own feedback buttons.
List<List<Map<String, dynamic>>> _groupRows(List<Map<String, dynamic>> rows) {
  final groups = <List<Map<String, dynamic>>>[];
  List<Map<String, dynamic>>? current;
  for (final row in rows) {
    final kind = row['kind'];
    if (kind == 'timelineMarker') {
      current = null;
      groups.add([row]);
      continue;
    }
    final isUser = kind == 'userInput';
    final startsGroup =
        isUser || current == null || current.first['kind'] == 'userInput';
    if (startsGroup) {
      current = [row];
      groups.add(current);
    } else {
      current.add(row);
    }
  }
  return groups;
}

class _TurnGroupWidget extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final ConversationTransport transport;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;

  /// Auxiliary (side) chats render clean: no turn duration header, no
  /// goal banner, no feedback/fork/edit affordances (official selection
  /// side chat gates those out).
  final bool sideChat;

  /// Whether the collapsible assistant history starts expanded (official
  /// turn model: latest turn open while running, completed turns collapse).
  final bool turnExpanded;

  /// User toggled the turn collapse state.
  final ValueChanged<bool>? onToggleExpanded;

  const _TurnGroupWidget({
    required this.rows,
    required this.transport,
    required this.sessionId,
    required this.onAction,
    required this.state,
    this.sideChat = false,
    this.turnExpanded = true,
    this.onToggleExpanded,
  });

  @override
  Widget build(BuildContext context) {
    // single timeline marker
    if (rows.length == 1 && rows.first['kind'] == 'timelineMarker') {
      return _TimelineMarkerWidget(row: rows.first);
    }
    // leading user message(s) of the turn
    var lead = 0;
    while (lead < rows.length && rows[lead]['kind'] == 'userInput') {
      lead++;
    }
    final userRows = rows.sublist(0, lead);
    final assistantRows = rows.sublist(lead);
    final parts = assistantTurnParts(assistantRows);
    final showTurnHeader = !sideChat && assistantRows.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < userRows.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          _RowWidget(
            row: userRows[i],
            transport: transport,
            sessionId: sessionId,
            onAction: onAction,
            state: state,
            sideChat: sideChat,
          ),
        ],
        if (assistantRows.isNotEmpty) ...[
          if (userRows.isNotEmpty) const SizedBox(height: 20),
          if (showTurnHeader) ...[
            _buildTurnTrigger(context, parts, assistantRows),
            // collapsible content follows the bordered trigger directly
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: turnExpanded
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _assistantChildren(parts),
                    )
                  // 官方语义：收起的只是前置思考/工具流程，最终总结保留。
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _collapsedChildren(parts),
                    ),
            ),
          ] else
            ..._assistantChildren(parts),
        ],
      ],
    );
  }

  /// 折叠态只渲染最后一段 assistant 总结正文。
  List<Widget> _collapsedChildren(AssistantTurnParts parts) {
    var lastTextIdx = -1;
    for (var i = 0; i < parts.parts.length; i++) {
      if (parts.parts[i].kind == 'text') lastTextIdx = i;
    }
    if (lastTextIdx < 0) return const [];
    final all = _assistantChildren(parts);
    if (lastTextIdx >= all.length) return const [];
    return [all[lastTextIdx]];
  }

  List<Widget> _assistantChildren(AssistantTurnParts parts) {
    var lastTextIdx = -1;
    for (var i = 0; i < parts.parts.length; i++) {
      if (parts.parts[i].kind == 'text') lastTextIdx = i;
    }
    final children = <Widget>[];
    for (var i = 0; i < parts.parts.length; i++) {
      final p = parts.parts[i];
      if (p.kind == 'text') {
        children.add(_RowWidget(
          row: {
            ...?p.row,
            'kind': 'assistantText',
            'text': p.text,
            if (p.streaming) 'state': 'streaming',
          },
          showFeedback: i == lastTextIdx && !sideChat,
          transport: transport,
          sessionId: sessionId,
          onAction: onAction,
          state: state,
          sideChat: sideChat,
        ));
      } else if (_isExecutionRow(p.row!)) {
        // 官方运行中为平铺（He 官方截图对照）：思考/工具/子代理各占一行，
        // 不再做「N 个工具」折叠分组；完成后的收起由 turn 折叠承担。
        children.add(_RowWidget(
          row: p.row!,
          showFeedback: false,
          transport: transport,
          sessionId: sessionId,
          onAction: onAction,
          state: state,
          sideChat: sideChat,
        ));
      } else {
        children.add(_RowWidget(
          row: p.row!,
          showFeedback: false,
          transport: transport,
          sessionId: sessionId,
          onAction: onAction,
          state: state,
          sideChat: sideChat,
        ));
      }
    }
    return children;
  }

  /// Official turn trigger (`PX`): 「已工作 3m2s」 subtle label + rotating
  /// chevron, bottom hairline; tap collapses/expands the turn history.
  Widget _buildTurnTrigger(BuildContext context, AssistantTurnParts parts,
      List<Map<String, dynamic>> assistantRows) {
    final header = parts.header;
    String st = header?['state'] as String? ?? '';
    final ms = turnDurationMs(header ?? const {}, running: st == 'running');
    if (st.isEmpty || st == 'running') {
      final anyRunning = assistantRows.any((r) {
        if (r['state'] == 'streaming') return true;
        final s = r['status'] as String? ?? '';
        return s == 'running' || s == 'inputStreaming' || s == 'pendingApproval';
      });
      if (st != 'running' && anyRunning) st = 'running';
    }
    final label = turnWorkLabel(state: st, durationMs: ms);
    return InkWell(
      onTap: onToggleExpanded == null
          ? null
          : () => onToggleExpanded!(!turnExpanded),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.only(top: 2, bottom: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
                color: ZInk.messageBorder(context).withValues(alpha: 0.5)),
          ),
        ),
        child: Row(
          children: [
            AnimatedRotation(
              turns: turnExpanded ? 0.0 : -0.25,
              duration: const Duration(milliseconds: 150),
              child: Icon(Icons.expand_more,
                  size: 16, color: ZInk.faint(context)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: ZInk.muted(context))),
            ),
          ],
        ),
      ),
    );
  }
}

bool _isExecutionRow(Map<String, dynamic> row) {
  final kind = row['kind'];
  return kind == 'toolCall' || kind == 'reasoning' || kind == 'subagent';
}

String compactExecutionLabel(List<Map<String, dynamic>> rows) {
  final tools = rows.where((row) => row['kind'] == 'toolCall').length;
  final reasoning = rows.where((row) => row['kind'] == 'reasoning').length;
  final subagents = rows.where((row) => row['kind'] == 'subagent').length;
  final running = rows
      .any((row) => row['status'] == 'running' || row['state'] == 'streaming');
  final failed =
      rows.any((row) => row['status'] == 'error' || row['status'] == 'failed');
  final parts = <String>[
    if (running) '执行中',
    if (failed) '有失败步骤',
    if (tools > 0) '$tools 个工具',
    if (reasoning > 0) '$reasoning 段思考',
    if (subagents > 0) '$subagents 个子代理',
  ];
  return parts.isEmpty ? '执行过程' : parts.join(' · ');
}

class _ActiveExecutionBar extends StatelessWidget {
  final ConversationState state;

  const _ActiveExecutionBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final active = state.rows.where((row) {
      final kind = row['kind'];
      return (kind == 'toolCall' ||
              kind == 'reasoning' ||
              kind == 'subagent') &&
          (row['status'] == 'running' ||
              row['status'] == 'inputStreaming' ||
              row['state'] == 'streaming');
    }).toList();
    if (active.isEmpty) return const SizedBox.shrink();
    final current = active.last;
    final label = current['kind'] == 'toolCall'
        ? '${current['toolName'] ?? '工具'} 执行中'
        : current['kind'] == 'subagent'
            ? '子代理执行中'
            : '正在思考';
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 3, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: ZColors.running.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZColors.running.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 1.6),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              active.length > 1 ? '$label · 还有 ${active.length - 1} 项' : label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: ZInk.soft(context)),
            ),
          ),
          TextButton(
            onPressed: () => _scrollToLatest(context),
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: Size.zero),
            child: const Text('跟随', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }

  void _scrollToLatest(BuildContext context) {
    Scrollable.ensureVisible(context,
        duration: const Duration(milliseconds: 180), alignment: 1);
  }
}

class _RowWidget extends StatelessWidget {
  final Map<String, dynamic> row;
  final ConversationTransport transport;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;
  final bool showFeedback;
  final bool sideChat;

  const _RowWidget({
    required this.row,
    required this.transport,
    required this.sessionId,
    required this.onAction,
    required this.state,
    this.showFeedback = true,
    this.sideChat = false,
  });

  Map<String, dynamic> get _target => {
        'rowId': row['rowId'],
        if (row['entityId'] != null) 'entityId': row['entityId'],
      };

  void _showActions(BuildContext context) {
    final kind = row['kind'];
    if (kind != 'userInput' && kind != 'assistantText') return;
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 编辑入口在气泡下的操作行（气泡内原地编辑），长按菜单不再重复。
            ListTile(
              leading: const Icon(Icons.copy_outlined, size: 20),
              title: const Text('复制'),
              onTap: () {
                Navigator.pop(context);
                Clipboard.setData(
                    ClipboardData(text: row['text'] as String? ?? ''));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    duration: Duration(seconds: 1), content: Text('已复制')));
              },
            ),
            ListTile(
              leading: const Icon(Icons.replay, size: 20),
              title: const Text('重试本轮 (retryTurn)'),
              onTap: () {
                Navigator.pop(context);
                onAction('重试失败', () => transport.retryTurn(sessionId, _target));
              },
            ),
            ListTile(
              leading: const Icon(Icons.fork_right, size: 20),
              title: const Text('分叉对话 (fork)'),
              onTap: () {
                Navigator.pop(context);
                onAction(
                    '分叉失败', () => transport.forkAssistant(sessionId, _target));
              },
            ),
            ListTile(
              leading: const Icon(Icons.history, size: 20),
              title: const Text('回滚文件到此 (rewind)'),
              onTap: () {
                Navigator.pop(context);
                _confirmRewind(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.difference_outlined, size: 20),
              title: const Text('查看文件变更'),
              onTap: () {
                Navigator.pop(context);
                _showFileChanges(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRewind(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('回滚文件？'),
        content: const Text('将把此消息之后产生的文件变更回滚，对话保留'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('回滚'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await onAction('回滚失败', () => transport.applyFileRewind(sessionId, _target));
  }

  Future<void> _showFileChanges(BuildContext context) async {
    try {
      final changes = await transport.fileChanges(
        sessionId,
        target: _target,
      );
      if (!context.mounted) return;
      showModalBottomSheet(
        context: context,
        builder: (context) => _StructuredSheet(title: '文件变更', data: changes),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('获取失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final widget_ = switch (row['kind']) {
      'userInput' =>
        _UserBubble(row: row, transport: transport, sessionId: sessionId),
      'assistantText' => _AssistantBubble(
          row: row,
          transport: transport,
          sessionId: sessionId,
          state: state,
          showFeedback: showFeedback),
      'reasoning' => _ReasoningTile(
          text: row['text'] as String? ?? '',
          streaming: row['state'] == 'streaming'),
      'toolCall' => _ToolCallTile(row: row),
      'turnHeader' => _TurnHeader(row: row),
      'changeSummary' => _ChangeSummaryCard(
          row: row,
          transport: transport,
          sessionId: sessionId,
          onAction: onAction),
      'subagent' => _SubagentTile(row: row),
      'timelineMarker' =>
        // 辅助会话完全隔离：主会话的压缩等标记不带入。
        sideChat
            ? const SizedBox.shrink()
            : _TimelineMarkerWidget(row: row),
      _ => const SizedBox.shrink(),
    };
    final kind = row['kind'];
    if (kind != 'userInput' && kind != 'assistantText') return widget_;
    if (sideChat) return widget_;
    return GestureDetector(
      onLongPress: () => _showActions(context),
      child: widget_,
    );
  }
}

class _UserBubble extends StatefulWidget {
  final Map<String, dynamic> row;
  final ConversationTransport transport;
  final String sessionId;
  final String? badge;
  final VoidCallback? onRetry;

  const _UserBubble({
    required this.row,
    required this.transport,
    required this.sessionId,
    this.badge,
    this.onRetry,
  });

  @override
  State<_UserBubble> createState() => _UserBubbleState();
}

class _UserBubbleState extends State<_UserBubble> {
  bool _editing = false;
  TextEditingController? _editController;
  bool _sending = false;

  bool get _canEdit =>
      widget.badge == null &&
      widget.sessionId.isNotEmpty &&
      widget.row['rowId'] != null;

  void _startEdit() {
    _editController?.dispose();
    _editController =
        TextEditingController(text: widget.row['text'] as String? ?? '');
    setState(() => _editing = true);
  }

  Future<void> _confirmEdit() async {
    final text = _editController?.text.trim() ?? '';
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.transport.editUserQuery(
        widget.sessionId,
        {
          'rowId': widget.row['rowId'],
          if (widget.row['entityId'] != null) 'entityId': widget.row['entityId'],
        },
        text,
      );
      if (mounted) setState(() => _editing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            duration: Duration(seconds: 1), content: Text('已重发')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('编辑失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _editController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.row['text'] as String? ?? '';
    final attachments = widget.row['attachments'];
    return Align(
      alignment: Alignment.centerRight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            // Official user bubble (`data-v4-user-input-bubble`): 12px radius
            // with a 2px top-right corner, surface fill + 10% hairline, 16/12
            // padding, max-w-xl (576px). 编辑态在气泡内原地展开为多行输入框。
            constraints: const BoxConstraints(maxWidth: 576),
            width: _editing ? double.infinity : null,
            margin: const EdgeInsets.only(left: 56, top: 4, bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              // 编辑态用实底（官方无蓝色聚焦边），普通态保持 surface。
              color: _editing
                  ? (Theme.of(context).brightness == Brightness.light
                      ? Colors.white
                      : ZColors.composerDark)
                  : ZInk.messageSurface(context),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(2),
                bottomLeft: Radius.circular(12),
                bottomRight: Radius.circular(12),
              ),
              border: Border.all(
                  color: _editing
                      ? ZInk.messageBorder(context)
                      : ZInk.messageBorder(context)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (attachments is List && !_editing)
                  for (final a in attachments)
                    if (a is Map)
                      _AttachmentView(
                        attachment: a.cast<String, dynamic>(),
                        transport: widget.transport,
                        sessionId: widget.sessionId,
                      ),
                if (_editing) ...[
                  TextField(
                    controller: _editController,
                    minLines: 2,
                    maxLines: 8,
                    autofocus: true,
                    style: TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: ZInk.solid(context)),
                    decoration: const InputDecoration(
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _sending
                            ? null
                            : () => setState(() => _editing = false),
                        style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        child: const Text('取消',
                            style: TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 6),
                      FilledButton(
                        onPressed: _sending ? null : _confirmEdit,
                        style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            minimumSize: Size.zero,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        child: const Text('重新发送',
                            style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ] else ...[
                  if (text.isNotEmpty)
                    SelectableText(text,
                        style: TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            color: ZInk.solid(context))),
                  if (widget.badge != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(widget.badge!,
                            style: TextStyle(
                                fontSize: 10, color: ZInk.faint(context))),
                        if (widget.onRetry != null)
                          TextButton(
                            onPressed: widget.onRetry,
                            style: TextButton.styleFrom(
                                padding: const EdgeInsets.only(left: 4),
                                minimumSize: Size.zero,
                                tapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap),
                            child: const Text('重试',
                                style: TextStyle(fontSize: 10)),
                          ),
                      ],
                    ),
                ],
              ],
            ),
          ),
          // 官方用户消息的操作行（编辑/复制/分叉），气泡下右对齐。
          _UserActionRow(
            row: widget.row,
            transport: widget.transport,
            sessionId: widget.sessionId,
            onEdit: _canEdit && !_editing ? _startEdit : null,
          ),
        ],
      ),
    );
  }
}

/// Small action row under the user bubble: edit & resend / copy / fork —
/// the explicit counterpart of the official hover actions. Editing happens
/// INLINE inside the bubble ([_UserBubble] owns the editing state), not in
/// a dialog.
class _UserActionRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final ConversationTransport transport;
  final String sessionId;

  /// Opens the bubble's in-place editor; null hides the edit button
  /// (rows without a server rowId / echo messages can't be edited).
  final VoidCallback? onEdit;

  const _UserActionRow({
    required this.row,
    required this.transport,
    required this.sessionId,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 2, bottom: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onEdit != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              constraints:
                  const BoxConstraints(minWidth: 30, minHeight: 26),
              padding: EdgeInsets.zero,
              iconSize: 14,
              color: ZInk.faint(context),
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined),
              onPressed: onEdit,
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints:
                const BoxConstraints(minWidth: 30, minHeight: 26),
            padding: EdgeInsets.zero,
            iconSize: 14,
            color: ZInk.faint(context),
            tooltip: '复制',
            icon: const Icon(Icons.copy_outlined),
            onPressed: () {
              Clipboard.setData(
                  ClipboardData(text: row['text'] as String? ?? ''));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  duration: Duration(seconds: 1), content: Text('已复制')));
            },
          ),
        ],
      ),
    );
  }
}

class _AttachmentView extends StatefulWidget {
  final Map<String, dynamic> attachment;
  final ConversationTransport transport;
  final String sessionId;

  const _AttachmentView({
    required this.attachment,
    required this.transport,
    required this.sessionId,
  });

  @override
  State<_AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<_AttachmentView> {
  Uint8List? _imageBytes;
  bool _failed = false;

  bool get _isImage =>
      '${widget.attachment['mime'] ?? ''}'.startsWith('image/');

  @override
  void initState() {
    super.initState();
    if (_isImage) _load();
  }

  Future<void> _load() async {
    final ref = widget.attachment['ref'] as String?;
    if (ref == null) return;
    try {
      final res =
          await widget.transport.attachmentRead(widget.sessionId, ref: ref);
      if (mounted) setState(() => _imageBytes = res.bytes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileName = '${widget.attachment['fileName'] ?? '附件'}';
    if (!_isImage) {
      return Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: ZInk.tile(context),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_drive_file_outlined, size: 16),
            const SizedBox(width: 6),
            Flexible(
              child: Text(fileName,
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );
    }
    if (_failed) {
      return Text('[图片加载失败] $fileName',
          style: TextStyle(fontSize: 11, color: ZInk.faint(context)));
    }
    if (_imageBytes == null) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 1.5)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(
          _imageBytes!,
          width: 220,
          cacheWidth: 440,
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  final Map<String, dynamic> row;
  final ConversationTransport transport;
  final String sessionId;
  final ConversationState state;
  final bool showFeedback;

  const _AssistantBubble({
    required this.row,
    required this.transport,
    required this.sessionId,
    required this.state,
    this.showFeedback = true,
  });

  void _setFeedback(String? value) {
    if (sessionId.isEmpty) return;
    // Optimistic: update the icon instantly; server row.upserted confirms.
    state.optimisticRowUpdate(row['rowId'] as num?, {'feedback': value});
    transport.setAssistantFeedback(
      sessionId,
      {
        'rowId': row['rowId'],
        if (row['entityId'] != null) 'entityId': row['entityId'],
      },
      value,
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = row['text'] as String? ?? '';
    final streaming = row['state'] == 'streaming';
    final feedback = row['feedback'] as String?;
    return Container(
      margin: const EdgeInsets.only(right: 24, top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ZemoteMarkdown(text),
          if (showFeedback)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (streaming)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                  )
                else ...[
                  _FeedbackButton(
                    icon: Icons.copy_outlined,
                    lucideIcon: 'copy',
                    active: false,
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: text));
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              duration: Duration(seconds: 1),
                              content: Text('已复制')));
                    },
                  ),
                  _FeedbackButton(
                    icon: Icons.thumb_up_alt_outlined,
                    lucideIcon: 'thumbs-up',
                    active: feedback == 'like',
                    onTap: () =>
                        _setFeedback(feedback == 'like' ? null : 'like'),
                  ),
                  _FeedbackButton(
                    icon: Icons.thumb_down_alt_outlined,
                    lucideIcon: 'thumbs-down',
                    active: feedback == 'dislike',
                    onTap: () =>
                        _setFeedback(feedback == 'dislike' ? null : 'dislike'),
                  ),
                  _FeedbackButton(
                    icon: Icons.fork_right,
                    lucideIcon: 'git-branch',
                    active: false,
                    onTap: () {
                      if (sessionId.isEmpty) return;
                      transport
                          .forkAssistant(sessionId, {
                        'rowId': row['rowId'],
                        if (row['entityId'] != null) 'entityId': row['entityId'],
                      })
                          .then((_) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  duration: Duration(seconds: 2),
                                  content: Text('已分叉，新会话在任务列表中')));
                        }
                      }).catchError((Object _) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('分叉失败，请重试')));
                        }
                      });
                    },
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _FeedbackButton extends StatelessWidget {
  final IconData icon;

  /// Official lucide glyph (takes precedence over [icon]).
  final String? lucideIcon;
  final bool active;
  final VoidCallback onTap;

  const _FeedbackButton({
        required this.icon,
    this.lucideIcon, required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: lucideIcon != null
          ? LucideIcon(lucideIcon!,
              size: 15, color: active ? ZColors.primary : ZInk.ghost(context))
          : Icon(icon,
              size: 15,
              color: active ? ZColors.primary : ZInk.ghost(context)),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// 官方 `.animated-gradient-text`（index-BM2ndL2ru.css 实抓）：
/// linear-gradient(90deg, strong 0/34/66/100%, soft 50%)，background-size
/// 300%，`gradient-flow` 4s linear——前 2s 从 position 100% 扫到 0，
/// 后 2s 停驻。strong = 正文色（深 #fff / 浅 #0d0d0d），soft = 同色
/// 20%~22% 透明度（官方 --animated-gradient-text-soft）。
class _AnimatedGradientText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _AnimatedGradientText({
    required this.text,
    required this.style,
  });

  @override
  State<_AnimatedGradientText> createState() => _AnimatedGradientTextState();
}

class _AnimatedGradientTextState extends State<_AnimatedGradientText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final strong = isLight ? const Color(0xFF0D0D0D) : Colors.white;
    final softAlpha = isLight ? 0.22 : 0.20;
    final soft = strong.withValues(alpha: softAlpha);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        // background-position 100% -> 0%（前半程扫过），随后停驻。
        final q = (t / 0.5).clamp(0.0, 1.0);
        return ShaderMask(
          shaderCallback: (bounds) {
            final w = bounds.width;
            final origin = -2 * w * (1 - q);
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [strong, strong, soft, strong, strong],
              stops: const [0.0, 0.34, 0.5, 0.66, 1.0],
            ).createShader(Rect.fromLTWH(origin, 0, w * 3, bounds.height));
          },
          child: child,
        );
      },
      child: Text(widget.text, style: widget.style),
    );
  }
}

class _ReasoningTile extends StatefulWidget {
  final String text;
  final bool streaming;

  const _ReasoningTile({required this.text, this.streaming = false});

  @override
  State<_ReasoningTile> createState() => _ReasoningTileState();
}

class _ReasoningTileState extends State<_ReasoningTile> {
  bool _expanded = false;

  /// Chevron shows on toggle and fades out after a few seconds (the official
  /// client reveals it on hover; mobile has no hover, so it appears on
  /// interaction instead). While streaming it stays visible.
  bool _chevronVisible = false;
  Timer? _chevronTimer;

  static const _chevronFade = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    // 官方思考行在运行中也保持一行折叠态（He 官方截图对照）：
    // 「思考 · 持续了 N 秒」，内容点开才显示，不随流式自动展开。
    _chevronVisible = widget.streaming;
  }

  @override
  void didUpdateWidget(_ReasoningTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.streaming && oldWidget.streaming) {
      _scheduleChevronFade();
    }
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      _chevronVisible = true;
    });
    _scheduleChevronFade();
  }

  void _scheduleChevronFade() {
    if (widget.streaming) return;
    _chevronTimer?.cancel();
    _chevronTimer = Timer(_chevronFade, () {
      if (mounted) setState(() => _chevronVisible = false);
    });
  }

  @override
  void dispose() {
    _chevronTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 官方思考块（浅色实测）：无底色无框的一行灰字「图标 思考 · 时长」，
    // 展开后内容挂在浅灰左竖线下；chevron 仅在操作后短暂出现。
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LucideIcon('brain',
                      size: 14,
                      color: widget.streaming
                          ? ZColors.running
                          : ZInk.faint(context)),
                  const SizedBox(width: 7),
                  // 官方流式头部 = animated-gradient-text + 「正在思考」。
                  if (widget.streaming)
                    _AnimatedGradientText(
                      text: '正在思考',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w500),
                    )
                  else
                    Text('思考',
                        style: TextStyle(
                            fontSize: 13, color: ZInk.faint(context))),
                  if (!widget.streaming) ...[
                    const SizedBox(width: 7),
                    Text('·',
                        style: TextStyle(
                            fontSize: 12, color: ZInk.faint(context))),
                    const SizedBox(width: 7),
                    Text('持续了几秒',
                        style: TextStyle(
                            fontSize: 13, color: ZInk.faint(context))),
                  ],
                  const SizedBox(width: 6),
                  AnimatedOpacity(
                    opacity: _chevronVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 250),
                    child: AnimatedRotation(
                      // 官方 chevron：默认朝右，展开 rotate-90。
                      turns: _expanded ? 0.25 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Icon(Icons.chevron_right,
                          size: 16, color: ZInk.faint(context)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 8),
              child: Container(
                padding: const EdgeInsets.only(left: 14),
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                        width: 1, color: ZInk.messageBorder(context)),
                  ),
                ),
                child: ZemoteMarkdown(widget.text, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToolCallTile extends StatefulWidget {
  final Map<String, dynamic> row;

  const _ToolCallTile({required this.row});

  @override
  State<_ToolCallTile> createState() => _ToolCallTileState();
}

class _ToolCallTileState extends State<_ToolCallTile> {
  bool _expanded = false;

  /// Same chevron policy as the reasoning tile (official behavior: chevron
  /// default-hidden, revealed on interaction, fades after a few seconds):
  /// visible while running, revealed on toggle, then fades out.
  bool _chevronVisible = false;
  Timer? _chevronTimer;

  static const _chevronFade = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    // 官方行为：运行中/等待确认的工具默认展开详情。
    final status = widget.row['status'] as String? ?? '';
    final running = status == 'running' ||
        status == 'inputStreaming' ||
        status == 'pendingApproval';
    _expanded = running;
    _chevronVisible = running;
  }

  @override
  void didUpdateWidget(_ToolCallTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasRunning = _chevronVisible;
    final status = widget.row['status'] as String? ?? '';
    final running = status == 'running' ||
        status == 'inputStreaming' ||
        status == 'pendingApproval';
    if (running && !wasRunning) {
      setState(() => _chevronVisible = true);
    } else if (!running && wasRunning) {
      _scheduleChevronFade();
    }
  }

  void _toggle() {
    if (!mounted) return;
    setState(() {
      _expanded = !_expanded;
      _chevronVisible = true;
    });
    _scheduleChevronFade();
  }

  void _scheduleChevronFade() {
    _chevronTimer?.cancel();
    _chevronTimer = Timer(_chevronFade, () {
      if (mounted) setState(() => _chevronVisible = false);
    });
  }

  @override
  void dispose() {
    _chevronTimer?.cancel();
    super.dispose();
  }

  /// Official kind labels — 「终端」 verified against the real light-theme
  /// web client (shell family), others from `chat.toolCall.kind.*`.
  static const _kindLabels = {
    'Read': '读取',
    'Write': '写入',
    'Edit': '编辑',
    'MultiEdit': '编辑',
    'NotebookEdit': '编辑',
    'Grep': '搜索',
    'Glob': '搜索',
    'WebFetch': '搜索',
    'WebSearch': '搜索',
    'Bash': '终端',
    'TodoWrite': '待办',
    'Task': '任务',
    'AskUserQuestion': '询问',
  };

  /// Per-family OFFICIAL lucide glyphs (terminal / magnifier / earth /
  /// bot / list-todo / file-diff — all extracted from the official bundle).
  static const _kindLucideIcons = {
    'Read': 'search',
    'Grep': 'search',
    'Glob': 'search',
    'WebSearch': 'earth',
    'WebFetch': 'globe',
    'Write': 'file-diff',
    'Edit': 'file-diff',
    'MultiEdit': 'file-diff',
    'NotebookEdit': 'file-diff',
    'Bash': 'terminal',
    'TodoWrite': 'list-todo',
    'Task': 'bot',
  };

  String get _kindLabel {
    final toolName = widget.row['toolName'] as String? ?? '';
    // 官方 ask-user-question 家族（Mrt）：kindLabel 随状态切换为
    // 「正在询问 / 已询问」。
    if (toolName == 'AskUserQuestion') {
      final status = widget.row['status'] as String? ?? '';
      final running = status == 'running' ||
          status == 'inputStreaming' ||
          status == 'pendingApproval';
      return running ? '正在询问' : '已询问';
    }
    return _kindLabels[toolName] ?? toolName;
  }

  /// ask-user-question 的输入里通常带 questions 数组（官方 secondary =
  /// 「N 个问题」）。
  int get _questionCount {
    final inputText = widget.row['inputText'] as String? ?? '';
    if (inputText.isEmpty) return 0;
    try {
      final input = jsonDecode(inputText);
      if (input is Map && input['questions'] is List) {
        return (input['questions'] as List).length;
      }
    } catch (_) {}
    return 0;
  }

  /// Primary summary: a file path / command / pattern from the structured
  /// input when present (official `title`), else the truncated raw input.
  String get _primaryText {
    final inputText = widget.row['inputText'] as String? ?? '';
    if (inputText.isEmpty) return '';
    Object? input;
    try {
      input = jsonDecode(inputText);
    } catch (_) {
      final one = inputText.replaceAll('\n', ' ').trim();
      return one.length > 60 ? '${one.substring(0, 60)}…' : one;
    }
    if (input is Map) {
      for (final key in ['filePath', 'file_path', 'path', 'command',
        'pattern', 'url', 'query', 'question', 'description']) {
        final v = input[key];
        if (v is String && v.isNotEmpty) {
          return v.replaceAll('\n', ' ');
        }
      }
    }
    final one = inputText.replaceAll('\n', ' ').trim();
    return one.length > 60 ? '${one.substring(0, 60)}…' : one;
  }

  (String?, Color) _statusLabel(BuildContext context) {
    final status = widget.row['status'] as String? ?? '';
    // 官方完成态不显示状态文字（浅色实测），只有进行中/失败/待确认才出现。
    final label = switch (status) {
      'running' || 'inputStreaming' => '执行中',
      'pendingApproval' => '等待确认',
      'pending' => '等待中',
      'error' || 'failed' => '执行失败',
      'rejected' => '已拒绝',
      'stopped' => '已停止',
      _ => null,
    };
    final color = switch (status) {
      'running' || 'inputStreaming' => ZColors.running,
      'pendingApproval' => ZColors.warning,
      'pending' => ZInk.faint(context),
      'error' || 'failed' || 'rejected' => ZColors.danger,
      'stopped' => ZInk.faint(context),
      _ => ZInk.faint(context),
    };
    return (label, color);
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final status = row['status'] as String? ?? '';
    final running = status == 'running' ||
        status == 'inputStreaming' ||
        status == 'pendingApproval';
    final output = row['output'];
    final outputText = output is Map ? output['text'] as String? ?? '' : '';
    final error = row['error'];
    final progress = row['progress'];
    final display = row['display'];
    final diff = extractDiff(row);
    final hasDetails = (row['inputText'] as String? ?? '').isNotEmpty ||
        outputText.isNotEmpty ||
        error is Map ||
        diff != null ||
        (display is Map &&
            display['kind'] == 'node_repl_images' &&
            display['images'] is List);
    final primary = _primaryText;
    final (statusLabel, statusColor) = _statusLabel(context);
    final toolName = row['toolName'] as String? ?? '';
    final kindIcon = Icons.build_outlined;

    // 编辑/写入行的 +/- 行数角标（官方 diffCount）。
    var added = 0, removed = 0;
    if (diff != null) {
      for (final line in diff.lines) {
        switch (line.type) {
          case DiffLineType.added:
            added++;
          case DiffLineType.removed:
            removed++;
          case DiffLineType.context:
            break;
        }
      }
    }

    final images = display is Map &&
            display['kind'] == 'node_repl_images' &&
            display['images'] is List
        ? display['images'] as List
        : const [];

    // 官方 ToolLayout（浅色实测）：无卡片容器的单行灰字——专属图标 +
    // kind 标签 + `·` + 摘要（+ diff 计数），完成态无状态文字，整行
    // 点击展开左竖线详情。行随内容收拢（mainAxisSize.min），chevron
    // 贴在文本右侧而非顶到行尾，且仅操作后短暂出现。
    final header = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_kindLucideIcons[toolName] != null)
            LucideIcon(_kindLucideIcons[toolName]!,
                size: 14,
                color: running ? ZColors.running : ZInk.faint(context))
          else
            Icon(kindIcon,
                size: 14,
                color: running ? ZColors.running : ZInk.faint(context)),
          const SizedBox(width: 7),
          // 官方 running 时 kindLabel 用 animated-gradient-text。
          if (running)
            _AnimatedGradientText(
              text: _kindLabel,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500),
            )
          else
            Text(
              _kindLabel,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                // 已执行行比进行中更浅（官方 subtlest 层级）。
                color: ZInk.faint(context),
              ),
            ),
          if (primary.isNotEmpty) ...[
            const SizedBox(width: 7),
            Text('·', style: TextStyle(fontSize: 12, color: ZInk.faint(context))),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                primary,
                style: TextStyle(
                    fontSize: 13,
                    color: running
                        ? ZInk.soft(context)
                        : ZInk.faint(context)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (added > 0 || removed > 0) ...[
              const SizedBox(width: 8),
              Text('+$added',
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: ZInk.diffAdded(context))),
              const SizedBox(width: 5),
              Text('-$removed',
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: ZInk.diffRemoved(context))),
            ],
            if (_questionCount > 1) ...[
              const SizedBox(width: 8),
              Text('$_questionCount 个问题',
                  style: TextStyle(fontSize: 12, color: ZInk.faint(context))),
            ],
          ],
          if (statusLabel != null)
            Padding(
              padding: const EdgeInsets.only(left: 7),
              child: Text(statusLabel,
                  style: TextStyle(fontSize: 12, color: statusColor)),
            ),
          if (hasDetails) ...[
            const SizedBox(width: 6),
            AnimatedOpacity(
              opacity: _chevronVisible ? 1 : 0,
              duration: const Duration(milliseconds: 250),
              child: AnimatedRotation(
                // 官方 chevron：默认朝右，展开 rotate-90。
                turns: _expanded ? 0.25 : 0,
                duration: const Duration(milliseconds: 150),
                child: Icon(Icons.chevron_right,
                    size: 16, color: ZInk.faint(context)),
              ),
            ),
          ],
        ],
      ),
    );

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (row['inputText'] is String && (row['inputText'] as String).isNotEmpty)
          _kv(context, '输入', row['inputText'] as String),
        if (outputText.isNotEmpty) _kv(context, '输出', outputText),
        if (error is Map)
          _kv(context, '错误', '${error['code'] ?? ''} ${error['message'] ?? ''}'),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: hasDetails ? _toggle : null,
            child: header,
          ),
          if (_expanded && hasDetails)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 8),
              child: Container(
                padding: const EdgeInsets.only(left: 14),
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                        width: 1, color: ZInk.messageBorder(context)),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    body,
                    if (progress is Map) _ProgressRow(progress: progress),
                    if (diff != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(0, 4, 8, 8),
                        child: DiffView(diff: diff),
                      ),
                    for (final image in images)
                      if (image is Map && image['base64'] is String)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(0, 0, 12, 8),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(
                              base64Decode(image['base64'] as String),
                              cacheWidth:
                                  (MediaQuery.sizeOf(context).width * 2).round(),
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) =>
                                  const SizedBox.shrink(),
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String label, String value) {
    Object? structured;
    try {
      structured = jsonDecode(value);
    } catch (_) {}
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 10.5, color: ZInk.faint(context))),
          const SizedBox(height: 2),
          if (structured is Map || structured is List)
            StructuredDataView(data: structured, maxDepth: 3)
          else
            // 官方原始输出 fallback：`px-4 py-3 rounded-xl bg-surface
            // max-h-50 overflow-auto`——限高滚动而非截断。
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 200),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              decoration: BoxDecoration(
                color: ZInk.messageSurface(context),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  value.length > 20000 ? '${value.substring(0, 20000)}…' : value,
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: ZInk.solid(context)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Official change-summary card (`utt`): header row with file count and
/// +N -N diff counters, expandable per-file rows, review/rewind actions.
class _ChangeSummaryCard extends StatefulWidget {
  final Map<String, dynamic> row;
  final ConversationTransport transport;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;

  const _ChangeSummaryCard({
    required this.row,
    required this.transport,
    required this.sessionId,
    required this.onAction,
  });

  @override
  State<_ChangeSummaryCard> createState() => _ChangeSummaryCardState();
}

class _ChangeSummaryCardState extends State<_ChangeSummaryCard> {
  bool _expanded = false;

  ({List<({String path, int added, int removed})> files, int added, int removed})
      _parse() {
    final files = <({String path, int added, int removed})>[];
    final raw = widget.row['files'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is String) {
          files.add((path: entry, added: 0, removed: 0));
        } else if (entry is Map) {
          final path =
              '${entry['path'] ?? entry['filePath'] ?? entry['file'] ?? entry['name'] ?? ''}';
          if (path.isEmpty) continue;
          files.add((
            path: path,
            added: (entry['additions'] as num?)?.toInt() ?? 0,
            removed: (entry['deletions'] as num?)?.toInt() ?? 0,
          ));
        }
      }
    }
    var added = (widget.row['additions'] as num?)?.toInt();
    var removed = (widget.row['deletions'] as num?)?.toInt();
    if (added == null || removed == null) {
      var a = 0;
      var r = 0;
      for (final f in files) {
        a += f.added;
        r += f.removed;
      }
      added ??= files.isEmpty ? 0 : a;
      removed ??= files.isEmpty ? 0 : r;
    }
    return (files: files, added: added, removed: removed);
  }

  Map<String, dynamic> get _target => {
        'rowId': widget.row['rowId'],
        if (widget.row['entityId'] != null) 'entityId': widget.row['entityId'],
      };

  Future<void> _rewind() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('撤销文件改动'),
        content: const Text(
            '撤销前会重新检查当前文件内容；如果文件已被其他进程改过，本次不会写入任何文件。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('撤销文件')),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.onAction('撤销失败',
        () => widget.transport.applyFileRewind(widget.sessionId, _target));
  }

  @override
  Widget build(BuildContext context) {
    final (:files, :added, :removed) = _parse();
    final cardColor = Theme.of(context).brightness == Brightness.light
        ? ZColors.composerLight
        : ZColors.composerDark;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6, right: 16),
      child: Container(
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ZInk.messageBorder(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(12)),
              onTap:
                  files.isEmpty ? null : () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox(
                  height: 40,
                  child: Row(
                    children: [
                      AnimatedRotation(
                        turns: _expanded ? 0.25 : 0,
                        duration: const Duration(milliseconds: 150),
                        child: Icon(Icons.chevron_right,
                            size: 12, color: ZInk.faint(context)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('${files.length} 个文件已更改',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: ZInk.solid(context))),
                      ),
                      Text('+$added',
                          style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: ZInk.diffAdded(context))),
                      const SizedBox(width: 5),
                      Text('-$removed',
                          style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: ZInk.diffRemoved(context))),
                    ],
                  ),
                ),
              ),
            ),
            if (_expanded && files.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final f in files)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(f.path,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                      color: ZInk.muted(context))),
                            ),
                            Text('+${f.added}',
                                style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    color: ZInk.diffAdded(context))),
                            const SizedBox(width: 4),
                            Text('-${f.removed}',
                                style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    color: ZInk.diffRemoved(context))),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      try {
                        final changes = await widget.transport
                            .fileChanges(widget.sessionId, target: _target);
                        if (!context.mounted) return;
                        showModalBottomSheet(
                          context: context,
                          builder: (sheetContext) => _StructuredSheet(
                              title: '文件变更', data: changes),
                        );
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('获取失败: $e')));
                        }
                      }
                    },
                    icon: const Icon(Icons.search, size: 15),
                    label: const Text('审查', style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 4),
                  TextButton.icon(
                    onPressed: _rewind,
                    icon: const Icon(Icons.undo, size: 15),
                    label: const Text('撤销', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressRow extends StatelessWidget {
  final Map progress;

  const _ProgressRow({required this.progress});

  @override
  Widget build(BuildContext context) {
    final bytes = (progress['bytes'] as num?)?.toInt() ?? 0;
    final preview = progress['previewLine'] as String? ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              [
                if (preview.isNotEmpty) preview,
                '${(bytes / 1024).toStringAsFixed(1)} KB',
              ].join(' · '),
              style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _TurnHeader extends StatelessWidget {
  final Map<String, dynamic> row;

  const _TurnHeader({required this.row});

  @override
  Widget build(BuildContext context) {
    // 官方 turnHeader（PX）：subtle 一行「已工作 {duration}」，无色彩编码。
    final st = row['state'] as String? ?? '';
    final ms = turnDurationMs(row, running: st == 'running');
    final label = turnWorkLabel(state: st, durationMs: ms);
    return Container(
      margin: const EdgeInsets.only(top: 10, bottom: 6),
      padding: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(color: ZInk.messageBorder(context))),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 12, color: ZInk.muted(context))),
    );
  }
}

class _TimelineMarkerWidget extends StatelessWidget {
  final Map<String, dynamic> row;

  const _TimelineMarkerWidget({required this.row});

  @override
  Widget build(BuildContext context) {
    final marker = row['marker'];
    if (marker is! Map) return const SizedBox.shrink();
    final type = '${marker['type'] ?? ''}';

    final (icon, text, _) = switch (type) {
      'compact' => (
          Icons.compress,
          '压缩上下文 · ${marker['status'] ?? ''}'
              '${marker['tokensBefore'] != null ? ' · ${marker['tokensBefore']}→${marker['tokensAfter'] ?? '?'} tokens' : ''}',
          ZColors.primary
        ),
      'forkNotice' => (Icons.fork_right, '从会话分叉而来', ZInk.faint(context)),
      'forkCreated' => (Icons.fork_right, '已创建分叉会话', ZInk.faint(context)),
      'modelChange' => (
          Icons.swap_horiz,
          '模型切换 ${marker['fromModel'] ?? ''} → ${marker['toModel'] ?? ''}',
          ZColors.warning
        ),
      'goalSet' => (
          Icons.flag_outlined,
          '设定目标: ${marker['objective'] ?? ''}',
          ZColors.success
        ),
      'goalVerify' => (
          Icons.fact_check_outlined,
          '目标验证 第${marker['iteration'] ?? '?'}轮 · ${marker['outcome'] ?? ''}',
          ZColors.success
        ),
      'retryNotice' => (
          Icons.refresh,
          '自动重试 第${marker['attempt'] ?? '?'}次 (${marker['reasonCode'] ?? ''})',
          ZColors.warning
        ),
      'checkpointRestored' => (Icons.restore, '已恢复检查点', ZInk.faint(context)),
      _ => (Icons.info_outline, type, ZInk.faint(context)),
    };

    // 官方 timelineMarker（$at）：左右两条 1px 细线夹着中央图标与标签，
    // 无底色 pill；文本统一 subtle 灰。
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            Expanded(child: Container(height: 1, color: ZInk.messageBorder(context))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 13, color: ZInk.muted(context)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      text,
                      style: TextStyle(fontSize: 12, color: ZInk.muted(context)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: Container(height: 1, color: ZInk.messageBorder(context))),
          ],
        ),
      ),
    );
  }
}

class _SubagentTile extends StatelessWidget {
  final Map<String, dynamic> row;

  const _SubagentTile({required this.row});

  @override
  Widget build(BuildContext context) {
    // 官方 subagent 行（not 组件）：一行 subtle 小字「类型 · 状态 — 摘要」，
    // 无卡片容器、无图标。
    final type = row['subagentType'] as String? ?? '';
    final status = row['status'] as String? ?? '';
    final summary = row['summaryText'] as String? ?? '';
    final text = [
      if (type.isNotEmpty) type,
      if (status.isNotEmpty) status,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const LucideIcon('bot', size: 13, color: ZColors.trajectoryAssistant),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              summary.isNotEmpty
                  ? '$text — $summary'
                  : text,
              style: TextStyle(fontSize: 12, color: ZInk.muted(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- bars

/// Composer context-usage ring (official chat toolbar parity): a tiny
/// circular progress arc — track 25% ink, used 70% ink, round cap starting
/// at 12 o'clock. Tap opens the usage sheet (context composition +
/// cache hit rate + cumulative tokens).
class _ContextUsageRing extends StatelessWidget {
  final double ratio;
  final VoidCallback onTap;

  const _ContextUsageRing({required this.ratio, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '上下文容量',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: CustomPaint(
            size: const Size(20, 20),
            painter: _UsageRingPainter(ratio, color: ZInk.muted(context)),
          ),
        ),
      ),
    );
  }
}

class _UsageRingPainter extends CustomPainter {
  final double ratio;
  final Color color;

  _UsageRingPainter(this.ratio, {required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1.5;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = color.withValues(alpha: 0.25);
    canvas.drawCircle(center, radius, track);
    final sweep = 2 * 3.141592653589793 * ratio.clamp(0.0, 1.0);
    if (sweep <= 0) return;
    final progress = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.7);
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius),
        -3.141592653589793 / 2, sweep, false, progress);
  }

  @override
  bool shouldRepaint(_UsageRingPainter oldDelegate) =>
      oldDelegate.ratio != ratio || oldDelegate.color != color;
}

/// Segment colors for the context composition bar — official palette is a
/// five-step mix of usage-chart-1 (sky) toward the surface color.
List<Color> usageSegmentColors(BuildContext context) {
  final base = Theme.of(context).brightness == Brightness.light
      ? const Color(0xFF0284C7)
      : const Color(0xFF0EA5E9);
  final surface = Theme.of(context).scaffoldBackgroundColor;
  return [
    for (final f in const [1.0, 0.78, 0.58, 0.42, 0.28])
      Color.lerp(surface, base, f)!,
  ];
}

class _GoalBanner extends StatelessWidget {
  final ConversationState state;

  const _GoalBanner({required this.state});

  /// 目标横幅展示时机（对齐官方 goal 语义）：目标进行中/校验中/已暂停
  /// 才展示；协议终态（completedSuccess / completedIncomplete /
  /// cancelled 等）不再常驻——结果由时间线的 goalVerify 标记记录。
  static (bool, String?) _statusText(String status) {
    final s = status.toLowerCase();
    if (s.isEmpty) return (true, null);
    if (s.contains('complete') || s.contains('cancel') || s.contains('fail') || s.contains('error')) {
      return (false, null);
    }
    if (s.contains('check') || s.contains('verif')) return (true, '目标校验中');
    if (s.contains('pause') || s.contains('hold')) return (true, '已暂停');
    return (true, null);
  }

  @override
  Widget build(BuildContext context) {
    final goal = state.goal;
    if (goal == null) return const SizedBox.shrink();
    final objective = '${goal['objective'] ?? ''}';
    if (objective.isEmpty) return const SizedBox.shrink();
    final (show, statusText) = _statusText('${goal['status'] ?? ''}');
    if (!show) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ZColors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZColors.success.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.flag_outlined, size: 14, color: ZColors.success),
          const SizedBox(width: 8),
          Text('目标',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: ZColors.success)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              objective,
              style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (statusText != null)
            Text(statusText,
                style: const TextStyle(fontSize: 11, color: ZColors.success)),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _PlanBanner extends StatelessWidget {
  final ConversationState state;
  final Object? rpcPlan;
  final VoidCallback onOpenRaw;

  const _PlanBanner({
    required this.state,
    required this.rpcPlan,
    required this.onOpenRaw,
  });

  @override
  Widget build(BuildContext context) {
    final steps = derivePlanSteps(
      rows: state.rows,
      snapshotPlan: state.plan ?? rpcPlan,
    );
    if ((steps == null || steps.isEmpty) && state.currentMode != 'plan') {
      return const SizedBox.shrink();
    }
    final visibleSteps = steps ?? const <PlanStep>[];
    final hasRawPlan = rpcPlan != null || state.plan != null;
    final completed = visibleSteps.where((step) => step.completed).length;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      decoration: BoxDecoration(
        color: ZInk.reasoningPanel(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZInk.reasoningBorder(context)),
      ),
      child: ExpansionTile(
        initiallyExpanded: true,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.account_tree_outlined,
            color: ZColors.primary, size: 18),
        title: Text(
          visibleSteps.isEmpty
              ? '计划模式'
              : '执行计划 · $completed/${visibleSteps.length}',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: ZInk.solid(context),
          ),
        ),
        subtitle: visibleSteps.isEmpty
            ? Text(hasRawPlan ? '计划数据已加载' : '等待计划内容…',
                style: TextStyle(fontSize: 11, color: ZInk.muted(context)))
            : null,
        children: [
          if (visibleSteps.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Column(
                children: [
                  for (final step in visibleSteps)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            step.completed
                                ? Icons.check_circle
                                : step.status == 'in_progress'
                                    ? Icons.pending
                                    : Icons.radio_button_unchecked,
                            size: 16,
                            color: step.completed
                                ? ZColors.success
                                : step.status == 'in_progress'
                                    ? ZColors.running
                                    : ZInk.muted(context),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              step.content,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: ZInk.solid(context),
                                decoration: step.completed
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: onOpenRaw,
                      child: const Text('查看完整计划'),
                    ),
                  ),
                ],
              ),
            ),
          if (visibleSteps.isEmpty && hasRawPlan)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onOpenRaw,
                child: const Text('查看完整计划'),
              ),
            ),
        ],
      ),
    );
  }
}

/// 官方 summaryPanel（`chat.summaryPanel.*`，2026-09-07 bundle 解密）：
/// 悬浮在会话区右上角的「状态」面板（absolute top-0 right-4 z-20），不占
/// 消息流。形态两档——mini 胶囊（`max-h-8.5 rounded-2xl bg-popover
/// shadow-md`，迷你值如「{count} 后台」）与展开面板（`w-80
/// max-h-[min(64dvh,32rem)]` 圆角 2xl）。官方 displayMode 有
/// 自动展开/始终收起/始终展开三档；Zemote 取 auto：有活动内容
/// （计划步骤/后台任务）才出现胶囊，无事整个隐藏。
class _StatusSummaryOverlay extends StatefulWidget {
  final ConversationState state;
  final ConversationTransport transport;
  final String sessionId;
  final Object? rpcPlan;
  final VoidCallback onOpenPlan;

  const _StatusSummaryOverlay({
    required this.state,
    required this.transport,
    required this.sessionId,
    required this.rpcPlan,
    required this.onOpenPlan,
  });

  @override
  State<_StatusSummaryOverlay> createState() => _StatusSummaryOverlayState();
}

class _StatusSummaryOverlayState extends State<_StatusSummaryOverlay> {
  Object? _fileData;
  bool _loadingFiles = false;
  bool _expanded = false;
  bool _planExpanded = true;
  bool _filesExpanded = false;
  bool _worksExpanded = false;

  Future<void> _loadFiles() async {
    if (_loadingFiles || widget.sessionId.isEmpty) return;
    setState(() => _loadingFiles = true);
    try {
      final headers = widget.state.rows
          .where((row) => row['kind'] == 'turnHeader')
          .where((row) => row['state'] == 'completedSuccess')
          .toList();
      if (headers.isEmpty) return;
      final row = headers.last;
      final target = <String, dynamic>{
        'rowId': row['rowId'],
        if (row['entityId'] != null) 'entityId': row['entityId'],
      };
      final result = await widget.transport.fileChanges(
        widget.sessionId,
        target: target,
        baseRevision: widget.state.revision,
        baseLogEpoch: widget.state.logEpoch,
      );
      if (mounted) setState(() => _fileData = result);
    } catch (e) {
      if (mounted) setState(() => _fileData = {'error': '$e'});
    } finally {
      if (mounted) setState(() => _loadingFiles = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final steps = derivePlanSteps(
      rows: widget.state.rows,
      snapshotPlan: widget.state.plan ?? widget.rpcPlan,
    );
    final works = widget.state.backgroundWorks;
    final hasPlan = steps?.isNotEmpty ?? false;
    final hasWorks = works.isNotEmpty;
    // auto 策略：无事发生时整个隐藏（旧版常驻卡不再占位）。
    if (!hasPlan && !hasWorks) return const SizedBox.shrink();

    final popover = Theme.of(context).brightness == Brightness.light
        ? ZColors.composerLight
        : ZColors.composerDark;
    final decoration = BoxDecoration(
      color: popover,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: ZInk.panelBorder(context)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.16),
          blurRadius: 14,
          offset: const Offset(0, 4),
        ),
      ],
    );

    Widget child;
    if (!_expanded) {
      // mini 胶囊：官方 max-h-8.5（34px）。
      child = Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(17),
          onTap: () => setState(() => _expanded = true),
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: decoration,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasPlan) ...[
                  const Icon(Icons.account_tree_outlined,
                      size: 13, color: ZColors.primary),
                  const SizedBox(width: 5),
                  Text(
                    '计划 ${steps!.where((s) => s.completed).length}/${steps.length}',
                    style: TextStyle(
                        fontSize: 11.5, color: ZInk.solid(context)),
                  ),
                ],
                if (widget.state.goal != null &&
                    '${widget.state.goal!['objective'] ?? ''}'.isNotEmpty) ...[
                  if (hasPlan || hasWorks) const SizedBox(width: 10),
                  Icon(Icons.flag_outlined,
                      size: 12, color: ZColors.success),
                  const SizedBox(width: 5),
                  Text('目标',
                      style: TextStyle(
                          fontSize: 11.5, color: ZInk.solid(context))),
                ],
                if (hasPlan && hasWorks) const SizedBox(width: 10),
                if (hasWorks) ...[
                  Icon(
                    Icons.pending_actions_outlined,
                    size: 13,
                    color: works.any((w) =>
                            '${w['status'] ?? ''}' == 'running' ||
                            '${w['status'] ?? ''}' == 'in_progress')
                        ? ZColors.running
                        : ZInk.muted(context),
                  ),
                  const SizedBox(width: 5),
                  Text('${works.length} 后台',
                      style: TextStyle(
                          fontSize: 11.5, color: ZInk.solid(context))),
                ],
                const SizedBox(width: 6),
                Icon(Icons.expand_more, size: 14, color: ZInk.faint(context)),
              ],
            ),
          ),
        ),
      );
    }

    // 展开面板：官方 w-80（320px）max-h-[min(64dvh,32rem)] 圆角 2xl。
    final size = MediaQuery.sizeOf(context);
    final done = steps?.where((s) => s.completed).length ?? 0;
    final fileSummary = summarizeFileChanges(_fileData);
    child = Material(
      color: Colors.transparent,
      child: Container(
        width: math.min(320, size.width - 24),
        constraints: BoxConstraints(
          maxHeight: math.min(size.height * 0.64, 512),
        ),
        decoration: decoration,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 整行可点收起（不依赖小图标命中）。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = false),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: Row(
                  children: [
                    Text('状态',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: ZInk.solid(context))),
                    const Spacer(),
                    Icon(Icons.close,
                        size: 16, color: ZInk.muted(context)),
                  ],
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (hasPlan) ...[
                      _sectionRow(
                        context,
                        icon: Icons.account_tree_outlined,
                        iconColor: ZColors.primary,
                        title: '计划',
                        trailing: '$done/${steps!.length}',
                        expanded: _planExpanded,
                        onTap: () =>
                            setState(() => _planExpanded = !_planExpanded),
                      ),
                      if (_planExpanded) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                          child: _PlanSummary(
                            steps: steps,
                            isPlanMode: widget.state.currentMode == 'plan',
                            onOpenRaw: widget.onOpenPlan,
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: widget.onOpenPlan,
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                            ),
                            child: const Text('查看原始数据',
                                style: TextStyle(fontSize: 11)),
                          ),
                        ),
                      ],
                      _divider(context),
                    ],
                    _sectionRow(
                      context,
                      icon: Icons.difference_outlined,
                      iconColor: ZInk.muted(context),
                      title: '文件变更',
                      trailing: fileSummary == null
                          ? '未检查'
                          : '${fileSummary.files} · +${fileSummary.additions} / -${fileSummary.deletions}',
                      loading: _loadingFiles,
                      expanded: _filesExpanded,
                      onTap: () {
                        setState(() => _filesExpanded = !_filesExpanded);
                        if (_filesExpanded && _fileData == null) _loadFiles();
                      },
                    ),
                    if (_filesExpanded)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                        child: _FileSummary(
                          data: _fileData,
                          loading: _loadingFiles,
                          onLoad: _loadFiles,
                        ),
                      ),
                    _divider(context),
                    _sectionRow(
                      context,
                      icon: Icons.pending_actions_outlined,
                      iconColor: hasWorks
                          ? ZColors.running
                          : ZInk.muted(context),
                      title: '后台任务',
                      trailing: '${works.length} 个运行',
                      expanded: _worksExpanded,
                      onTap: () =>
                          setState(() => _worksExpanded = !_worksExpanded),
                    ),
                    if (_worksExpanded)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                        child: _BackgroundWorkList(works: works),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return child;
  }

  Widget _divider(BuildContext context) => Divider(
        height: 1,
        thickness: 0.5,
        indent: 12,
        endIndent: 12,
        color: ZInk.panelBorder(context),
      );

  Widget _sectionRow(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    String? trailing,
    bool loading = false,
    required bool expanded,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            Icon(icon, size: 15, color: iconColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style:
                      TextStyle(fontSize: 12.5, color: ZInk.solid(context))),
            ),
            if (loading)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              )
            else if (trailing != null)
              Text(trailing,
                  style: TextStyle(fontSize: 11, color: ZInk.muted(context))),
            const SizedBox(width: 6),
            AnimatedRotation(
              turns: expanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(Icons.chevron_right,
                  size: 14, color: ZInk.faint(context)),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanSummary extends StatelessWidget {
  final List<PlanStep> steps;
  final bool isPlanMode;
  final VoidCallback onOpenRaw;

  const _PlanSummary({
    required this.steps,
    required this.isPlanMode,
    required this.onOpenRaw,
  });

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty) {
      return Row(
        children: [
          Expanded(
              child: Text(isPlanMode ? '等待计划内容…' : '暂无计划步骤',
                  style: TextStyle(fontSize: 11, color: ZInk.muted(context)))),
          TextButton(onPressed: onOpenRaw, child: const Text('查看原始数据')),
        ],
      );
    }
    final done = steps.where((step) => step.completed).length;
    return Column(
      children: [
        for (final step in steps)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                    step.completed
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 15,
                    color:
                        step.completed ? ZColors.success : ZInk.muted(context)),
                const SizedBox(width: 7),
                Expanded(
                    child: Text(step.content,
                        style: TextStyle(
                            fontSize: 12, color: ZInk.solid(context)))),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: Text('$done/${steps.length} 已完成',
              style: TextStyle(fontSize: 11, color: ZInk.muted(context))),
        ),
      ],
    );
  }
}

class _FileSummary extends StatelessWidget {
  final Object? data;
  final bool loading;
  final VoidCallback onLoad;

  const _FileSummary(
      {required this.data, required this.loading, required this.onLoad});

  @override
  Widget build(BuildContext context) {
    if (loading) return const LinearProgressIndicator(minHeight: 2);
    if (data == null) {
      return Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: onLoad,
          icon: const Icon(Icons.refresh, size: 15),
          label: const Text('加载最近变更'),
        ),
      );
    }
    return StructuredDataView(data: data);
  }
}

class FileChangeSummary {
  final int files;
  final int additions;
  final int deletions;

  const FileChangeSummary({
    required this.files,
    required this.additions,
    required this.deletions,
  });
}

FileChangeSummary? summarizeFileChanges(Object? data) {
  if (data is! Map) return null;
  final files = data['files'] is List
      ? (data['files'] as List).length
      : data['items'] is List
          ? (data['items'] as List).length
          : 0;
  final additions = (data['additions'] as num?)?.toInt() ?? 0;
  final deletions = (data['deletions'] as num?)?.toInt() ?? 0;
  return FileChangeSummary(
      files: files, additions: additions, deletions: deletions);
}

class _BackgroundWorkList extends StatelessWidget {
  final List<Map<String, dynamic>> works;

  const _BackgroundWorkList({required this.works});

  @override
  Widget build(BuildContext context) {
    if (works.isEmpty) {
      return Center(
        child: Text('当前没有后台任务',
            style: TextStyle(fontSize: 12, color: ZInk.muted(context))),
      );
    }
    // 状态面板内嵌在 SingleChildScrollView 里，用 Column 而非 ListView
    // （无界高度会挂掉）。
    return Column(
      children: [
        for (final (index, work) in works.indexed) ...[
          if (index > 0)
            Divider(height: 1, indent: 12, endIndent: 12, color: ZInk.panelBorder(context)),
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            leading: Icon(
                '${work['status'] ?? ''}' == 'running' ||
                        '${work['status'] ?? ''}' == 'in_progress'
                    ? Icons.sync
                    : Icons.task_alt,
                size: 18,
                color: '${work['status'] ?? ''}' == 'running' ||
                        '${work['status'] ?? ''}' == 'in_progress'
                    ? ZColors.running
                    : ZColors.success),
            title: Text('${work['title'] ?? work['kind'] ?? '后台任务'}',
                style: const TextStyle(fontSize: 12.5)),
            subtitle: Text('${work['status'] ?? '运行中'}',
                style: TextStyle(fontSize: 11, color: ZInk.muted(context))),
            trailing: work['progress'] is num
                ? Text('${((work['progress'] as num) * 100).round()}%',
                    style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: ZInk.muted(context)))
                : null,
          ),
        ],
      ],
    );
  }
}

// ignore: unused_element
class _BackgroundWorksBar extends StatelessWidget {
  final ConversationState state;

  const _BackgroundWorksBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final works = state.backgroundWorks
        .where((w) => w['status'] == 'running' && w['endedAt'] == null)
        .toList();
    if (works.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '后台任务 ${works.length} 个运行中: '
              '${works.map((w) => w['title'] ?? w['kind']).join('、')}',
              style: TextStyle(fontSize: 11.5, color: ZInk.soft(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueBar extends StatelessWidget {
  final ConversationState state;
  final ConversationTransport transport;

  const _QueueBar({required this.state, required this.transport});

  @override
  Widget build(BuildContext context) {
    final items = state.queueItems;
    if (items.isEmpty) return const SizedBox.shrink();
    final sessionId = state.snapshot?['sessionId'] as String? ?? '';
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ZColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZColors.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.queue_outlined,
                  size: 14, color: ZColors.primary),
              const SizedBox(width: 6),
              Text('排队消息 ${items.length}',
                  style: const TextStyle(fontSize: 12, color: ZColors.primary)),
              const Spacer(),
              InkWell(
                onTap: () {
                  final next = !state.autoDrain;
                  state.optimisticPatch({
                    'queue': {...?state.queue, 'autoDrain': next},
                  });
                  transport.setAutoDrain(sessionId, next);
                },
                child: Text(
                  state.autoDrain ? '自动发送: 开' : '自动发送: 关',
                  style: TextStyle(fontSize: 11, color: ZInk.muted(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${item['text'] ?? ''}',
                      style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _QueueAction(
                    icon: Icons.play_arrow,
                    tooltip: '立即发送',
                    onTap: () {
                      final id = '${item['queueItemId']}';
                      state.optimisticRemoveQueueItem(id);
                      transport.sendQueuedNow(sessionId, id);
                    },
                  ),
                  _QueueAction(
                    icon: Icons.edit_outlined,
                    tooltip: '编辑',
                    onTap: () => _edit(context, sessionId, item),
                  ),
                  _QueueAction(
                    icon: Icons.close,
                    tooltip: '删除',
                    onTap: () async {
                      final id = '${item['queueItemId']}';
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('删除排队消息？'),
                          content: Text('将删除「${item['text'] ?? ''}」',
                              maxLines: 3, overflow: TextOverflow.ellipsis),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('取消')),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                  backgroundColor: ZColors.danger),
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true) return;
                      state.optimisticRemoveQueueItem(id);
                      transport.deleteQueueItem(sessionId, id);
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(
      BuildContext context, String sessionId, Map<String, dynamic> item) async {
    final controller = TextEditingController(text: '${item['text'] ?? ''}');
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑排队消息'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    // Optimistic text update; server queue patch confirms.
    final q = state.queue;
    if (q != null && q['items'] is List) {
      final items = [
        for (final i in q['items'] as List)
          if (i is Map && '${i['queueItemId']}' == '${item['queueItemId']}')
            {...i, 'text': text}
          else
            i,
      ];
      state.optimisticPatch({
        'queue': {...q, 'items': items},
      });
    }
    await transport.editQueueItem(sessionId, '${item['queueItemId']}', text);
  }
}

class _QueueAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _QueueAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 16, color: ZInk.muted(context)),
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _PendingFilesBar extends StatelessWidget {
  final List<_PendingFile> files;
  final double? uploadProgress;
  final void Function(int index) onRemove;

  const _PendingFilesBar({
    required this.files,
    required this.uploadProgress,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (uploadProgress != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: LinearProgressIndicator(value: uploadProgress),
            ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < files.length; i++)
                Chip(
                  avatar: const Icon(Icons.attach_file, size: 14),
                  label: Text(files[i].fileName,
                      style: const TextStyle(fontSize: 11)),
                  onDeleted: () => onRemove(i),
                  deleteIcon: const Icon(Icons.close, size: 14),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- interactions

class _PendingInteractions extends StatelessWidget {
  final ConversationState state;
  final ConversationTransport transport;

  const _PendingInteractions({required this.state, required this.transport});

  @override
  Widget build(BuildContext context) {
    final interactions = state.pendingInteractions;
    if (interactions.isEmpty) return const SizedBox.shrink();
    final sessionId = state.snapshot?['sessionId'] as String? ?? '';
    return Column(
      children: [
        for (final interaction in interactions)
          _InteractionCard(
            interaction: interaction,
            onResolve: ({optionId, freeText, action, content}) =>
                transport.resolveInteraction(
              sessionId,
              interaction['interactionId'] as String? ?? '',
              optionId: optionId,
              freeText: freeText,
              action: action,
              content: content,
            ),
          ),
      ],
    );
  }
}

class _InteractionCard extends StatefulWidget {
  final Map<String, dynamic> interaction;
  final Future<dynamic> Function({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) onResolve;

  const _InteractionCard({required this.interaction, required this.onResolve});

  @override
  State<_InteractionCard> createState() => _InteractionCardState();
}

class _InteractionCardState extends State<_InteractionCard> {
  final _freeTextController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _freeTextController.dispose();
    super.dispose();
  }

  Future<void> _resolve({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onResolve(
          optionId: optionId,
          freeText: freeText,
          action: action,
          content: content);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = widget.interaction['payload'];
    if (payload is! Map) return const SizedBox.shrink();
    final kind = payload['kind'];
    final options = payload['options'];
    final questions = payload['questions'];
    final freeText = payload['freeText'] == true;

    final title =
        kind == 'permission' ? '需要权限' : '等待你的输入';

    // 官方 elicitation 权限卡（data-elicitation-dialog-card）：实色卡片
    // 16px 圆角 + 发丝边框，内体 12px 间距；选项为竖排全宽按钮行
    // （rounded-xl px-3 py-2，序号 + 标签 + 描述），确认色用绿色系。
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZInk.confirmSurface(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ZInk.messageBorder(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.privacy_tip_outlined,
                  size: 14, color: ZInk.confirmForeground(context)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              if (kind == 'permission' && payload['toolName'] != null)
                Text('${payload['toolName']}',
                    style: TextStyle(
                        fontSize: 11, fontFamily: 'monospace',
                        color: ZInk.muted(context))),
            ],
          ),
          if (kind == 'userInput' &&
              (payload['prompt'] as String? ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${payload['prompt']}',
                  style: TextStyle(fontSize: 12, color: ZInk.soft(context))),
            ),
          if (kind == 'permission' && payload['summary'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${payload['summary']}',
                  style: TextStyle(fontSize: 12, color: ZInk.soft(context))),
            ),
          const SizedBox(height: 8),
          if (options is List && options.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < options.length; i++)
                  if (options[i] is Map)
                    _PermissionOption(
                      index: i,
                      label: _optionLabel(options[i] as Map),
                      description: _optionDescription(options[i] as Map),
                      busy: _busy,
                      onTap: () => kind == 'permission'
                          ? _resolve(
                              optionId: '${(options[i] as Map)['optionId']}')
                          : _resolve(action: 'accept', content: {}),
                    ),
              ],
            ),
          if (questions is List && questions.isNotEmpty)
            _QuestionsView(
              questions: questions.cast<Map>(),
              busy: _busy,
              onResolve: (answers) => _resolve(
                action: 'accept',
                content: {'answers': answers},
              ),
            ),
          if (freeText)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _freeTextController,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '输入回复…',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send, size: 18),
                  onPressed: _busy
                      ? null
                      : () =>
                          _resolve(freeText: _freeTextController.text.trim()),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// Official server-side option labels arrive in English; the web client
  /// maps them to localized text (Pct/Nct tables). Kind fallbacks mirror
  /// jct, descriptions mirror Fct.
  static const _optionLabelByServerText = {
    'allow once': '允许一次',
    'allow': '允许',
    'always allow': '总是允许',
    'deny': '拒绝',
    'allow for session': '允许本会话',
    'allow for this session': '允许本会话',
    'always allow in this project': '始终允许本项目',
    'always allow computer use in this project': '始终允许本项目中的电脑控制',
  };

  static const _optionDescriptionByKind = {
    'allowOnce': '仅允许这一次',
    'allowAlways': '后续相同权限请求不再询问',
    'rejectOnce': '这次先拒绝',
    'rejectAlways': '后续相同权限请求也会直接拒绝',
  };

  String _optionLabel(Map option) {
    final kind = option['kind'] as String?;
    final kindLabel = switch (kind) {
      'allowOnce' => '允许一次',
      'allowAlways' => '总是允许',
      'deny' => '拒绝',
      'custom' => '自定义',
      _ => null,
    };
    final label = option['label'] as String?;
    if (label != null && label.isNotEmpty) {
      final normalized =
          label.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
      return _optionLabelByServerText[normalized] ?? label;
    }
    return kindLabel ?? '${option['optionId'] ?? '选择'}';
  }

  String _optionDescription(Map option) {
    final own = option['description'] as String?;
    if (own != null && own.isNotEmpty) return own;
    final kind = option['kind'] as String?;
    return _optionDescriptionByKind[kind] ?? '';
  }
}

/// Official permission option row (elicitation option button): full-width
/// rounded-xl row with an ordinal, label and optional description.
class _PermissionOption extends StatelessWidget {
  final int index;
  final String label;
  final String description;
  final bool busy;
  final VoidCallback onTap;

  const _PermissionOption({
    required this.index,
    required this.label,
    required this.description,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: busy ? 0.55 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: busy ? null : onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: Text('${index + 1}.',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: ZInk.muted(context))),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: ZInk.confirmForeground(context))),
                      if (description.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(description,
                              style: TextStyle(
                                  fontSize: 11, color: ZInk.muted(context))),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Renders a form-style `userInput` interaction (the `questions` payload):
/// the current question (by `currentQuestionIndex`) with its options.
class _QuestionsView extends StatefulWidget {
  final List<Map> questions;
  final bool busy;
  final void Function(Map<String, List<String>> answers) onResolve;

  const _QuestionsView({
    required this.questions,
    required this.busy,
    required this.onResolve,
  });

  @override
  State<_QuestionsView> createState() => _QuestionsViewState();
}

class _QuestionsViewState extends State<_QuestionsView> {
  final _answers = <String, List<String>>{};

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < widget.questions.length; i++)
          _QuestionItem(
            index: i,
            question: widget.questions[i],
            busy: widget.busy,
            selected:
                _answers['${widget.questions[i]['question']}'] ?? const [],
            onChanged: (selected) => setState(() {
              final key = '${widget.questions[i]['question']}';
              if (selected.isEmpty) {
                _answers.remove(key);
              } else {
                _answers[key] = selected;
              }
            }),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: widget.busy || _answers.isEmpty
                ? null
                : () => widget.onResolve(Map.of(_answers)),
            child: const Text('提交答案', style: TextStyle(fontSize: 12)),
          ),
        ),
      ],
    );
  }
}

class _QuestionItem extends StatefulWidget {
  final int index;
  final Map question;
  final bool busy;
  final List<String> selected;
  final void Function(List<String> selected) onChanged;

  const _QuestionItem({
    required this.index,
    required this.question,
    required this.busy,
    required this.selected,
    required this.onChanged,
  });

  @override
  State<_QuestionItem> createState() => _QuestionItemState();
}

class _QuestionItemState extends State<_QuestionItem> {
  @override
  Widget build(BuildContext context) {
    final q = widget.question;
    final label = q['label'] ?? q['question'] ?? q['value'] ?? '';
    final options = q['options'];
    final multi = q['multiSelect'] == true;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${widget.index + 1}. $label',
              style: const TextStyle(fontSize: 12, height: 1.4)),
          if (q['description'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('${q['description']}',
                  style: TextStyle(fontSize: 11, color: ZInk.faint(context))),
            ),
          if (options is List && options.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final o in options)
                    if (o is Map)
                      FilterChip(
                        label: Text('${o['label'] ?? o['value'] ?? ''}',
                            style: const TextStyle(fontSize: 12)),
                        selected: widget.selected.contains('${o['value']}'),
                        onSelected: widget.busy
                            ? null
                            : (on) {
                                setState(() {
                                  final selected =
                                      List<String>.from(widget.selected);
                                  if (multi) {
                                    if (on) {
                                      selected.add('${o['value']}');
                                    } else {
                                      selected.remove('${o['value']}');
                                    }
                                  } else {
                                    selected
                                      ..clear()
                                      ..add('${o['value']}');
                                  }
                                  widget.onChanged(selected);
                                });
                              },
                      ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- sheets

class _UsageSheet extends StatelessWidget {
  final ConversationState state;
  final BridgeSession session;
  final Map<String, dynamic> scope;
  final String sessionId;

  const _UsageSheet({
    required this.state,
    required this.session,
    required this.scope,
    required this.sessionId,
  });

  @override
  Widget build(BuildContext context) {
    final usage = state.usage ?? const {};
    final cumulative = usage['cumulative'];
    final info = parseContextWindowInfo(usage);
    final colors = usageSegmentColors(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (info != null) ...[
              // 官方用量卡：标题行 + mono 已用/总量(百分比)，下接分段组成条。
              Row(
                children: [
                  const Text('上下文容量',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text(
                    '${formatCompactTokens(info.usedTokens)} / '
                    '${formatCompactTokens(info.maxTokens)} '
                    '(${formatUsagePercent(info.ratio)})',
                    style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: ZInk.muted(context)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('提示词、工具调用和回复都会共享上下文窗口。',
                  style: TextStyle(fontSize: 11, color: ZInk.faint(context))),
              const SizedBox(height: 12),
              if (info.breakdown.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    height: 8,
                    child: Row(
                      children: [
                        for (var i = 0; i < info.breakdown.length; i++)
                          Expanded(
                            flex: info.breakdown[i].chars,
                            child: ColoredBox(
                              color: colors[i.clamp(0, colors.length - 1)],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              for (var i = 0; i < info.breakdown.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: colors[i.clamp(0, colors.length - 1)],
                          borderRadius: BorderRadius.circular(2),
                          border: Border.all(color: ZInk.messageBorder(context)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _contextSourceLabels[info.breakdown[i].source] ??
                            info.breakdown[i].source,
                        style: TextStyle(
                            fontSize: 12, color: ZInk.muted(context)),
                      ),
                      const Spacer(),
                      Text(
                        formatUsagePercent(
                            info.breakdown[i].chars /
                                info.breakdown.fold<int>(
                                    0, (sum, e) => sum + e.chars)),
                        style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            color: ZInk.soft(context)),
                      ),
                    ],
                  ),
                ),
              if (info.cacheHitRate != null) ...[
                const SizedBox(height: 6),
                Divider(height: 1, color: ZInk.messageBorder(context)),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Text('平均缓存命中率',
                          style: TextStyle(
                              fontSize: 12, color: ZInk.muted(context))),
                      const Spacer(),
                      Text(formatUsagePercent(info.cacheHitRate!),
                          style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: ZInk.soft(context))),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
            ],
            if (cumulative is Map) ...[
              _UsageRow('累计输入', '${cumulative['inputTokens'] ?? 0}'),
              _UsageRow('累计输出', '${cumulative['outputTokens'] ?? 0}'),
              _UsageRow('缓存读取', '${cumulative['cacheReadTokens'] ?? 0}'),
              _UsageRow('缓存写入', '${cumulative['cacheWriteTokens'] ?? 0}'),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}

class _UsageRow extends StatelessWidget {
  final String label;
  final String value;

  const _UsageRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(fontSize: 13, color: ZInk.muted(context))),
          Text(value,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

class _StructuredSheet extends StatelessWidget {
  final String title;
  final Object? data;

  const _StructuredSheet({required this.title, required this.data});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(title,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    tooltip: '查看原始数据',
                    icon: const Icon(Icons.data_object, size: 18),
                    onPressed: () => showRawDataDialog(context,
                        title: '$title · 原始数据', data: data),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: StructuredDataView(data: data),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- input

/// One entry in the slash popup: a builtin/custom command or a skill.
class _SlashItem {
  final String name;
  final String description;
  final String insert;
  final bool isSkill;

  const _SlashItem({
    required this.name,
    required this.description,
    required this.insert,
    this.isSkill = false,
  });
}

/// Match score of slash/command [name] against the typed query [q] (both
/// lowercase): 0 = prefix, 1 = at a word boundary (-_./: space), 2 = plain
/// substring, null = no match. Lower is a better match.
int? slashCommandMatchScore(String name, String q) {
  if (q.isEmpty) return 0;
  final prefix = name.indexOf(q);
  if (prefix < 0) return null;
  if (prefix == 0) return 0;
  const boundaries = {'-', '_', '.', '/', ':', ' '};
  if (boundaries.contains(name[prefix - 1])) return 1;
  return 2;
}

class _SlashCommandBar extends StatelessWidget {
  final String query;
  final List<_SlashItem> items;
  final void Function(_SlashItem item) onSelect;

  const _SlashCommandBar({
    required this.query,
    required this.items,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final q = query.startsWith('/') || query.startsWith('\$')
        ? query.substring(1)
        : query;
    // Best matches first: prefix > word-boundary > substring (stable within
    // a score class by name length, then alphabetically).
    final ql = q.toLowerCase();
    final scored = <(_SlashItem, int)>[];
    for (final item in items) {
      final score = slashCommandMatchScore(item.name.toLowerCase(), ql);
      if (score != null) scored.add((item, score));
    }
    scored.sort((a, b) {
      final byScore = a.$2.compareTo(b.$2);
      if (byScore != 0) return byScore;
      final byLen = a.$1.name.length.compareTo(b.$1.name.length);
      if (byLen != 0) return byLen;
      return a.$1.name.compareTo(b.$1.name);
    });
    final filtered = scored.map((s) => s.$1).toList();
    if (filtered.isEmpty) {
      return Container(
        margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('没有匹配的命令',
            style: TextStyle(fontSize: 12, color: ZInk.faint(context))),
      );
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZInk.panelBorder(context)),
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final command in filtered)
            ListTile(
              dense: true,
              leading: Icon(
                command.isSkill
                    ? Icons.auto_awesome_outlined
                    : (command.name == 'compact' ? Icons.compress : Icons.bolt),
                size: 16,
                color: command.isSkill ? ZColors.warning : ZColors.primary,
              ),
              title: Text(
                  command.isSkill ? '\$${command.name}' : '/${command.name}',
                  style:
                      const TextStyle(fontSize: 13, fontFamily: 'monospace')),
              subtitle: Text(
                command.description,
                style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => onSelect(command),
            ),
        ],
      ),
    );
  }
}

class _SkillsPickerSheet extends StatelessWidget {
  final List<SkillEntry> skills;
  final bool loading;
  final void Function(SkillEntry skill) onSelect;
  final Future<void> Function() onRefresh;

  const _SkillsPickerSheet({
    required this.skills,
    required this.loading,
    required this.onSelect,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final list = skills.where((s) => s.enabled).toList();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('选择 Skills',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  icon:
                      Icon(Icons.refresh, size: 18, color: ZInk.muted(context)),
                  tooltip: '刷新',
                  onPressed: onRefresh,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('没有可用的 Skills',
                    style: TextStyle(fontSize: 13, color: ZInk.muted(context))),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in list)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.auto_awesome_outlined,
                            size: 18, color: ZColors.warning),
                        title: Text('\$${s.name}',
                            style: const TextStyle(
                                fontSize: 14, fontFamily: 'monospace')),
                        subtitle: s.description != null
                            ? Text(s.description!,
                                style: TextStyle(
                                    fontSize: 12, color: ZInk.faint(context)),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis)
                            : null,
                        onTap: () => onSelect(s),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final bool sending;
  final bool voiceAvailable;
  final bool voiceRecording;
  final bool voiceWorking;
  final bool running;
  final VoidCallback? onStop;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onSkills;
  final VoidCallback onVoice;

  /// Inline config dropdowns built by [_ChatPageState] (official-web style:
  /// mode / model / thought live INSIDE the composer toolbar). The usage
  /// ring sits left of the model chip like the official chat toolbar.
  /// Chips are built with the TOOLBAR's measured width — the official
  /// breakpoints are container queries on the composer, not viewport
  /// queries, so a tablet master-detail chat pane uses narrow forms even
  /// though the screen is wide.
  final Widget Function(double composerWidth) modeChip;
  final Widget Function(double composerWidth) modelChip;
  final Widget Function(double composerWidth) thoughtChip;
  final Widget usageRing;

  /// 辅助会话完全隔离：不显示模式/模型/思考配置入口（切换会影响主会话）。
  final bool isSideChat;

  const _InputBar({
    required this.controller,
    required this.sending,
    required this.running,
    this.onStop,
    required this.voiceAvailable,
    required this.voiceRecording,
    required this.voiceWorking,
    required this.onSend,
    required this.onAttach,
    required this.onSkills,
    required this.onVoice,
    required this.modeChip,
    required this.modelChip,
    required this.thoughtChip,
    required this.usageRing,
    required this.isSideChat,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
        child: Container(
          // Official web composer parity: 16px radius container with a
          // hairline border; dark #2B2B2B / light white surface.
          decoration: BoxDecoration(
            color:
                isLight ? ZColors.composerLight : ZColors.composerDark,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: ZInk.hairline(context)),
          ),
          padding: const EdgeInsets.fromLTRB(4, 2, 8, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: widget.controller,
                      minLines: 1,
                      maxLines: 5,
                      style: const TextStyle(fontSize: 14),
                      // filled:false — the global input theme paints fields
                      // with the surface color, which visually split the
                      // text area from the toolbar sharing this container.
                      decoration: InputDecoration(
                        hintText: '向 ZCode 发送消息…',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 12),
                      ),
                      textInputAction: TextInputAction.newline,
                    ),
                  ),
                  if (widget.voiceAvailable)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: widget.voiceWorking
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2),
                            )
                          : Icon(
                              widget.voiceRecording
                                  ? Icons.stop_circle
                                  : Icons.mic,
                              size: 16,
                              color: widget.voiceRecording
                                  ? ZColors.danger
                                  : ZInk.muted(context),
                            ),
                      tooltip: widget.voiceRecording ? '停止录音' : '语音输入',
                      onPressed: widget.sending || widget.voiceWorking
                          ? null
                          : widget.onVoice,
                    ),
                ],
              ),
              // 断点数据源 = 工具条实际约束宽（官方 @container
              // composer/inline-size 的等价物），而不是视口宽。
              LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  return Row(
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: LucideIcon('plus',
                            size: 16, color: ZInk.muted(context)),
                        tooltip: '更多操作',
                        onPressed:
                            widget.sending ? null : () => _showActions(context),
                      ),
                      const SizedBox(width: 2),
                      widget.modeChip(w),
                      const Spacer(),
                      widget.usageRing,
                      const SizedBox(width: 6),
                      widget.modelChip(w),
                      const SizedBox(width: 6),
                      widget.thoughtChip(w),
                      const SizedBox(width: 4),
                      _SendButton(
                        sending: widget.sending,
                        running: widget.running,
                        onSend: widget.onSend,
                        onStop: widget.onStop,
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }


  /// 在光标处插入官方触发符（@ / /），前一位非空白时补一个空格，
  /// 满足官方「行首或空白后触发」的规则；插入后由 controller 监听器
  /// 唤起对应菜单。
  void _insertTrigger(String trigger) {
    final ctrl = widget.controller;
    final text = ctrl.text;
    var pos = ctrl.selection.baseOffset;
    if (pos < 0 || pos > text.length) pos = text.length;
    final needsSpace =
        pos > 0 && text[pos - 1] != ' ' && text.codeUnitAt(pos - 1) != 10;
    final inserted = (needsSpace ? ' ' : '') + trigger;
    ctrl.value = TextEditingValue(
      text: text.substring(0, pos) + inserted + text.substring(pos),
      selection: TextSelection.collapsed(offset: pos + inserted.length),
    );
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('更多操作',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  // 官方加号菜单（He 官方截图对照）：附件 / @ 上下文 /
                  // / 能力 / $ 技能 四项，横向依次排开。
                  _ActionItem(
                    icon: Icons.attach_file,
                    label: '添加附件',
                    onTap: () {
                      Navigator.pop(context);
                      widget.onAttach();
                    },
                  ),
                  _ActionItem(
                    icon: Icons.alternate_email,
                    label: '使用 @ 添加上下文',
                    onTap: () {
                      Navigator.pop(context);
                      _insertTrigger('@');
                    },
                  ),
                  _ActionItem(
                    icon: Icons.terminal,
                    label: '使用 / 选择能力',
                    onTap: () {
                      Navigator.pop(context);
                      _insertTrigger('/');
                    },
                  ),
                  _ActionItem(
                    icon: Icons.auto_awesome_outlined,
                    label: '使用 \$ 选择技能',
                    onTap: () {
                      Navigator.pop(context);
                      widget.onSkills();
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Composer send button — official web style: a solid circle in the ink
/// color (dark theme: white circle / dark arrow; light: near-black circle /
/// white arrow), fading when disabled.
class _SendButton extends StatelessWidget {
  final bool sending;

  /// 任务运行中：同款圆形按钮变为官方停止形态（内部实心方块）。
  final bool running;
  final VoidCallback onSend;
  final VoidCallback? onStop;

  const _SendButton({
    required this.sending,
    required this.onSend,
    this.running = false,
    this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final ink = ZInk.solid(context);
    return Opacity(
      opacity: sending ? 0.45 : 1,
      child: Material(
        color: ink,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: sending
              ? null
              : running
                  ? onStop
                  : onSend,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child: sending
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: ZInk.solid(context) == Colors.white
                            ? Colors.black
                            : Colors.white,
                      ),
                    )
                  : LucideIcon('arrow-up',
                      size: 16,
                      color: ZInk.solid(context) == Colors.white
                          ? Colors.black
                          : Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 82,
          child: Column(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: ZColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: ZColors.primary, size: 25),
              ),
              const SizedBox(height: 7),
              Text(label,
                  style: const TextStyle(fontSize: 12),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}
