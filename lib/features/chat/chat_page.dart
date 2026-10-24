import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../app.dart';
import '../../core/app_controller.dart';
import '../../core/app_section.dart';
import '../../core/chat/chat_client.dart';
import '../../core/chat/chat_history.dart';
import '../../core/models/model_catalog.dart';
import '../../core/runtime/server_controller.dart';
import '../../core/settings/app_settings.dart';
import '../../design/flash_components.dart';
import '../../design/flash_tokens.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _client = ChatClient();
  final _scroll = ScrollController();
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _systemPrompt = TextEditingController();
  final List<_ChatMessage> _messages = [];
  bool _loaded = false;
  bool _streaming = false;
  String _streamingText = '';
  DateTime? _streamStarted;
  DateTime? _firstTokenAt;
  int _streamCjk = 0;
  int _streamOther = 0;
  Timer? _liveTimer;
  Timer? _paramSaveTimer;
  ChatOptions _options = ChatOptions();
  String _storePath = '';
  bool _composerFocused = false;
  bool _showParameters = false;

  @override
  void initState() {
    super.initState();
    _inputFocus.addListener(() {
      setState(() => _composerFocused = _inputFocus.hasFocus);
    });
    ChatHistory.instance.openRequest.addListener(_openRecentThread);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final controller = AppScope.of(context);
    _options = ChatOptions(
      temperature: controller.settings.temperature,
      topP: controller.settings.topP,
      systemPrompt: controller.settings.systemPrompt,
      reasoningEffort: controller.settings.effectiveReasoningEffort,
    );
    _systemPrompt.text = _options.systemPrompt;
    _loadConversation(controller);
    _loadHistory(controller);
  }

  Future<void> _loadConversation(AppController controller) async {
    _storePath = await controller.settings.conversationPath();
    final file = File(_storePath);
    if (!file.existsSync()) return;
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is List) {
        final restored = value
            .whereType<Map>()
            .map(
              (item) => _ChatMessage.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList();
        if (!mounted) return;
        setState(() {
          _messages
            ..clear()
            ..addAll(
              restored.length > 60
                  ? restored.sublist(restored.length - 60)
                  : restored,
            );
        });
        _jumpToBottom();
      }
    } catch (_) {
      // A damaged conversation should not block the app.
    }
  }

  Future<void> _saveConversation() async {
    if (_storePath.isEmpty) return;
    try {
      await File(_storePath).writeAsString(
        jsonEncode(_messages.map((item) => item.toJson()).toList()),
        flush: true,
      );
    } catch (_) {}
  }

  Future<void> _loadHistory(AppController controller) async {
    try {
      await ChatHistory.instance.ensureLoaded(
        File(await controller.settings.historyPath()),
      );
    } catch (_) {}
  }

  void _openRecentThread() {
    final thread = ChatHistory.instance.openRequest.value;
    if (thread == null) return;
    ChatHistory.instance.openRequest.value = null;
    if (!mounted) return;
    if (_streaming) {
      _toast('正在生成，先停止再切换对话');
      return;
    }
    final previous = _messages.map((item) => item.toJson()).toList();
    final previousTitle = _threadTitle;
    final hadUser = _messages.any((item) => item.role == 'user');
    setState(() {
      _messages
        ..clear()
        ..addAll(thread.messages.map(_ChatMessage.fromJson));
      _streaming = false;
      _streamingText = '';
      _input.clear();
    });
    unawaited(
      _syncHistory(thread.id, previousTitle, previous, hadUser),
    );
    unawaited(_saveConversation());
    _jumpToBottom();
    _toast('已打开「${thread.title}」');
  }

  /// Archive the conversation that was replaced and drop the thread we just
  /// opened from “最近”. Both touch the same JSON file, so run them in order.
  Future<void> _syncHistory(
    String openedId,
    String previousTitle,
    List<Map<String, dynamic>> previous,
    bool archivePrevious,
  ) async {
    if (archivePrevious) {
      await ChatHistory.instance.archive(
        title: previousTitle,
        messages: previous,
      );
    }
    await ChatHistory.instance.forget(openedId);
  }

  @override
  void dispose() {
    ChatHistory.instance.openRequest.removeListener(_openRecentThread);
    unawaited(_client.cancel());
    _liveTimer?.cancel();
    _paramSaveTimer?.cancel();
    _scroll.dispose();
    _input.dispose();
    _inputFocus.dispose();
    _systemPrompt.dispose();
    unawaited(_saveConversation());
    super.dispose();
  }

  int get _streamTokens =>
      (_streamCjk + _streamOther / 4).round().clamp(1, 1 << 30);

  double? get _decodeRate {
    final first = _firstTokenAt;
    if (first == null) return null;
    final span = DateTime.now().difference(first).inMilliseconds / 1000;
    if (span < 0.15) return null;
    return _streamTokens / span;
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _streaming) return;
    final controller = AppScope.read(context);
    if (!controller.isReady) {
      _toast('服务还没有就绪');
      return;
    }
    final model = controller.currentModel;
    if (model.isEmpty) {
      _toast('请先选择模型');
      return;
    }
    _input.clear();
    final now = DateTime.now();
    setState(() {
      _messages.add(_ChatMessage(role: 'user', text: text, createdAt: now));
      _messages.add(
        _ChatMessage(role: 'assistant', text: '', model: model, createdAt: now),
      );
      _streaming = true;
      _streamingText = '';
      _streamStarted = now;
      _firstTokenAt = null;
      _streamCjk = 0;
      _streamOther = 0;
    });
    _options.reasoningEffort = controller.settings.effectiveReasoningEffort;
    _startLiveTimer();
    _jumpToBottom();

    final turns = _messages
        .take(_messages.length - 1)
        .where((item) => !item.isError && item.text.trim().isNotEmpty)
        .map((item) => ChatTurn(role: item.role, content: item.text))
        .toList();
    await _client.send(
      port: controller.port,
      model: model,
      turns: turns,
      options: _options,
      onDelta: (delta) {
        if (!mounted) return;
        _firstTokenAt ??= DateTime.now();
        _streamingText += delta;
        for (final rune in delta.runes) {
          if (rune > 0x2E80) {
            _streamCjk++;
          } else {
            _streamOther++;
          }
        }
        setState(() {});
        if (_nearBottom) _jumpToBottom();
      },
      onFinish: (usage, elapsed) {
        if (!mounted) return;
        _finishStream(usage: usage, elapsed: elapsed);
      },
      onFailure: (message) {
        if (!mounted) return;
        _finishStream(error: message);
      },
    );
  }

  void _startLiveTimer() {
    _liveTimer?.cancel();
    _liveTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (mounted && _streaming) setState(() {});
    });
  }

  void _finishStream({
    ChatUsage? usage,
    Duration? elapsed,
    String? error,
    bool cancelled = false,
  }) {
    if (!_streaming || _messages.isEmpty) return;
    _liveTimer?.cancel();
    final text = _streamingText.trim();
    final duration =
        elapsed ?? DateTime.now().difference(_streamStarted ?? DateTime.now());
    final tokens = usage?.completionTokens ?? _streamTokens;
    final rate = duration.inMilliseconds > 200
        ? tokens / (duration.inMilliseconds / 1000)
        : _decodeRate;
    final parts = <String>[
      if (rate != null && rate > 0) '${rate.toStringAsFixed(1)} tok/s',
      '$tokens tokens',
      '${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s',
      if (usage?.promptTokens != null) '上下文 ${usage!.promptTokens}',
      if (cancelled) '已停止',
    ];
    final current = _messages.last;
    _messages[_messages.length - 1] = current.copyWith(
      text: text.isEmpty ? (cancelled ? '[已停止]' : '[空回复]') : text,
      stats: error == null ? parts.join(' · ') : '失败',
      isError: error != null,
      tokens: error == null ? tokens : null,
      elapsed: duration.inMilliseconds / 1000,
      ttft: _firstTokenAt
          ?.difference(_streamStarted ?? DateTime.now())
          .inMilliseconds,
    );
    if (error != null) {
      _messages[_messages.length - 1] = _messages.last.copyWith(
        text: text.isEmpty ? error : '$text\n\n[出错] $error',
      );
    }
    setState(() {
      _streaming = false;
      _streamingText = '';
    });
    unawaited(_saveConversation());
    _jumpToBottom();
  }

  Future<void> _stop() async {
    if (!_streaming) return;
    await _client.cancel();
    if (!mounted) return;
    _finishStream(cancelled: true);
  }

  void _regenerate() {
    if (_streaming) return;
    final userIndex = _messages.lastIndexWhere((item) => item.role == 'user');
    if (userIndex < 0) return;
    final prompt = _messages[userIndex].text;
    setState(() {
      _messages.removeRange(userIndex, _messages.length);
    });
    _input.text = prompt;
    _send();
  }

  Future<void> _clear() async {
    if (_messages.isEmpty) return;
    final confirmed = await _confirm(
      title: '清空当前对话？',
      description: '只会删除界面上的记录，不会影响模型或服务。',
      confirmLabel: '清空',
    );
    if (!confirmed || !mounted) return;
    await _client.cancel();
    if (!mounted) return;
    _liveTimer?.cancel();
    setState(() {
      _messages.clear();
      _streaming = false;
      _streamingText = '';
    });
    await _saveConversation();
    if (mounted) _toast('对话已清空');
  }

  Future<void> _newChat() async {
    if (_streaming) {
      _toast('正在生成，先停止再新建对话');
      return;
    }
    if (_messages.isNotEmpty) {
      final confirmed = await _confirm(
        title: '开始新对话？',
        description: '当前对话会移到侧栏的“最近”，可以随时重新打开；不会影响模型或推理服务。',
        confirmLabel: '新建对话',
      );
      if (!confirmed || !mounted) return;
    }
    await _client.cancel();
    if (!mounted) return;
    _liveTimer?.cancel();
    final archived = _messages.map((item) => item.toJson()).toList();
    final archivedTitle = _threadTitle;
    final hadUser = _messages.any((item) => item.role == 'user');
    setState(() {
      _messages.clear();
      _streaming = false;
      _streamingText = '';
      _input.clear();
    });
    if (hadUser) {
      unawaited(
        ChatHistory.instance.archive(
          title: archivedTitle,
          messages: archived,
        ),
      );
    }
    await _saveConversation();
    if (!mounted) return;
    _inputFocus.requestFocus();
    _toast('已开始新对话');
  }

  Future<bool> _confirm({
    required String title,
    required String description,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .18),
      builder: (dialogContext) {
        final t = dialogContext.flash;
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: t.surface,
                borderRadius: BorderRadius.circular(FlashRadius.lg),
                border: Border.all(color: t.border),
                boxShadow: t.shadow2,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -.2,
                      color: t.text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    description,
                    style: TextStyle(fontSize: 12, height: 1.6, color: t.text3),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      FlashQuietButton(
                        label: '取消',
                        onPressed: () => Navigator.pop(dialogContext, false),
                      ),
                      const SizedBox(width: 8),
                      FlashPrimaryButton(
                        label: confirmLabel,
                        height: 31,
                        onPressed: () => Navigator.pop(dialogContext, true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    return result ?? false;
  }

  // ---------------------------------------------------------------------------
  // Parameters
  // ---------------------------------------------------------------------------

  void _toggleParameters() {
    if (_showParameters) {
      _closeParameters();
    } else {
      setState(() => _showParameters = true);
    }
  }

  void _closeParameters() {
    _persistParameters();
    if (!mounted) return;
    setState(() => _showParameters = false);
  }

  void _persistParameters() {
    _paramSaveTimer?.cancel();
    if (!mounted) return;
    final controller = AppScope.read(context);
    _options.systemPrompt = _systemPrompt.text;
    controller.settings
      ..temperature = _options.temperature
      ..topP = _options.topP
      ..systemPrompt = _options.systemPrompt;
  }

  void _scheduleParameterSave() {
    _paramSaveTimer?.cancel();
    _paramSaveTimer = Timer(const Duration(milliseconds: 420), () {
      if (mounted) _persistParameters();
    });
  }

  void _setTemperature(double value) {
    setState(() => _options.temperature = value.clamp(0, 2));
    _scheduleParameterSave();
  }

  void _setTopP(double value) {
    setState(() => _options.topP = value.clamp(.05, 1));
    _scheduleParameterSave();
  }

  void _setThinking(ThinkingMode mode) {
    final controller = AppScope.read(context);
    controller.settings.thinkingMode = mode;
    setState(() {
      _options.reasoningEffort = controller.settings.effectiveReasoningEffort;
    });
  }

  void _setSystemPrompt(String value) {
    _options.systemPrompt = value;
    _scheduleParameterSave();
  }

  void _restoreDefaultParameters() {
    final controller = AppScope.read(context);
    controller.settings
      ..temperature = .7
      ..topP = .95
      ..systemPrompt = ''
      ..thinkingMode = ThinkingMode.automatic;
    setState(() {
      _options
        ..temperature = .7
        ..topP = .95
        ..systemPrompt = ''
        ..reasoningEffort = null;
      _systemPrompt.text = '';
    });
    _persistParameters();
    _toast('已恢复默认参数');
  }

  Future<void> _applyModel(String id) async {
    final controller = AppScope.read(context);
    if (id == controller.currentModel) return;
    try {
      await controller.applyModel(id);
      if (!mounted) return;
      _toast('已切换到 ${_shortModel(id)}');
    } catch (error) {
      if (!mounted) return;
      _toast('切换模型失败：$error');
    }
  }

  // ---------------------------------------------------------------------------
  // Scroll / helpers
  // ---------------------------------------------------------------------------

  bool get _nearBottom {
    if (!_scroll.hasClients) return true;
    return _scroll.position.maxScrollExtent - _scroll.offset < 120;
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _copyText(String text, [String message = '已复制']) {
    Clipboard.setData(ClipboardData(text: text));
    _toast(message);
  }

  String get _threadTitle {
    for (final message in _messages) {
      if (message.role == 'user' && message.text.trim().isNotEmpty) {
        return _topicFor(message.text);
      }
    }
    return '新对话';
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final t = context.flash;
    return Padding(
      padding: pagePadding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final inlinePanel = constraints.maxWidth >= 1000;
          final chat = _buildChatCard(context, controller);
          if (!_showParameters) return chat;

          final panel = _buildParametersPanel(
            controller,
            overlay: !inlinePanel,
          );
          if (!inlinePanel) {
            final width = (constraints.maxWidth - 24)
                .clamp(260.0, 316.0)
                .toDouble();
            return Stack(
              fit: StackFit.expand,
              children: [
                chat,
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _closeParameters,
                    child: ColoredBox(
                      color: Colors.black.withValues(
                        alpha: t.isDark ? .28 : .12,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 62,
                  right: 0,
                  bottom: 0,
                  width: width,
                  child: panel,
                ),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: chat),
              const SizedBox(width: 14),
              SizedBox(width: 290, child: panel),
            ],
          );
        },
      ),
    );
  }

  Widget _buildChatCard(BuildContext context, AppController controller) {
    final t = context.flash;
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(FlashRadius.lg),
        border: Border.all(color: t.border),
        boxShadow: t.shadow1,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTopbar(context, controller),
          Expanded(
            child: _messages.isEmpty
                ? _Welcome(
                    onSuggestion: (text) {
                      _input.text = text;
                      _inputFocus.requestFocus();
                    },
                  )
                : Scrollbar(
                    controller: _scroll,
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(28, 22, 28, 4),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final isLast = index == _messages.length - 1;
                        final message = _messages[index];
                        final display = isLast && _streaming
                            ? message.copyWith(text: _streamingText)
                            : message;
                        return _MessageItem(
                          key: ValueKey(
                            '${message.createdAt.microsecondsSinceEpoch}-$index',
                          ),
                          message: display,
                          streaming: isLast && _streaming,
                          canRegenerate:
                              !_streaming &&
                              isLast &&
                              message.role == 'assistant' &&
                              !message.isError,
                          onRegenerate: _regenerate,
                          onCopy: () => _copyText(display.text, '已复制消息'),
                          onCopyCode: (code) => _copyText(code, '已复制代码'),
                        );
                      },
                    ),
                  ),
          ),
          if (!controller.isReady) _buildServiceBanner(context, controller),
          if (_streaming) _buildLiveStrip(context),
          _buildComposer(context, controller),
        ],
      ),
    );
  }

  Widget _buildTopbar(BuildContext context, AppController controller) {
    final t = context.flash;
    final state = controller.serverState;
    final model = controller.currentModel;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          final tiny = constraints.maxWidth < 430;
          return Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: t.brandSoft,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 16,
                  color: t.brand,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _threadTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -.1,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${model.isEmpty ? '—' : model} · 本地上下文',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'SF Mono',
                        fontSize: 10,
                        color: t.text3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (!tiny) _readyPill(state) else _readyDot(state),
              if (!compact) ...[const SizedBox(width: 8), _toolbarDivider(t)],
              if (!compact)
                Opacity(
                  opacity: controller.isReady ? 1 : .45,
                  child: FlashIconButton(
                    icon: Icons.open_in_browser_rounded,
                    tooltip: 'Web 界面',
                    solid: true,
                    onPressed: controller.isReady
                        ? () => launchUrl(
                            Uri.parse('http://127.0.0.1:${controller.port}/'),
                            mode: LaunchMode.externalApplication,
                          )
                        : null,
                  ),
                ),
              const SizedBox(width: 2),
              FlashIconButton(
                icon: Icons.tune_rounded,
                tooltip: '对话参数',
                solid: true,
                active: _showParameters,
                onPressed: _toggleParameters,
              ),
              const SizedBox(width: 2),
              Opacity(
                opacity: _messages.isEmpty ? .45 : 1,
                child: FlashIconButton(
                  icon: Icons.delete_outline_rounded,
                  tooltip: '清空对话',
                  solid: true,
                  onPressed: _messages.isEmpty ? null : _clear,
                ),
              ),
              const SizedBox(width: 2),
              FlashIconButton(
                icon: Icons.add_rounded,
                tooltip: '新对话',
                solid: true,
                onPressed: _newChat,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _readyPill(ServerState state) {
    final (tone, label) = switch (state) {
      ServerState.ready => (FlashTone.success, '就绪'),
      ServerState.starting => (FlashTone.warning, '启动中'),
      ServerState.stopping => (FlashTone.warning, '停止中'),
      ServerState.failed => (FlashTone.danger, '异常'),
      ServerState.stopped => (FlashTone.neutral, '未就绪'),
    };
    return FlashPill(label: label, tone: tone, dot: true);
  }

  Widget _readyDot(ServerState state) {
    final t = context.flash;
    final color = switch (state) {
      ServerState.ready => t.success,
      ServerState.starting || ServerState.stopping => t.warning,
      ServerState.failed => t.danger,
      ServerState.stopped => t.text3,
    };
    return FlashStatusDot(
      color: color,
      size: 7,
      pulse: state == ServerState.starting || state == ServerState.stopping,
    );
  }

  Widget _toolbarDivider(FlashTokens t) => Container(
    width: 1,
    height: 18,
    margin: const EdgeInsets.symmetric(horizontal: 2),
    color: t.border,
  );

  Widget _buildServiceBanner(BuildContext context, AppController controller) {
    final t = context.flash;
    final starting = controller.serverState == ServerState.starting;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: t.warningSoft,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: t.warning.withValues(alpha: .2)),
      ),
      child: Row(
        children: [
          Icon(
            starting ? Icons.hourglass_top_rounded : Icons.info_outline_rounded,
            size: 15,
            color: t.warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              starting ? '正在启动服务，就绪后即可对话…' : '服务未运行，启动后即可继续对话。',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: t.warning),
            ),
          ),
          const SizedBox(width: 8),
          FlashQuietButton(
            label: '启动服务',
            icon: Icons.play_arrow_rounded,
            height: 26,
            onPressed: starting ? null : controller.toggleService,
          ),
        ],
      ),
    );
  }

  Widget _buildLiveStrip(BuildContext context) {
    final t = context.flash;
    final rate = _decodeRate;
    final ttft = _firstTokenAt
        ?.difference(_streamStarted ?? DateTime.now())
        .inMilliseconds;
    final elapsed =
        DateTime.now()
            .difference(_streamStarted ?? DateTime.now())
            .inMilliseconds /
        1000;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 12,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const _Equalizer(),
                _LiveValue(
                  value: rate == null ? '—' : rate.toStringAsFixed(1),
                  unit: ' tok/s',
                ),
                _LiveValue(
                  label: '首字 ',
                  value: ttft == null ? '—' : '$ttft',
                  unit: ttft == null ? '' : ' ms',
                ),
                _LiveValue(value: '$_streamTokens', unit: ' tokens'),
                _LiveValue(value: elapsed.toStringAsFixed(1), unit: 's'),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '生成中…',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: t.brand,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(BuildContext context, AppController controller) {
    final t = context.flash;
    final enabled = controller.isReady;
    final model = controller.currentModel;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 16),
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(
          color: _composerFocused
              ? t.brand.withValues(alpha: .55)
              : t.borderStrong,
        ),
        borderRadius: BorderRadius.circular(15),
        boxShadow: [
          if (_composerFocused)
            BoxShadow(color: t.brandSoft, blurRadius: 0, spreadRadius: 3)
          else
            BoxShadow(
              color: Colors.black.withValues(alpha: t.isDark ? .16 : .035),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
        ],
      ),
      child: Opacity(
        opacity: enabled ? 1 : .62,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): () {
                  if (enabled && !_streaming) _send();
                },
                const SingleActivator(
                  LogicalKeyboardKey.enter,
                  meta: true,
                ): () {
                  if (enabled && !_streaming) _send();
                },
              },
              child: TextField(
                controller: _input,
                focusNode: _inputFocus,
                enabled: enabled,
                minLines: 1,
                maxLines: 6,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                cursorColor: t.brand,
                style: TextStyle(fontSize: 13, height: 1.6, color: t.text),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: enabled
                      ? '输入消息，Enter 发送，Shift+Enter 换行'
                      : '启动服务后即可输入',
                  hintStyle: TextStyle(fontSize: 13, color: t.text3),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.fromLTRB(3, 2, 3, 8),
                ),
              ),
            ),
            const SizedBox(height: 2),
            LayoutBuilder(
              builder: (context, constraints) {
                final showHint = constraints.maxWidth >= 560;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _ComposerChip(
                            icon: Icons.view_in_ar_outlined,
                            label: model.isEmpty ? '选择模型' : _shortModel(model),
                            chevron: true,
                            maxLabelWidth: constraints.maxWidth < 520
                                ? 140
                                : 240,
                            onTap: () =>
                                appSectionNotifier.value = AppSection.models,
                          ),
                          _ComposerChip(
                            icon: Icons.speed_rounded,
                            label:
                                '温度 ${_options.temperature.toStringAsFixed(2)}',
                            onTap: _toggleParameters,
                          ),
                          _ComposerChip(
                            icon: Icons.auto_awesome_rounded,
                            label:
                                '思考 ${controller.settings.thinkingMode.label}',
                            onTap: _toggleParameters,
                          ),
                        ],
                      ),
                    ),
                    if (showHint && !_streaming) ...[
                      const SizedBox(width: 8),
                      const FlashKbd(label: '↵'),
                      const SizedBox(width: 6),
                    ],
                    _SendButton(
                      streaming: _streaming,
                      enabled: enabled,
                      onTap: _streaming ? _stop : (enabled ? _send : null),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildParametersPanel(
    AppController controller, {
    required bool overlay,
  }) {
    return _ParametersPanel(
      controller: controller,
      options: _options,
      systemPrompt: _systemPrompt,
      overlay: overlay,
      onClose: _closeParameters,
      onDone: _closeParameters,
      onReset: _restoreDefaultParameters,
      onModelSelected: _applyModel,
      onTemperatureChanged: _setTemperature,
      onTopPChanged: _setTopP,
      onThinkingChanged: _setThinking,
      onSystemPromptChanged: _setSystemPrompt,
    );
  }
}

// ---------------------------------------------------------------------------
// Shell pieces
// ---------------------------------------------------------------------------

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  static const _suggestions = [
    _SuggestionData(
      icon: Icons.terminal_rounded,
      title: '解释这段日志',
      detail: '排查首字延迟',
      prompt: '帮我解释一下这段推理日志里的首字延迟为什么偏高',
    ),
    _SuggestionData(
      icon: Icons.bolt_rounded,
      title: '写一个并发下载器',
      detail: 'Flutter · Dart',
      prompt: '用 Flutter 写一个并发下载器，限制最多 4 个并发，并显示进度',
    ),
    _SuggestionData(
      icon: Icons.auto_awesome_rounded,
      title: '草稿模型如何加速',
      detail: 'DFlash2 原理',
      prompt: 'DFlash2 草稿模型是怎么加速解码的？用通俗的语言解释',
    ),
    _SuggestionData(
      icon: Icons.view_in_ar_outlined,
      title: '优化一段 SQL',
      detail: '查询与执行计划',
      prompt: '帮我把这段 SQL 查询优化一下，并解释执行计划',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const FlashLogo(size: 54),
              const SizedBox(height: 14),
              Text(
                '开始一次本地对话',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.6,
                  color: t.text,
                ),
              ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Text(
                  '所有推理都在这台设备上完成。没有账号，没有云端，也没有内容上传。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, height: 1.6, color: t.text3),
                ),
              ),
              const SizedBox(height: 22),
              LayoutBuilder(
                builder: (context, constraints) {
                  final oneColumn = constraints.maxWidth < 480;
                  final width = oneColumn
                      ? constraints.maxWidth
                      : (constraints.maxWidth - 9) / 2;
                  return Wrap(
                    spacing: 9,
                    runSpacing: 9,
                    children: [
                      for (final suggestion in _suggestions)
                        SizedBox(
                          width: width,
                          child: _SuggestionCard(
                            data: suggestion,
                            onTap: () => onSuggestion(suggestion.prompt),
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const FlashKbd(label: '↵'),
                  Text(
                    ' 发送 · ',
                    style: TextStyle(fontSize: 10.5, color: t.text3),
                  ),
                  const FlashKbd(label: '⇧'),
                  const FlashKbd(label: '↵'),
                  Text(' 换行', style: TextStyle(fontSize: 10.5, color: t.text3)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SuggestionData {
  const _SuggestionData({
    required this.icon,
    required this.title,
    required this.detail,
    required this.prompt,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String prompt;
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.data, required this.onTap});

  final _SuggestionData data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return FlashHover(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      builder: (hovered) => Transform.translate(
        offset: Offset(0, hovered ? -1 : 0),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
          decoration: BoxDecoration(
            color: hovered ? t.surface : t.surface2,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: hovered ? t.borderStrong : t.border),
            boxShadow: hovered ? t.shadow1 : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(data.icon, size: 16, color: t.brand),
              const SizedBox(height: 5),
              Text(
                data.title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                data.detail,
                style: TextStyle(fontSize: 10.5, color: t.text3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

class _MessageItem extends StatefulWidget {
  const _MessageItem({
    super.key,
    required this.message,
    required this.streaming,
    required this.canRegenerate,
    required this.onRegenerate,
    required this.onCopy,
    required this.onCopyCode,
  });

  final _ChatMessage message;
  final bool streaming;
  final bool canRegenerate;
  final VoidCallback onRegenerate;
  final VoidCallback onCopy;
  final ValueChanged<String> onCopyCode;

  @override
  State<_MessageItem> createState() => _MessageItemState();
}

class _MessageItemState extends State<_MessageItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final message = widget.message;
    final user = message.role == 'user';
    final metrics = _metricTags(message);
    final avatar = user
        ? Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.surface2,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: t.border),
            ),
            child: Text(
              '你',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: t.text2,
              ),
            ),
          )
        : const FlashLogo(size: 28, glow: false);

    final main = Column(
      crossAxisAlignment: user
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _messageMeta(t, message, user),
        const SizedBox(height: 6),
        if (widget.streaming && message.text.isEmpty)
          const _TypingDots()
        else if (user)
          _UserBubble(text: message.text)
        else
          _AssistantBody(text: message.text, onCopyCode: widget.onCopyCode),
        if (message.isError) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: t.dangerSoft,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline_rounded, size: 13, color: t.danger),
                const SizedBox(width: 6),
                Text('请求失败', style: TextStyle(fontSize: 11.5, color: t.danger)),
              ],
            ),
          ),
        ],
        if (!user && !widget.streaming && metrics.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [for (final metric in metrics) _MetricTag(label: metric)],
          ),
        ],
        if (!widget.streaming)
          AnimatedSize(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: !_hovered
                ? const SizedBox(width: double.infinity, height: 0)
                : Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Align(
                      alignment: user
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.canRegenerate)
                            FlashIconButton(
                              icon: Icons.refresh_rounded,
                              tooltip: '重新生成',
                              size: 26,
                              iconSize: 14,
                              onPressed: widget.onRegenerate,
                            ),
                          FlashIconButton(
                            icon: Icons.copy_rounded,
                            tooltip: '复制',
                            size: 26,
                            iconSize: 14,
                            onPressed: widget.onCopy,
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
      ],
    );

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: user ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (!user) ...[avatar, const SizedBox(width: 11)],
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: user ? 620 : 690),
            child: main,
          ),
        ),
        if (user) ...[const SizedBox(width: 11), avatar],
      ],
    );

    final padded = Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: row,
          ),
        ),
      ),
    );

    if (widget.streaming) return padded;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      builder: (context, value, child) => Transform.translate(
        offset: Offset(0, 10 * (1 - value)),
        child: Opacity(opacity: value, child: child),
      ),
      child: padded,
    );
  }

  Widget _messageMeta(FlashTokens t, _ChatMessage message, bool user) {
    final name = user ? '你' : _messageModel(message.model);
    final time = _clockTime(message.createdAt);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: user
          ? [
              Text(
                time,
                style: TextStyle(
                  fontSize: 10.5,
                  color: t.text3,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 7),
              Text(
                name,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: t.text2,
                ),
              ),
            ]
          : [
              Text(
                name,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: t.text2,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                time,
                style: TextStyle(
                  fontSize: 10.5,
                  color: t.text3,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              t.brand.withValues(alpha: t.isDark ? .2 : .09),
              t.surface,
            ),
            Color.alphaBlend(
              t.brand2.withValues(alpha: t.isDark ? .14 : .07),
              t.surface,
            ),
          ],
        ),
        border: Border.all(
          color: Color.alphaBlend(t.brand.withValues(alpha: .16), t.surface),
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(14),
          topRight: Radius.circular(14),
          bottomLeft: Radius.circular(14),
          bottomRight: Radius.circular(4),
        ),
      ),
      child: SelectableText(
        text,
        style: TextStyle(fontSize: 13, height: 1.65, color: t.text),
      ),
    );
  }
}

class _AssistantBody extends StatelessWidget {
  const _AssistantBody({required this.text, required this.onCopyCode});

  final String text;
  final ValueChanged<String> onCopyCode;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return MarkdownBody(
      data: text,
      selectable: true,
      builders: {'pre': _CodeBlockBuilder(onCopy: onCopyCode)},
      onTapLink: (label, href, title) {
        if (href == null) return;
        final uri = Uri.tryParse(href);
        if (uri != null) {
          launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(fontSize: 13, height: 1.65, color: t.text),
        pPadding: const EdgeInsets.only(bottom: 10),
        h1: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -.4,
          color: t.text,
        ),
        h2: TextStyle(
          fontSize: 15.5,
          fontWeight: FontWeight.w600,
          letterSpacing: -.2,
          color: t.text,
        ),
        h3: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.text),
        h4: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: t.text,
        ),
        strong: TextStyle(fontWeight: FontWeight.w600, color: t.text),
        em: TextStyle(fontStyle: FontStyle.italic, color: t.text),
        a: TextStyle(
          color: t.brand,
          decoration: TextDecoration.underline,
          decorationColor: t.brand,
        ),
        code: TextStyle(
          fontFamily: 'SF Mono',
          fontSize: 11.5,
          color: Color.lerp(t.brand, t.text, .28),
          backgroundColor: t.surface2,
        ),
        blockquote: TextStyle(fontSize: 13, height: 1.65, color: t.text2),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: t.brand.withValues(alpha: .45), width: 2),
          ),
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(12, 2, 0, 2),
        listIndent: 18,
        listBullet: TextStyle(fontSize: 12, color: t.text3),
        blockSpacing: 10,
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: t.border)),
        ),
        codeblockDecoration: BoxDecoration(
          color: t.termBg,
          borderRadius: BorderRadius.circular(11),
        ),
      ),
    );
  }
}

class _MetricTag extends StatelessWidget {
  const _MetricTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Container(
      height: 19,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: t.text3,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Markdown code block
// ---------------------------------------------------------------------------

class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder({required this.onCopy});

  final ValueChanged<String> onCopy;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    var code = element.textContent;
    if (code.endsWith('\n')) {
      code = code.substring(0, code.length - 1);
    }
    var language = 'CODE';
    final children = element.children;
    if (children != null) {
      for (final child in children) {
        if (child is md.Element && child.tag == 'code') {
          final match = RegExp(r'language-([A-Za-z0-9_+-]+)')
              .firstMatch(child.attributes['class'] ?? '');
          if (match != null) {
            language = match.group(1)!.toUpperCase();
          }
        }
      }
    }
    return _CodeBlock(
      code: code,
      language: language,
      onCopy: () => onCopy(code),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({
    required this.code,
    required this.language,
    required this.onCopy,
  });

  final String code;
  final String language;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    const headerColor = Color(0xFF8A94A8);
    const codeColor = Color(0xFFD7E0F0);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.termBg,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: Colors.white.withValues(alpha: .06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(11, 7, 8, 7),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .035),
              border: Border(
                bottom: BorderSide(color: Colors.white.withValues(alpha: .05)),
              ),
            ),
            child: Row(
              children: [
                Text(
                  language,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: .8,
                    color: headerColor,
                  ),
                ),
                const Spacer(),
                FlashHover(
                  onTap: onCopy,
                  borderRadius: BorderRadius.circular(5),
                  builder: (hovered) => Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.copy_rounded,
                          size: 12,
                          color: hovered
                              ? const Color(0xFFD9E2F2)
                              : headerColor,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '复制',
                          style: TextStyle(
                            fontSize: 10,
                            color: hovered
                                ? const Color(0xFFD9E2F2)
                                : headerColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: SelectableText(
              code,
              style: const TextStyle(
                fontFamily: 'SF Mono',
                fontSize: 11.5,
                height: 1.7,
                color: codeColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Parameters panel
// ---------------------------------------------------------------------------

class _ParametersPanel extends StatelessWidget {
  const _ParametersPanel({
    required this.controller,
    required this.options,
    required this.systemPrompt,
    required this.overlay,
    required this.onClose,
    required this.onDone,
    required this.onReset,
    required this.onModelSelected,
    required this.onTemperatureChanged,
    required this.onTopPChanged,
    required this.onThinkingChanged,
    required this.onSystemPromptChanged,
  });

  final AppController controller;
  final ChatOptions options;
  final TextEditingController systemPrompt;
  final bool overlay;
  final VoidCallback onClose;
  final VoidCallback onDone;
  final VoidCallback onReset;
  final ValueChanged<String> onModelSelected;
  final ValueChanged<double> onTemperatureChanged;
  final ValueChanged<double> onTopPChanged;
  final ValueChanged<ThinkingMode> onThinkingChanged;
  final ValueChanged<String> onSystemPromptChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(FlashRadius.lg),
        border: Border.all(color: t.border),
        boxShadow: overlay ? t.shadow2 : t.shadow1,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(15, 14, 10, 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.border)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '对话参数',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -.1,
                          color: t.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '仅影响当前会话',
                        style: TextStyle(fontSize: 10.5, color: t.text3),
                      ),
                    ],
                  ),
                ),
                FlashIconButton(
                  icon: Icons.close_rounded,
                  tooltip: '关闭参数面板',
                  size: 26,
                  iconSize: 15,
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PanelLabel(label: '模型'),
                  const SizedBox(height: 7),
                  _ModelDropdown(
                    models: controller.machineModels,
                    current: controller.currentModel,
                    onSelected: onModelSelected,
                  ),
                  const SizedBox(height: 16),
                  _PanelLabel(
                    label: 'Temperature',
                    value: options.temperature.toStringAsFixed(2),
                  ),
                  const SizedBox(height: 3),
                  _GradientSlider(
                    value: options.temperature.clamp(0, 2),
                    min: 0,
                    max: 2,
                    onChanged: onTemperatureChanged,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '越低越稳定，越高越有创造性',
                    style: TextStyle(fontSize: 11, color: t.text3),
                  ),
                  const SizedBox(height: 16),
                  _PanelLabel(
                    label: 'Top P',
                    value: options.topP.toStringAsFixed(2),
                  ),
                  const SizedBox(height: 3),
                  _GradientSlider(
                    value: options.topP.clamp(.05, 1),
                    min: .05,
                    max: 1,
                    onChanged: onTopPChanged,
                  ),
                  const SizedBox(height: 16),
                  _PanelLabel(label: '思考模式'),
                  const SizedBox(height: 7),
                  _ThinkingSegmented(
                    value: controller.settings.thinkingMode,
                    onChanged: onThinkingChanged,
                  ),
                  const SizedBox(height: 16),
                  _PanelLabel(label: '系统提示词'),
                  const SizedBox(height: 7),
                  TextField(
                    controller: systemPrompt,
                    minLines: 4,
                    maxLines: 6,
                    onChanged: onSystemPromptChanged,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.55,
                      color: t.text,
                    ),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: t.surface2,
                      hintText: '例如：回答保持简洁、准确。',
                      hintStyle: TextStyle(fontSize: 12, color: t.text3),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(FlashRadius.xs),
                        borderSide: BorderSide(color: t.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(FlashRadius.xs),
                        borderSide: BorderSide(color: t.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(FlashRadius.xs),
                        borderSide: BorderSide(color: t.brand),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(15, 11, 15, 11),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: t.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _PanelQuietButton(label: '恢复默认', onTap: onReset),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FlashPrimaryButton(
                    label: '完成',
                    expanded: true,
                    height: 31,
                    onPressed: onDone,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelLabel extends StatelessWidget {
  const _PanelLabel({required this.label, this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: t.text2,
            ),
          ),
        ),
        if (value != null)
          Text(
            value!,
            style: TextStyle(
              fontFamily: 'SF Mono',
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: t.text,
            ),
          ),
      ],
    );
  }
}

class _ModelDropdown extends StatelessWidget {
  const _ModelDropdown({
    required this.models,
    required this.current,
    required this.onSelected,
  });

  final List<ModelInfo> models;
  final String current;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final field = Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(FlashRadius.xs),
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              current.isEmpty ? '—' : _shortModel(current),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: current.isEmpty ? t.text3 : t.text,
              ),
            ),
          ),
          Icon(Icons.expand_more_rounded, size: 16, color: t.text3),
        ],
      ),
    );
    if (models.isEmpty) {
      return Opacity(opacity: .55, child: field);
    }
    return PopupMenuButton<String>(
      tooltip: '选择模型',
      offset: const Offset(0, 38),
      color: t.surface,
      elevation: 10,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FlashRadius.sm),
        side: BorderSide(color: t.border),
      ),
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final model in models)
          PopupMenuItem<String>(
            value: model.id,
            height: 44,
            child: Row(
              children: [
                Icon(
                  model.id == current
                      ? Icons.check_rounded
                      : Icons.view_in_ar_outlined,
                  size: 14,
                  color: model.id == current ? t.brand : t.text3,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        model.shortName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: t.text,
                        ),
                      ),
                      Text(
                        model.id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'SF Mono',
                          fontSize: 9.5,
                          color: t.text3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
      child: field,
    );
  }
}

class _GradientSlider extends StatelessWidget {
  const _GradientSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackWidth = math.max(1.0, constraints.maxWidth - 14);
        final ratio = max == min
            ? 0.0
            : ((value - min) / (max - min)).clamp(0.0, 1.0);
        void update(Offset local) {
          final dx = (local.dx - 7).clamp(0.0, trackWidth);
          onChanged(min + (max - min) * (dx / trackWidth));
        }

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => update(details.localPosition),
            onHorizontalDragStart: (details) => update(details.localPosition),
            onHorizontalDragUpdate: (details) => update(details.localPosition),
            child: SizedBox(
              height: 24,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 7,
                    right: 7,
                    top: 10,
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: t.surface3,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 7,
                    top: 10,
                    width: trackWidth * ratio,
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        gradient: t.brandGradient,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 7 + trackWidth * ratio - 7,
                    top: 5,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.black.withValues(alpha: .12),
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x4D10141E),
                            blurRadius: 4,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ThinkingSegmented extends StatelessWidget {
  const _ThinkingSegmented({required this.value, required this.onChanged});

  final ThinkingMode value;
  final ValueChanged<ThinkingMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Container(
      height: 31,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(FlashRadius.xs),
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: [
          for (final mode in ThinkingMode.values)
            Expanded(
              child: FlashHover(
                onTap: () => onChanged(mode),
                borderRadius: BorderRadius.circular(6),
                builder: (hovered) {
                  final active = mode == value;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? t.raised
                          : hovered
                          ? t.surface.withValues(alpha: .6)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: active ? t.shadow1 : null,
                    ),
                    child: Text(
                      mode.label,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                        color: active ? t.text : t.text3,
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _PanelQuietButton extends StatelessWidget {
  const _PanelQuietButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return FlashHover(
      onTap: onTap,
      borderRadius: BorderRadius.circular(FlashRadius.xs),
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 31,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: hovered ? t.surface : t.surface.withValues(alpha: .55),
          borderRadius: BorderRadius.circular(FlashRadius.xs),
          border: Border.all(color: hovered ? t.borderStrong : t.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: t.text2,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Composer pieces
// ---------------------------------------------------------------------------

class _ComposerChip extends StatelessWidget {
  const _ComposerChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.chevron = false,
    this.maxLabelWidth = 220,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool chevron;
  final double maxLabelWidth;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return FlashHover(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: hovered ? t.surface3 : t.surface2,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: hovered ? t.borderStrong : t.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: t.text3),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxLabelWidth),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: t.text2,
                ),
              ),
            ),
            if (chevron) ...[
              const SizedBox(width: 4),
              Icon(
                Icons.expand_more_rounded,
                size: 13,
                color: t.text3.withValues(alpha: .7),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.streaming,
    required this.enabled,
    required this.onTap,
  });

  final bool streaming;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final active = streaming || enabled;
    return Tooltip(
      message: streaming ? '停止生成' : '发送消息',
      child: FlashHover(
        onTap: active ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        builder: (hovered) => AnimatedOpacity(
          duration: const Duration(milliseconds: 140),
          opacity: active ? 1 : .45,
          child: Transform.translate(
            offset: Offset(0, hovered && active ? -1 : 0),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 33,
              height: 33,
              decoration: BoxDecoration(
                gradient: streaming ? null : t.brandGradient,
                color: streaming ? t.danger : null,
                borderRadius: BorderRadius.circular(10),
                boxShadow: streaming
                    ? [
                        BoxShadow(
                          color: t.danger.withValues(alpha: .38),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ]
                    : t.shadowBrand,
              ),
              child: Icon(
                streaming ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                size: 17,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Small live / typing indicators
// ---------------------------------------------------------------------------

class _LiveValue extends StatelessWidget {
  const _LiveValue({required this.value, required this.unit, this.label = ''});

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Text.rich(
      TextSpan(
        children: [
          if (label.isNotEmpty)
            TextSpan(
              text: label,
              style: TextStyle(fontSize: 10.5, color: t.text3),
            ),
          TextSpan(
            text: value,
            style: TextStyle(
              fontFamily: 'SF Mono',
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: t.text2,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (unit.isNotEmpty)
            TextSpan(
              text: unit,
              style: TextStyle(fontSize: 10.5, color: t.text3),
            ),
        ],
      ),
    );
  }
}

class _Equalizer extends StatefulWidget {
  const _Equalizer();

  @override
  State<_Equalizer> createState() => _EqualizerState();
}

class _EqualizerState extends State<_Equalizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return SizedBox(
      width: 16,
      height: 12,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 4; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: Container(
                    width: 2,
                    height:
                        3 +
                        9 *
                            (0.5 +
                                0.5 *
                                    math.sin(
                                      (_controller.value * 2 * math.pi) +
                                          i * .7,
                                    )),
                    decoration: BoxDecoration(
                      color: t.brand,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return SizedBox(
      height: 22,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: t.text3.withValues(
                        alpha:
                            .3 +
                            .7 *
                                (1 -
                                    ((_controller.value + i * .15) % 1 - .5)
                                            .abs() *
                                        2),
                      ),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers and data
// ---------------------------------------------------------------------------

List<String> _metricTags(_ChatMessage message) {
  final stats = message.stats?.trim();
  if (stats != null && stats.isNotEmpty && stats != '失败') {
    final parts = stats
        .split('·')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    if (parts.isNotEmpty) return parts;
  }
  return [
    if (message.tokens != null) '${message.tokens} tokens',
    if (message.elapsed != null) '${message.elapsed!.toStringAsFixed(1)}s',
    if (message.ttft != null) '首字 ${message.ttft}ms',
  ];
}

String _messageModel(String? id) {
  if (id == null || id.trim().isEmpty) return '模型';
  return _shortModel(id);
}

String _shortModel(String id) {
  final value = id.trim();
  if (value.isEmpty) return '—';
  return value.split('/').last;
}

String _clockTime(DateTime time) {
  return '${time.hour}:${time.minute.toString().padLeft(2, '0')}';
}

String _topicFor(String text) {
  final value = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final rules = <(RegExp, String)>[
    (RegExp(r'日志|延迟|ttft|首字|log', caseSensitive: false), '推理日志排查'),
    (RegExp(r'flutter|dart|并发|下载器|代码', caseSensitive: false), 'Flutter 并发下载'),
    (RegExp(r'草稿|dflash|加速|投机', caseSensitive: false), 'DFlash2 加速原理'),
    (RegExp(r'sql|查询|索引|执行计划', caseSensitive: false), 'SQL 查询优化'),
  ];
  for (final rule in rules) {
    if (rule.$1.hasMatch(value)) return rule.$2;
  }
  return value.length > 18
      ? '${value.substring(0, 18)}…'
      : (value.isEmpty ? '新对话' : value);
}

class _ChatMessage {
  const _ChatMessage({
    required this.role,
    required this.text,
    required this.createdAt,
    this.model,
    this.stats,
    this.isError = false,
    this.tokens,
    this.elapsed,
    this.ttft,
  });

  factory _ChatMessage.fromJson(Map<String, dynamic> json) {
    return _ChatMessage(
      role: json['role'] as String? ?? 'assistant',
      text: json['text'] as String? ?? '',
      model: json['model'] as String?,
      stats: json['stats'] as String?,
      isError: json['isError'] as bool? ?? false,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      tokens: (json['tokens'] as num?)?.toInt(),
      elapsed: (json['elapsed'] as num?)?.toDouble(),
      ttft: (json['ttft'] as num?)?.toInt(),
    );
  }

  final String role;
  final String text;
  final String? model;
  final String? stats;
  final bool isError;
  final DateTime createdAt;
  final int? tokens;
  final double? elapsed;
  final int? ttft;

  _ChatMessage copyWith({
    String? text,
    String? stats,
    bool? isError,
    int? tokens,
    double? elapsed,
    int? ttft,
  }) {
    return _ChatMessage(
      role: role,
      text: text ?? this.text,
      model: model,
      stats: stats ?? this.stats,
      isError: isError ?? this.isError,
      createdAt: createdAt,
      tokens: tokens ?? this.tokens,
      elapsed: elapsed ?? this.elapsed,
      ttft: ttft ?? this.ttft,
    );
  }

  Map<String, dynamic> toJson() => {
    'role': role,
    'text': text,
    'model': model,
    'stats': stats,
    'isError': isError,
    'createdAt': createdAt.toIso8601String(),
    'tokens': tokens,
    'elapsed': elapsed,
    'ttft': ttft,
  };
}
