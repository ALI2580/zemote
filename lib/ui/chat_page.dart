import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../protocol/channel_client.dart';
import '../protocol/conversation.dart';
import '../protocol/zemote_client.dart';
import '../state/log_store.dart';
import 'composer_menu.dart';
import 'diff_view.dart';
import 'markdown_view.dart';
import 'mention_menu.dart';
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

/// Chat view for one task (session), backed by Conversation V4 subscription.
/// Draft mode (no [sessionId]): the first message issues `createSession`.
class ChatPage extends StatefulWidget {
  final BridgeSession session;
  final Map<String, dynamic> scope;
  final String workspaceKey;
  final String? sessionId;
  final String title;

  const ChatPage({
    super.key,
    required this.session,
    required this.scope,
    required this.workspaceKey,
    this.sessionId,
    required this.title,
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
  if (desktopDescription != null && desktopDescription.isNotEmpty) {
    return desktopDescription;
  }
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
      final res = await _transport.rowsRange(
        sessionId,
        beforeRowId: state.oldestRowId,
        limit: 60,
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
      if (rows != null && rows.isNotEmpty) {
        final older = rows
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList()
          ..sort((a, b) =>
              ((a['rowId'] as num?) ?? 0).compareTo((b['rowId'] as num?) ?? 0));
        state.prependOlderRows(older, firstRowId);
        if (hasMore == false) state.historyExhausted = true;
        // Prepending shifts the content above; keep the newest message in
        // view when the user is pinned to the bottom.
        if (_stickToBottom) _scrollToBottom();
      } else if (state.rows.isNotEmpty) {
        if (hasMore == false) state.historyExhausted = true;
        _toast('没有更早的消息了');
      }
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

  /// Shared apply path for the inline composer dropdowns (no sheet to pop).
  Future<bool> _applyConfig(Future<dynamic> Function() run,
      {void Function()? onAccepted}) async {
    try {
      final res = await run();
      if (res is Map && res['status'] != null && res['status'] != 'accepted') {
        _toast('被拒绝: ${res['reasonCode'] ?? res['status']}');
        return false;
      }
      onAccepted?.call();
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

  Widget _buildModeChip() {
    final isFull = _currentModeValue == 'yolo' ||
        _currentModeValue.toLowerCase() == 'fullaccess';
    return ComposerChip(
      icon: isFull ? Icons.gpp_maybe : Icons.shield_outlined,
      label: _currentModeLabel,
      labelColor: isFull ? _fullAccessInkFor(context) : null,
      tooltip: '协作模式',
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

  Widget _buildModelChip() {
    final option = _modelOption;
    final available = option != null && option.options.isNotEmpty;
    return ComposerChip(
      icon: Icons.radio_button_checked_outlined,
      label: available || _currentModelLabel.isNotEmpty
          ? _currentModelLabel
          : '模型',
      enabled: available,
      tooltip: '模型',
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

  Widget _buildThoughtChip() {
    final entries = _thoughtMenuEntries();
    return ComposerChip(
      icon: Icons.psychology_outlined,
      label: _currentThoughtLabel,
      enabled: entries.isNotEmpty,
      tooltip: '思考强度',
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

  // ------------------------------------------------------------ sheets

  void _showModelSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ModelModeSheet(
        state: _state,
        transport: _transport,
        prep: _prep,
        sessionId: _sessionId,
        draftConfig: _draftConfig,
        onDraftChange: (key, value) {
          setState(() => _draftConfig[key] = value);
        },
      ),
    );
  }

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

  void _showUsageSheet() {
    final state = _state;
    final sessionId = _sessionId;
    if (state == null || sessionId == null) return;
    showModalBottomSheet(
      context: context,
      builder: (context) => _UsageSheet(
        state: state,
        session: widget.session,
        scope: widget.scope,
        sessionId: sessionId,
      ),
    );
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
                    if (state.phase.isNotEmpty) state.phase,
                    state.currentModel,
                    if (state.currentThought.isNotEmpty) state.currentThought,
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
                ),
              ),
          ],
        ),
        actions: [
          if (state != null)
            AnimatedBuilder(
              animation: state,
              builder: (context, _) => state.isRunning
                  ? IconButton(
                      icon: const Icon(Icons.stop_circle_outlined,
                          color: ZColors.danger),
                      tooltip: '停止',
                      onPressed: () =>
                          _run('停止失败', () => _transport.stop(_sessionId!)),
                    )
                  : const SizedBox.shrink(),
            ),
          if (_sessionId != null)
            IconButton(
              icon: const Icon(Icons.quickreply_outlined, size: 20),
              tooltip: '辅助对话',
              onPressed: _openSideChat,
            ),
          IconButton(
            icon: const Icon(Icons.tune, size: 20),
            tooltip: '模型 / 模式',
            onPressed: _showModelSheet,
          ),
          if (state != null)
            PopupMenuButton<String>(
              onSelected: (action) {
                switch (action) {
                  case 'compact':
                    _run('压缩失败', () => _transport.compact(_sessionId!));
                  case 'usage':
                    _showUsageSheet();
                  case 'plans':
                    _showPlansSheet();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'compact', child: Text('压缩上下文 (compact)')),
                PopupMenuItem(value: 'usage', child: Text('用量统计')),
                PopupMenuItem(value: 'plans', child: Text('计划')),
              ],
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
          if (state != null)
            AnimatedBuilder(
              animation: state,
              builder: (context, _) => _ContextUsageBar(state: state),
            ),
          Expanded(
            child: state == null
                ? Center(
                    child: _sessionId == null
                        ? Text('输入消息开始新会话',
                            style: TextStyle(color: ZInk.faint(context)))
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
                              return _TurnGroupWidget(
                                rows: group,
                                transport: _transport,
                                sessionId: _sessionId ?? '',
                                onAction: _run,
                                state: state,
                              );
                            },
                          );
                        },
                      ),
          ),
          _ReconnectBanner(bridge: _transport.session),
          if (state != null)
            AnimatedBuilder(
              animation: state,
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _GoalBanner(state: state),
                  _ActiveExecutionBar(state: state),
                  _ConversationInsights(
                    state: state,
                    transport: _transport,
                    sessionId: _sessionId ?? '',
                    rpcPlan: _planData,
                    onOpenPlan: _showPlansSheet,
                  ),
                  _QueueBar(state: state, transport: _transport),
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
            voiceAvailable: _voiceAvailable,
            voiceRecording: _voiceRecording,
            voiceWorking: _voiceWorking,
            onSend: _send,
            onAttach: _pickFiles,
            onSkills: _openSkillsPicker,
            onVoice: _toggleVoiceInput,
            modeChip: _buildModeChip(),
            modelChip: _buildModelChip(),
            thoughtChip: _buildThoughtChip(),
            onMoreSettings: _showModelSheet,
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

  const _TurnGroupWidget({
    required this.rows,
    required this.transport,
    required this.sessionId,
    required this.onAction,
    required this.state,
  });

  @override
  Widget build(BuildContext context) {
    // single timeline marker
    if (rows.length == 1 && rows.first['kind'] == 'timelineMarker') {
      return _TimelineMarkerWidget(row: rows.first);
    }
    final first = rows.first;
    if (first['kind'] == 'userInput') {
      // user message + anything attached to the same turn
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RowWidget(
            row: first,
            transport: transport,
            sessionId: sessionId,
            onAction: onAction,
            state: state,
          ),
          for (final row in rows.skip(1))
            _RowWidget(
              row: row,
              transport: transport,
              sessionId: sessionId,
              onAction: onAction,
              state: state,
            ),
        ],
      );
    }
    // assistant turn: render parts in original order (reasoning → text →
    // tool → text …); feedback buttons appear only on the LAST text segment.
    final parts = assistantTurnParts(rows);
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
          showFeedback: i == lastTextIdx,
          transport: transport,
          sessionId: sessionId,
          onAction: onAction,
          state: state,
        ));
      } else if (_isExecutionRow(p.row!)) {
        final executionRows = <Map<String, dynamic>>[p.row!];
        while (i + 1 < parts.parts.length &&
            parts.parts[i + 1].kind == 'row' &&
            _isExecutionRow(parts.parts[i + 1].row!)) {
          executionRows.add(parts.parts[++i].row!);
        }
        children.add(_ExecutionTrace(
          rows: executionRows,
          transport: transport,
          sessionId: sessionId,
          onAction: onAction,
          state: state,
        ));
      } else {
        children.add(_RowWidget(
          row: p.row!,
          showFeedback: false,
          transport: transport,
          sessionId: sessionId,
          onAction: onAction,
          state: state,
        ));
      }
    }
    final header = parts.header;
    if (header != null) children.add(_TurnHeader(row: header));
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
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

class _ExecutionTrace extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final ConversationTransport transport;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;

  const _ExecutionTrace({
    required this.rows,
    required this.transport,
    required this.sessionId,
    required this.onAction,
    required this.state,
  });

  bool get _running => rows
      .any((row) => row['status'] == 'running' || row['state'] == 'streaming');

  bool get _failed =>
      rows.any((row) => row['status'] == 'error' || row['status'] == 'failed');

  @override
  Widget build(BuildContext context) {
    final color = _running
        ? ZColors.running
        : _failed
            ? ZColors.danger
            : ZInk.muted(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: ZInk.panel(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZInk.panelBorder(context)),
      ),
      child: ExpansionTile(
        initiallyExpanded: _running,
        dense: true,
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 11),
        leading: Icon(
          _running
              ? Icons.sync
              : _failed
                  ? Icons.error_outline
                  : Icons.account_tree_outlined,
          size: 16,
          color: color,
        ),
        title: Text(compactExecutionLabel(rows),
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: ZInk.solid(context))),
        subtitle: Text('点击查看执行详情',
            style: TextStyle(fontSize: 10.5, color: ZInk.faint(context))),
        children: [
          for (final row in rows)
            _RowWidget(
              row: row,
              showFeedback: false,
              transport: transport,
              sessionId: sessionId,
              onAction: onAction,
              state: state,
            ),
        ],
      ),
    );
  }
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

  const _RowWidget({
    required this.row,
    required this.transport,
    required this.sessionId,
    required this.onAction,
    required this.state,
    this.showFeedback = true,
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
            if (kind == 'userInput')
              ListTile(
                leading: const Icon(Icons.edit_outlined, size: 20),
                title: const Text('编辑并重发'),
                onTap: () {
                  Navigator.pop(context);
                  _editQuery(context);
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

  Future<void> _editQuery(BuildContext context) async {
    final controller =
        TextEditingController(text: row['text'] as String? ?? '');
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑消息'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('重发')),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    await onAction(
        '编辑失败', () => transport.editUserQuery(sessionId, _target, text));
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
      'subagent' => _SubagentTile(row: row),
      'timelineMarker' => _TimelineMarkerWidget(row: row),
      _ => const SizedBox.shrink(),
    };
    final kind = row['kind'];
    if (kind != 'userInput' && kind != 'assistantText') return widget_;
    return GestureDetector(
      onLongPress: () => _showActions(context),
      child: widget_,
    );
  }
}

class _UserBubble extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final text = row['text'] as String? ?? '';
    final attachments = row['attachments'];
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        // Official user bubble (`data-v4-user-input-bubble`): 12px radius
        // with a 2px top-right corner, surface fill + 10% hairline, 16/12
        // padding, max-w-xl (576px).
        constraints: const BoxConstraints(maxWidth: 576),
        margin: const EdgeInsets.only(left: 56, top: 4, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: ZInk.messageSurface(context),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(2),
            bottomLeft: Radius.circular(12),
            bottomRight: Radius.circular(12),
          ),
          border: Border.all(color: ZInk.messageBorder(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (attachments is List)
              for (final a in attachments)
                if (a is Map)
                  _AttachmentView(
                    attachment: a.cast<String, dynamic>(),
                    transport: transport,
                    sessionId: sessionId,
                  ),
            if (text.isNotEmpty)
              SelectableText(text,
                  style: TextStyle(
                      fontSize: 14, height: 1.5, color: ZInk.solid(context))),
            if (badge != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(badge!,
                      style:
                          TextStyle(fontSize: 10, color: ZInk.faint(context))),
                  if (onRetry != null)
                    TextButton(
                      onPressed: onRetry,
                      style: TextButton.styleFrom(
                          padding: const EdgeInsets.only(left: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      child: const Text('重试', style: TextStyle(fontSize: 10)),
                    ),
                ],
              ),
          ],
        ),
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
                    icon: Icons.thumb_up_alt_outlined,
                    active: feedback == 'like',
                    onTap: () =>
                        _setFeedback(feedback == 'like' ? null : 'like'),
                  ),
                  _FeedbackButton(
                    icon: Icons.thumb_down_alt_outlined,
                    active: feedback == 'dislike',
                    onTap: () =>
                        _setFeedback(feedback == 'dislike' ? null : 'dislike'),
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
  final bool active;
  final VoidCallback onTap;

  const _FeedbackButton({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon,
          size: 15, color: active ? ZColors.primary : ZInk.ghost(context)),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
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

  @override
  void initState() {
    super.initState();
    _expanded = widget.streaming;
  }

  @override
  void didUpdateWidget(_ReasoningTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.streaming && !oldWidget.streaming) _expanded = true;
  }

  @override
  Widget build(BuildContext context) {
    // 官方思考块（浅色实测）：无底色无框的一行灰字「图标 思考 · 时长」，
    // 展开后内容挂在浅灰左竖线下。
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.psychology_outlined,
                      size: 14,
                      color: widget.streaming
                          ? ZColors.running
                          : ZInk.faint(context)),
                  const SizedBox(width: 7),
                  Text(
                    widget.streaming ? '思考中…' : '思考',
                    style: TextStyle(
                        fontSize: 13, color: ZInk.muted(context)),
                  ),
                  if (!widget.streaming) ...[
                    const SizedBox(width: 7),
                    Text('·',
                        style: TextStyle(
                            fontSize: 12, color: ZInk.faint(context))),
                    const SizedBox(width: 7),
                    Text('持续了几秒',
                        style: TextStyle(
                            fontSize: 13, color: ZInk.muted(context))),
                  ],
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(Icons.expand_more,
                        size: 15, color: ZInk.faint(context)),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 8),
              child: Container(
                padding: const EdgeInsets.only(left: 10),
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                        width: 2, color: ZInk.messageBorder(context)),
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

  @override
  void initState() {
    super.initState();
    // 官方行为：运行中/等待确认的工具默认展开详情。
    final status = widget.row['status'] as String? ?? '';
    _expanded = status == 'running' ||
        status == 'inputStreaming' ||
        status == 'pendingApproval';
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
  };

  /// Per-family icons like the official web client (terminal / magnifier /
  /// pencil in the real rendering).
  static const _kindIcons = {
    'Read': Icons.search,
    'Grep': Icons.search,
    'WebSearch': Icons.travel_explore,
    'WebFetch': Icons.language,
    'Write': Icons.edit_outlined,
    'Edit': Icons.edit_outlined,
    'MultiEdit': Icons.edit_outlined,
    'NotebookEdit': Icons.edit_outlined,
    'Bash': Icons.terminal,
    'Glob': Icons.folder_open,
    'TodoWrite': Icons.checklist,
    'Task': Icons.account_tree_outlined,
  };

  String get _kindLabel {
    final toolName = widget.row['toolName'] as String? ?? '';
    return _kindLabels[toolName] ?? toolName;
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
        'pattern', 'url', 'query', 'description']) {
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
      _ => null,
    };
    final color = switch (status) {
      'running' || 'inputStreaming' => ZColors.running,
      'pendingApproval' => ZColors.warning,
      'pending' => ZInk.faint(context),
      'error' || 'failed' => ZColors.danger,
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
    final kindIcon = _kindIcons[toolName] ?? Icons.build_outlined;

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
    // 点击展开左竖线详情。
    final header = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(kindIcon,
              size: 14,
              color: running ? ZColors.running : ZInk.faint(context)),
          const SizedBox(width: 7),
          Text(
            _kindLabel,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: running ? ZColors.running : ZInk.muted(context),
            ),
          ),
          if (primary.isNotEmpty) ...[
            const SizedBox(width: 7),
            Text('·', style: TextStyle(fontSize: 12, color: ZInk.faint(context))),
            const SizedBox(width: 7),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      primary,
                      style: TextStyle(fontSize: 13, color: ZInk.muted(context)),
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
                ],
              ),
            ),
          ] else
            const Spacer(),
          if (statusLabel != null)
            Padding(
              padding: const EdgeInsets.only(left: 7),
              child: Text(statusLabel,
                  style: TextStyle(fontSize: 12, color: statusColor)),
            ),
          if (hasDetails && _expanded)
            Padding(
              padding: const EdgeInsets.only(left: 5),
              child: Icon(Icons.expand_less,
                  size: 15, color: ZInk.faint(context)),
            ),
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
            onTap: hasDetails ? () => setState(() => _expanded = !_expanded) : null,
            child: header,
          ),
          if (_expanded && hasDetails)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 8),
              child: Container(
                padding: const EdgeInsets.only(left: 10),
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                        width: 2, color: ZInk.messageBorder(context)),
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
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: ZInk.codeBlockBg(context),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                value.length > 4000 ? '${value.substring(0, 4000)}…' : value,
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: ZInk.solid(context)),
              ),
            ),
        ],
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

  String _fmtDuration(int? ms) {
    if (ms == null) return '';
    if (ms < 1000) return '${ms}ms';
    final totalSeconds = (ms / 1000).round();
    if (totalSeconds < 60) return '${(ms / 1000).toStringAsFixed(1)}s';
    final m = totalSeconds ~/ 60;
    return '${m}m${totalSeconds % 60}s';
  }

  @override
  Widget build(BuildContext context) {
    final state = row['state'] as String? ?? '';
    final fileChanges = row['fileChanges'];
    final duration = _fmtDuration((row['activeMs'] as num?)?.toInt());

    String stats = '';
    if (fileChanges is Map) {
      final adds = fileChanges['additions'];
      final dels = fileChanges['deletions'];
      final files = fileChanges['files'];
      final parts = <String>[
        if (adds is num && adds > 0) '+$adds',
        if (dels is num && dels > 0) '-$dels',
        if (files is num && files > 0) '$files 文件',
      ];
      stats = parts.join(' ');
    }

    final label = switch (state) {
      'running' => '本轮执行中',
      'completedSuccess' => [
          '本轮完成',
          if (duration.isNotEmpty) duration,
        ].join(' · '),
      'completedInterrupted' => '已中断',
      'failed' => '本轮失败',
      _ => '',
    };
    if (label.isEmpty) return const SizedBox.shrink();
    final color = switch (state) {
      'running' => ZColors.running,
      'failed' => ZColors.danger,
      'completedInterrupted' => ZColors.warning,
      _ => ZInk.muted(context),
    };
    // 官方 turnHeader（Jat）：左对齐 subtle 小字 + 底部发丝分隔线。
    return Container(
      margin: const EdgeInsets.only(top: 10, bottom: 6),
      padding: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(color: ZInk.messageBorder(context))),
      ),
      child: Row(
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: color)),
          if (stats.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(stats, style: TextStyle(fontSize: 12, color: ZInk.faint(context))),
          ],
        ],
      ),
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
          const Icon(Icons.smart_toy_outlined,
              size: 13, color: ZColors.trajectoryAssistant),
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

class _ContextUsageBar extends StatelessWidget {
  final ConversationState state;

  const _ContextUsageBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final usage = state.usage;
    final window = usage?['contextWindow'];
    if (window is! Map) return const SizedBox.shrink();
    final used = (window['usedTokens'] as num?)?.toInt();
    final max = (window['maxTokens'] as num?)?.toInt();
    if (used == null || max == null || max <= 0) {
      return const SizedBox.shrink();
    }
    final ratio = (used / max).clamp(0.0, 1.0);
    final color = ratio > 0.8 ? ZColors.warning : ZColors.primary;
    String fmt(int v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : '$v';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 4,
                backgroundColor: ZInk.tile(context),
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${fmt(used)}/${fmt(max)}',
            style: TextStyle(fontSize: 10, color: color),
          ),
        ],
      ),
    );
  }
}

class _GoalBanner extends StatelessWidget {
  final ConversationState state;

  const _GoalBanner({required this.state});

  @override
  Widget build(BuildContext context) {
    final goal = state.goal;
    if (goal == null) return const SizedBox.shrink();
    final objective = '${goal['objective'] ?? ''}';
    if (objective.isEmpty) return const SizedBox.shrink();
    final status = '${goal['status'] ?? ''}';
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
          Expanded(
            child: Text(
              objective,
              style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (status.isNotEmpty)
            Text(status,
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

class _ConversationInsights extends StatefulWidget {
  final ConversationState state;
  final ConversationTransport transport;
  final String sessionId;
  final Object? rpcPlan;
  final VoidCallback onOpenPlan;

  const _ConversationInsights({
    required this.state,
    required this.transport,
    required this.sessionId,
    required this.rpcPlan,
    required this.onOpenPlan,
  });

  @override
  State<_ConversationInsights> createState() => _ConversationInsightsState();
}

class _ConversationInsightsState extends State<_ConversationInsights> {
  Object? _fileData;
  bool _loadingFiles = false;

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
    final hasPlan = (steps?.isNotEmpty ?? false) ||
        widget.state.currentMode == 'plan' ||
        widget.rpcPlan != null;
    final fileSummary = summarizeFileChanges(_fileData);
    final completed = steps?.where((step) => step.completed).length ?? 0;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 5, 14, 4),
      padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
      decoration: BoxDecoration(
        color: ZInk.panel(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZInk.panelBorder(context)),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: ZColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(Icons.dashboard_customize_outlined,
                size: 17, color: ZColors.primary),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('会话工作台',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: ZInk.solid(context))),
                const SizedBox(height: 2),
                Text(
                  [
                    hasPlan ? '计划 $completed/${steps?.length ?? 0}' : '暂无计划',
                    fileSummary == null
                        ? '文件未检查'
                        : '文件 ${fileSummary.files} · +${fileSummary.additions} / -${fileSummary.deletions}',
                    works.isEmpty ? '无后台任务' : '${works.length} 个后台任务',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: ZInk.muted(context)),
                ),
              ],
            ),
          ),
          _WorkbenchAction(
            tooltip: '计划',
            icon: Icons.account_tree_outlined,
            active: hasPlan,
            badge: steps?.isNotEmpty == true ? '${steps!.length}' : null,
            onTap: () => _openWorkbench(context, 0, steps ?? const [], works),
          ),
          _WorkbenchAction(
            tooltip: '文件变更',
            icon: Icons.difference_outlined,
            active: fileSummary != null && fileSummary.files > 0,
            loading: _loadingFiles,
            badge: fileSummary == null ? null : '${fileSummary.files}',
            onTap: () => _openFiles(context, steps ?? const [], works),
          ),
          _WorkbenchAction(
            tooltip: '后台任务',
            icon: Icons.pending_actions_outlined,
            active: works.isNotEmpty,
            badge: works.isEmpty ? null : '${works.length}',
            onTap: () => _openWorkbench(context, 2, steps ?? const [], works),
          ),
        ],
      ),
    );
  }

  Future<void> _openFiles(BuildContext context, List<PlanStep> steps,
      List<Map<String, dynamic>> works) async {
    if (_fileData == null) await _loadFiles();
    if (context.mounted) _openWorkbench(context, 1, steps, works);
  }

  void _openWorkbench(BuildContext context, int index, List<PlanStep> steps,
      List<Map<String, dynamic>> works) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DefaultTabController(
        length: 3,
        initialIndex: index,
        child: FractionallySizedBox(
          heightFactor: 0.72,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('会话工作台',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: '计划'),
                  Tab(text: '文件'),
                  Tab(text: '后台任务'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: _PlanSummary(
                        steps: steps,
                        isPlanMode: widget.state.currentMode == 'plan',
                        onOpenRaw: widget.onOpenPlan,
                      ),
                    ),
                    SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: _FileSummary(
                        data: _fileData,
                        loading: _loadingFiles,
                        onLoad: () async {
                          Navigator.pop(context);
                          await _openFiles(this.context, steps, works);
                        },
                      ),
                    ),
                    _BackgroundWorkList(works: works),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkbenchAction extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final bool active;
  final bool loading;
  final String? badge;
  final VoidCallback onTap;

  const _WorkbenchAction({
    required this.tooltip,
    required this.icon,
    required this.active,
    required this.onTap,
    this.loading = false,
    this.badge,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: onTap,
              icon: loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 1.7),
                    )
                  : Icon(icon,
                      size: 19,
                      color: active ? ZColors.primary : ZInk.muted(context)),
            ),
            if (badge != null)
              Positioned(
                right: 2,
                top: 1,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: active ? ZColors.primary : ZInk.faint(context),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(badge!,
                      style: const TextStyle(fontSize: 8, color: Colors.white)),
                ),
              ),
          ],
        ),
      );
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
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: works.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final work = works[index];
        final status = '${work['status'] ?? '运行中'}';
        final running = status == 'running' || status == 'in_progress';
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(running ? Icons.sync : Icons.task_alt,
              size: 19, color: running ? ZColors.primary : ZColors.success),
          title: Text('${work['title'] ?? work['kind'] ?? '后台任务'}',
              style: const TextStyle(fontSize: 13)),
          subtitle: Text(status,
              style: TextStyle(fontSize: 11, color: ZInk.muted(context))),
          trailing: work['progress'] is num
              ? Text('${((work['progress'] as num) * 100).round()}%',
                  style: TextStyle(fontSize: 11, color: ZInk.muted(context)))
              : null,
        );
      },
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

class _ModelModeSheet extends StatelessWidget {
  final ConversationState? state;
  final ConversationTransport transport;
  final WorkspacePrep? prep;
  final String? sessionId;
  final Map<String, String>? draftConfig;
  final void Function(String key, String value)? onDraftChange;

  const _ModelModeSheet({
    required this.state,
    required this.transport,
    this.prep,
    this.sessionId,
    this.draftConfig,
    this.onDraftChange,
  });

  bool get _isDraft => sessionId == null || sessionId!.isEmpty;

  /// Config options beyond the model/mode/thought selects (e.g. max output
  /// length, search enhancement) surfaced read-only from prepareWorkspace.
  List<ConfigOption> get _otherOptions {
    const known = {'model', 'mode', 'thought_level'};
    final options = prep?.configOptions;
    if (options == null) return const [];
    return options.where((o) => !known.contains(o.id)).toList();
  }

  /// 'builtin:zai-coding-plan/GLM-5.2' → (provider, model)
  (String, String) _splitModelValue(String value) {
    final idx = value.lastIndexOf('/');
    if (idx <= 0) return (value, value);
    return (value.substring(0, idx), value.substring(idx + 1));
  }

  // ------------------------------------------------------- mode presentation

  static const _modeLabels = {
    'build': '构建',
    'edit': '编辑',
    'plan': '计划',
    'yolo': 'Full Access',
  };

  static const _modeDescriptions = {
    'build': '标准协作：读写文件、执行命令、完成任务',
    'edit': '聚焦编辑：专注修改文件，能力范围更可控',
    'plan': '只读规划：先讨论和制定计划，不动代码',
    'yolo': '完全访问：自动批准全部操作，无需逐项确认',
  };

  static bool _isFullAccessMode(String value) =>
      value == 'yolo' || value.toLowerCase() == 'fullaccess';

  static String _modeLabelOf(String value, {required String fallbackName}) {
    final mapped = _modeLabels[value.trim().toLowerCase()];
    return mapped ?? (fallbackName.isNotEmpty ? fallbackName : value);
  }

  static String? _modeDescriptionOf(String value, String? desktopDescription) {
    if (desktopDescription != null && desktopDescription.isNotEmpty) {
      return desktopDescription;
    }
    return _modeDescriptions[value.trim().toLowerCase()];
  }

  /// Full Access ink: deep orange on light theme, light orange on dark.
  static Color _fullAccessInk(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light
          ? ZColors.fullAccessDeep
          : ZColors.fullAccess;

  Widget _modeChip(
    BuildContext context, {
    required String value,
    required bool selected,
  }) {
    final isFull = _isFullAccessMode(value);
    return ChoiceChip(
      label: Text(
        _modeLabelOf(value, fallbackName: value),
        style: TextStyle(
          fontSize: 13,
          color: isFull ? _fullAccessInk(context) : null,
          fontWeight: isFull ? FontWeight.w600 : null,
        ),
      ),
      selected: selected,
      onSelected: (_) {
        if (_isDraft) {
          onDraftChange?.call('mode', value);
        } else {
          _apply(
            context,
            () => transport.switchCollaborationMode(sessionId ?? '', value),
          );
        }
      },
      backgroundColor:
          isFull ? ZColors.fullAccess.withValues(alpha: 0.12) : null,
      selectedColor:
          isFull ? ZColors.fullAccess.withValues(alpha: 0.30) : null,
      side: isFull
          ? BorderSide(
              color: ZColors.fullAccess.withValues(
                  alpha: selected ? 0.85 : 0.5),
              width: selected ? 1.4 : 1,
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final sid = sessionId ?? '';
    final config = state?.config ?? const {};
    final modelOption = prep?.option('model');
    final modeOption = prep?.option('mode');
    final thoughtOption = prep?.option('thought_level');
    final followup = '${config['followupMode'] ?? 'queue'}';

    // Current selection: prefer the LIVE session config (updates after a
    // switch), fall back to prepareWorkspace's currentValue / draft.
    final liveModelValue =
        '${config['provider'] ?? ''}/${config['model'] ?? ''}';
    final currentModelValue =
        _isDraft || config['model'] == null || '${config['model']}'.isEmpty
            ? (draftConfig?['model'] ?? '${modelOption?.currentValue ?? ''}')
            : liveModelValue;
    final currentThoughtValue = _isDraft
        ? (draftConfig?['thought'] ?? '${thoughtOption?.currentValue ?? ''}')
        : (state?.currentThought.isNotEmpty == true
            ? state!.currentThought
            : '${thoughtOption?.currentValue ?? ''}');
    final currentModeValue = _isDraft
        ? (draftConfig?['mode'] ?? 'build')
        : state?.currentMode ?? 'build';

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_isDraft ? '新会话 · 模型与模式' : '模型与模式',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            if (modelOption != null && modelOption.options.isNotEmpty) ...[
              _ModelPickerSection(
                modelOption: modelOption,
                currentModelValue: currentModelValue,
                isDraft: _isDraft,
                state: state,
                transport: transport,
                prep: prep,
                sessionId: sessionId,
                onDraftChange: onDraftChange,
                apply: _apply,
              ),
              const SizedBox(height: 12),
            ] else
              Text('当前模型: ${state?.currentModel ?? ''}',
                  style: TextStyle(fontSize: 12, color: ZInk.muted(context))),
            if (thoughtOption != null && thoughtOption.options.isNotEmpty) ...[
              Text(thoughtOption.name, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final v in thoughtOption.options)
                    ChoiceChip(
                      label: Text(v.name),
                      selected: currentThoughtValue == v.value ||
                          state?.currentThought == v.value,
                      onSelected: (_) {
                        if (_isDraft) {
                          onDraftChange?.call('thought', v.value);
                        } else {
                          final modelValue = currentModelValue;
                          final (provider, model) = modelValue.isNotEmpty
                              ? _splitModelValue(modelValue)
                              : (
                                  '${config['provider'] ?? ''}',
                                  '${config['model'] ?? ''}'
                                );
                          _apply(
                            context,
                            () => transport.switchModelConfig(
                              sid,
                              provider: provider,
                              model: model,
                              thought: v.value,
                            ),
                            onAccepted: () => state?.optimisticPatch({
                              'config': {
                                ...?state!.config,
                                'thought': v.value,
                              },
                            }),
                          );
                        }
                      },
                    ),
                ],
              ),
            ] else if ((state?.thoughtLevels ?? const []).isNotEmpty) ...[
              const Text('思考等级', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final level in state!.thoughtLevels)
                    ChoiceChip(
                      label: Text(level),
                      selected: state?.currentThought == level,
                      onSelected: (_) => _apply(
                        context,
                        () => transport.switchModelConfig(
                          sid,
                          provider: '${config['provider'] ?? ''}',
                          model: '${config['model'] ?? ''}',
                          thought: level,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            const Text('协作模式', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            if (modeOption != null && modeOption.options.isNotEmpty)
              for (final v in modeOption.options)
                Builder(builder: (context) {
                  final isFull = _isFullAccessMode(v.value);
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      currentModeValue == v.value
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 18,
                      color: isFull
                          ? _fullAccessInk(context)
                          : (currentModeValue == v.value
                              ? ZColors.primary
                              : ZInk.ghost(context)),
                    ),
                    title: Text(
                      _modeLabelOf(v.value, fallbackName: v.name),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isFull ? FontWeight.w600 : null,
                        color: isFull ? _fullAccessInk(context) : null,
                      ),
                    ),
                    subtitle: _modeDescriptionOf(v.value, v.description) != null
                        ? Text(
                            _modeDescriptionOf(v.value, v.description)!,
                            style: TextStyle(
                                fontSize: 11, color: ZInk.faint(context)),
                          )
                        : null,
                    onTap: () {
                      if (_isDraft) {
                        onDraftChange?.call('mode', v.value);
                      } else {
                        _apply(
                          context,
                          () =>
                              transport.switchCollaborationMode(sid, v.value),
                          onAccepted: () => state?.optimisticPatch({
                            'config': {
                              ...?state!.config,
                              'mode': v.value,
                            },
                          }),
                        );
                      }
                    },
                  );
                })
            else
              Wrap(
                spacing: 8,
                children: [
                  for (final m in const ['build', 'edit', 'plan', 'yolo'])
                    _modeChip(
                      context,
                      value: m,
                      selected: currentModeValue == m,
                    ),
                ],
              ),
            if (!_isDraft) ...[
              const SizedBox(height: 16),
              const Text('后续消息', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final f in const ['queue', 'guide'])
                    ChoiceChip(
                      label: Text(f == 'queue' ? '排队' : '引导'),
                      selected: followup == f,
                      onSelected: (_) => _apply(
                        context,
                        () => transport.setFollowupMode(sid, f),
                        onAccepted: () => state?.optimisticPatch({
                          'config': {
                            ...?state!.config,
                            'followupMode': f,
                          },
                        }),
                      ),
                    ),
                ],
              ),
            ],
            if (_otherOptions.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('其他配置', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              for (final o in _otherOptions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child:
                            Text(o.name, style: const TextStyle(fontSize: 13)),
                      ),
                      const SizedBox(width: 8),
                      Text('${o.currentValue}',
                          style: TextStyle(
                              fontSize: 12, color: ZInk.muted(context))),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _apply(
    BuildContext context,
    Future<dynamic> Function() run, {
    void Function()? onAccepted,
  }) async {
    try {
      final res = await run();
      if (context.mounted) {
        if (res is Map &&
            res['status'] != null &&
            res['status'] != 'accepted') {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('被拒绝: ${res['reasonCode'] ?? res['status']}')));
        } else {
          onAccepted?.call();
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('失败: $e')));
      }
    }
  }
}

/// Two-level model picker: level 1 lists providers (with model count and the
/// current model), level 2 lists the chosen provider's models. Falls back to
/// a flat list when grouping is meaningless (single provider, or every model
/// carries no provider info).
class _ModelPickerSection extends StatefulWidget {
  final ConfigOption modelOption;
  final String currentModelValue;
  final bool isDraft;
  final ConversationState? state;
  final ConversationTransport transport;
  final WorkspacePrep? prep;
  final String? sessionId;
  final void Function(String key, String value)? onDraftChange;
  final Future<void> Function(
    BuildContext context,
    Future<dynamic> Function() run, {
    void Function()? onAccepted,
  }) apply;

  const _ModelPickerSection({
    required this.modelOption,
    required this.currentModelValue,
    required this.isDraft,
    required this.transport,
    required this.apply,
    this.state,
    this.prep,
    this.sessionId,
    this.onDraftChange,
  });

  @override
  State<_ModelPickerSection> createState() => _ModelPickerSectionState();
}

class _ModelPickerSectionState extends State<_ModelPickerSection> {
  /// Provider currently drilled into; null shows the provider list.
  String? _openProvider;

  /// 'builtin:zai-coding-plan/GLM-5.2' → 'builtin:zai-coding-plan'
  static String _providerSegment(String value) {
    final idx = value.lastIndexOf('/');
    return idx <= 0 ? value : value.substring(0, idx);
  }

  /// Prefer the desktop-provided provider name; derive from the value's
  /// provider segment when it is missing (older desktops).
  String _providerKeyOf(ConfigOptionValue v) =>
      v.modelProviderName ?? _providerSegment(v.value);

  /// Provider groups keyed in first-appearance order.
  Map<String, List<ConfigOptionValue>> get _groups {
    final groups = <String, List<ConfigOptionValue>>{};
    for (final v in widget.modelOption.options) {
      groups.putIfAbsent(_providerKeyOf(v), () => []).add(v);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.modelOption.name, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 8),
        ..._buildBody(context),
      ],
    );
  }

  List<Widget> _buildBody(BuildContext context) {
    final groups = _groups;
    // Degenerate grouping (single provider, or every model standalone) ->
    // keep the flat list; an accordion would add a pointless tap.
    if (groups.length < 2 ||
        groups.length >= widget.modelOption.options.length) {
      return [
        _modelList(groups.values.expand((m) => m).toList(),
            showProviderSubtitle: true),
      ];
    }
    // Accordion: tapping a provider expands its model list in place; at
    // most one section is open at a time. Every group keeps its AnimatedSize
    // mounted so collapse animates too (child swaps to a zero-height box).
    final widgets = <Widget>[];
    for (final g in groups.entries) {
      final expanded = _openProvider == g.key;
      widgets.add(_providerRow(context, g, expanded: expanded));
      widgets.add(
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: expanded
              ? Padding(
                  padding: const EdgeInsets.only(left: 18),
                  child: _modelList(g.value, showProviderSubtitle: false),
                )
              : const SizedBox(width: double.infinity),
        ),
      );
    }
    return widgets;
  }

  Widget _providerRow(BuildContext context,
      MapEntry<String, List<ConfigOptionValue>> group,
      {required bool expanded}) {
    final isCurrent =
        group.value.any((v) => v.value == widget.currentModelValue);
    final current = isCurrent
        ? group.value.firstWhere((v) => v.value == widget.currentModelValue)
        : null;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        isCurrent ? Icons.radio_button_checked : Icons.radio_button_off,
        size: 18,
        color: isCurrent ? ZColors.primary : ZInk.ghost(context),
      ),
      title: Text(group.key,
          style: TextStyle(
              fontSize: 13,
              fontWeight: expanded ? FontWeight.w600 : null,
              color: ZInk.soft(context))),
      subtitle: Text(
        isCurrent && current != null
            ? '当前 · ${current.name}'
            : '${group.value.length} 个模型',
        style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
      ),
      trailing: AnimatedRotation(
        turns: expanded ? 0.25 : 0,
        duration: const Duration(milliseconds: 200),
        child: Icon(
          Icons.chevron_right,
          size: 18,
          color: ZInk.ghost(context),
        ),
      ),
      onTap: () =>
          setState(() => _openProvider = expanded ? null : group.key),
    );
  }

  Widget _modelList(List<ConfigOptionValue> models,
      {required bool showProviderSubtitle}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final v in models) _modelRow(v, showProviderSubtitle),
      ],
    );
  }

  Widget _modelRow(ConfigOptionValue v, bool showProviderSubtitle) {
    final isCurrent = widget.currentModelValue == v.value;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        isCurrent ? Icons.radio_button_checked : Icons.radio_button_off,
        size: 18,
        color: isCurrent ? ZColors.primary : ZInk.ghost(context),
      ),
      title: Text(v.name, style: const TextStyle(fontSize: 13)),
      subtitle: showProviderSubtitle && v.modelProviderName != null
          ? Text(v.modelProviderName!,
              style: TextStyle(fontSize: 11, color: ZInk.faint(context)))
          : null,
      onTap: () => _selectModel(v),
    );
  }

  void _selectModel(ConfigOptionValue v) {
    if (widget.isDraft) {
      widget.onDraftChange?.call('model', v.value);
      return;
    }
    final sid = widget.sessionId ?? '';
    final (provider, model) = _splitPair(v.value);
    // thought must be valid for the target model: keep current if supported,
    // else fall back to the thought option's currentValue (Turbo: enabled/off)
    final currentThought = widget.state?.currentThought ?? '';
    final thoughtOpt = widget.prep?.option('thought_level');
    final thought = currentThought.isNotEmpty &&
            (thoughtOpt?.options.any((o) => o.value == currentThought) ??
                false)
        ? currentThought
        : '${thoughtOpt?.currentValue ?? (currentThought.isNotEmpty ? currentThought : 'enabled')}';
    widget.apply(
      context,
      () => widget.transport.switchModelConfig(
        sid,
        provider: provider,
        model: model,
        thought: thought,
      ),
      onAccepted: () => widget.state?.optimisticPatch({
        'config': {
          ...?widget.state!.config,
          'provider': provider,
          'model': model,
          'thought': thought,
        },
      }),
    );
  }

  static (String, String) _splitPair(String value) {
    final idx = value.lastIndexOf('/');
    if (idx <= 0) return (value, value);
    return (value.substring(0, idx), value.substring(idx + 1));
  }
}

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
    final contextWindow = usage['contextWindow'];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('用量统计',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            if (contextWindow is Map) ...[
              _UsageRow('上下文',
                  '${contextWindow['usedTokens'] ?? '-'} / ${contextWindow['maxTokens'] ?? '-'} tokens'),
            ],
            if (cumulative is Map) ...[
              _UsageRow('累计输入', '${cumulative['inputTokens'] ?? 0}'),
              _UsageRow('累计输出', '${cumulative['outputTokens'] ?? 0}'),
              _UsageRow('缓存读取', '${cumulative['cacheReadTokens'] ?? 0}'),
              _UsageRow('缓存写入', '${cumulative['cacheWriteTokens'] ?? 0}'),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.query_stats, size: 16),
                label: const Text('查询任务级用量 (getTaskTokenUsage)'),
                onPressed: () async {
                  try {
                    final res = await session.channels.call(
                      Channels.zcodeTask,
                      'getTaskTokenUsage',
                      [
                        {...scope, 'taskId': sessionId},
                      ],
                    );
                    if (context.mounted) {
                      showModalBottomSheet(
                        context: context,
                        builder: (context) =>
                            _StructuredSheet(title: '任务用量', data: res),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text('查询失败: $e')));
                    }
                  }
                },
              ),
            ),
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
    final filtered = q.isEmpty
        ? items
        : items
            .where((c) => c.name.toLowerCase().startsWith(q.toLowerCase()))
            .toList();
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
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onSkills;
  final VoidCallback onVoice;

  /// Inline config dropdowns built by [_ChatPageState] (official-web style:
  /// mode / model / thought live INSIDE the composer toolbar).
  final Widget modeChip;
  final Widget modelChip;
  final Widget thoughtChip;
  final VoidCallback? onMoreSettings;

  const _InputBar({
    required this.controller,
    required this.sending,
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
    this.onMoreSettings,
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
                      decoration: const InputDecoration(
                        hintText: '向 ZCode 发送消息…',
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
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
                              size: 20,
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
              Row(
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.add,
                        size: 20, color: ZInk.muted(context)),
                    tooltip: '更多操作',
                    onPressed:
                        widget.sending ? null : () => _showActions(context),
                  ),
                  const SizedBox(width: 2),
                  widget.modeChip,
                  const Spacer(),
                  widget.modelChip,
                  const SizedBox(width: 6),
                  widget.thoughtChip,
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.tune,
                        size: 18, color: ZInk.muted(context)),
                    tooltip: '更多设置',
                    onPressed: widget.onMoreSettings,
                  ),
                  const SizedBox(width: 2),
                  Container(
                    decoration: BoxDecoration(
                      color: ZColors.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.sending ? null : widget.onSend,
                      icon: widget.sending
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.arrow_upward,
                              color: Colors.white, size: 19),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
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
                  _ActionItem(
                    icon: Icons.attach_file,
                    label: '上传文件',
                    onTap: () {
                      Navigator.pop(context);
                      widget.onAttach();
                    },
                  ),
                  _ActionItem(
                    icon: Icons.auto_awesome_outlined,
                    label: '选择 Skill',
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
