import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../core/app_controller.dart';
import '../../core/runtime/local_api.dart';
import '../../core/runtime/server_controller.dart';
import '../../design/flash_components.dart';
import '../../design/flash_tokens.dart';

enum _LogLevel { info, warning, error }

// Terminal colours come straight from the web prototype. The terminal is
// always dark, even in light mode, so these are intentionally not themed.
abstract final class _Term {
  static const lineNo = Color(0xFF3D475C);
  static const time = Color(0xFF5B6880);
  static const info = Color(0xFF6EA8E6);
  static const warn = Color(0xFFE6B45C);
  static const error = Color(0xFFF27878);
  static const message = Color(0xFFB9C6D9);
  static const warnMessage = Color(0xFFDDC08C);
  static const errorMessage = Color(0xFFF0A3A3);
  static const empty = Color(0xFF6B7891);
  static const emptyTitle = Color(0xFF93A1B8);
  static const highlightBg = Color(0xFFFFD66B);
  static const highlightFg = Color(0xFF10131A);
  static const hover = Color(0x09FFFFFF);
}

const _monoFamily = 'Menlo';
const _monoFallback = <String>[
  'SF Mono',
  'JetBrains Mono',
  'Consolas',
  'monospace',
];

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  static final _stampPattern = RegExp(
    r'^\[?(\d{1,2}:\d{2}:\d{2}(?:[.,]\d{1,3})?)\]?\s+',
  );

  final _scroll = ScrollController();
  final _search = TextEditingController();
  final List<DateTime> _timestamps = [];

  bool _autoScroll = true;
  bool _paused = false;
  _LogLevel? _level;
  AppController? _controller;
  int _seenLogCount = 0;

  List<_LogEntry> _liveEntries = <_LogEntry>[];
  List<_LogEntry>? _pausedEntries;
  List<String>? _cacheOwner;
  String? _cacheFirstLine;
  int _cacheLength = 0;

  String? _timestampFirstLine;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = AppScope.of(context);
    if (_controller == controller) return;
    _controller = controller;
    _seenLogCount = controller.logs.length;
    _timestamps.clear();
    _resetEntryCache();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    _syncTimestamps(controller.logs);

    // Parse once and append incrementally; filtering is cheap on the parsed
    // list and the ListView below still only builds visible rows.
    final allEntries = _entriesForLive(controller.logs);
    final entries = _paused
        ? (_pausedEntries ?? const <_LogEntry>[])
        : allEntries;
    final visible = _filtered(entries);

    var infoCount = 0;
    var warnCount = 0;
    var errorCount = 0;
    for (final entry in allEntries) {
      switch (entry.level) {
        case _LogLevel.info:
          infoCount++;
        case _LogLevel.warning:
          warnCount++;
        case _LogLevel.error:
          errorCount++;
      }
    }

    if (!_paused && controller.logs.length != _seenLogCount) {
      _seenLogCount = controller.logs.length;
      if (_autoScroll) _scrollToEnd();
    }

    final stats = controller.stats;
    final model = stats?.model ?? controller.currentModel;
    final version = controller.runtime?.version;

    return Padding(
      padding: pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StatsStrip(stats: stats, model: model),
          const SizedBox(height: 12),
          Expanded(
            child: _LogPanel(
              service: controller.serverState,
              visible: visible,
              total: allEntries.length,
              infoCount: infoCount,
              warnCount: warnCount,
              errorCount: errorCount,
              search: _search,
              query: _search.text.trim(),
              level: _level,
              autoScroll: _autoScroll,
              paused: _paused,
              version: version,
              scroll: _scroll,
              onSearchChanged: (_) => setState(() {}),
              onClearSearch: () {
                _search.clear();
                setState(() {});
                if (_autoScroll) _scrollToEnd();
              },
              onLevelChanged: (value) {
                setState(() => _level = value);
                if (_autoScroll) _scrollToEnd();
              },
              onAutoScrollChanged: (value) {
                setState(() => _autoScroll = value);
                if (value) _scrollToEnd();
              },
              onTogglePause: () => _togglePause(controller),
              onCopy: visible.isEmpty ? null : () => _copyLogs(visible),
              onClear: controller.logs.isEmpty && !_paused
                  ? null
                  : () => _clearLogs(controller),
              onOpenLog: () => _openLog(controller.logFile),
              onRevealLog: () => _revealFile(controller.logFile),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Data
  // -------------------------------------------------------------------------

  List<_LogEntry> _filtered(List<_LogEntry> source) {
    final search = _search.text.trim().toLowerCase();
    return source.where((entry) {
      if (_level != null && entry.level != _level) return false;
      return search.isEmpty || entry.raw.toLowerCase().contains(search);
    }).toList();
  }

  void _syncTimestamps(List<String> logs) {
    final firstLine = logs.isEmpty ? null : logs.first;
    if (_timestampFirstLine != null && firstLine != _timestampFirstLine) {
      _timestamps.clear();
    }
    _timestampFirstLine = firstLine;
    while (_timestamps.length < logs.length) {
      _timestamps.add(DateTime.now());
    }
    if (_timestamps.length > logs.length) {
      _timestamps.removeRange(logs.length, _timestamps.length);
    }
  }

  List<_LogEntry> _entriesForLive(List<String> logs) {
    final stillAppending =
        identical(_cacheOwner, logs) &&
        logs.length >= _cacheLength &&
        (logs.isEmpty ? _cacheLength == 0 : _cacheFirstLine == logs.first);
    if (!stillAppending) {
      _liveEntries = <_LogEntry>[];
      _cacheOwner = logs;
      _cacheFirstLine = logs.isEmpty ? null : logs.first;
      _cacheLength = 0;
    }
    for (var i = _cacheLength; i < logs.length; i++) {
      final at = i < _timestamps.length ? _timestamps[i] : DateTime.now();
      _liveEntries.add(_parseLog(logs[i], i, at));
    }
    _cacheLength = logs.length;
    return _liveEntries;
  }

  void _resetEntryCache() {
    _liveEntries = <_LogEntry>[];
    _pausedEntries = null;
    _cacheOwner = null;
    _cacheFirstLine = null;
    _cacheLength = 0;
    _timestampFirstLine = null;
  }

  static _LogEntry _parseLog(String line, int index, DateTime fallback) {
    final match = _stampPattern.firstMatch(line);
    final time = match != null
        ? match.group(1)!.replaceAll(',', '.')
        : _formatClock(fallback);
    final message = match != null ? line.substring(match.end) : line;
    return _LogEntry(
      number: index + 1,
      time: time,
      level: _classify(line),
      message: message.isEmpty ? line : message,
      raw: line,
    );
  }

  static _LogLevel _classify(String line) {
    final lower = line.toLowerCase();
    if (lower.contains('error') ||
        lower.contains('fatal') ||
        lower.contains('traceback') ||
        lower.contains('失败')) {
      return _LogLevel.error;
    }
    if (lower.contains('warn') ||
        lower.contains('warning') ||
        lower.contains('deprecated')) {
      return _LogLevel.warning;
    }
    return _LogLevel.info;
  }

  static String _formatClock(DateTime date) {
    final h = date.hour.toString().padLeft(2, '0');
    final m = date.minute.toString().padLeft(2, '0');
    final s = date.second.toString().padLeft(2, '0');
    final ms = date.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  void _togglePause(AppController controller) {
    setState(() {
      if (_paused) {
        _paused = false;
        _pausedEntries = null;
        _seenLogCount = controller.logs.length;
      } else {
        _paused = true;
        _pausedEntries = List<_LogEntry>.unmodifiable(
          _entriesForLive(controller.logs),
        );
      }
    });
    if (!_paused) _scrollToEnd();
  }

  Future<void> _clearLogs(AppController controller) async {
    await controller.clearLogs();
    if (!mounted) return;
    setState(() {
      _timestamps.clear();
      _resetEntryCache();
      _seenLogCount = 0;
    });
  }

  void _copyLogs(List<_LogEntry> visible) {
    Clipboard.setData(
      ClipboardData(text: visible.map((entry) => entry.raw).join('\n')),
    );
    _toast('已复制 ${visible.length} 行日志');
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _openLog(File file) async {
    if (!file.existsSync()) {
      _toast('日志文件尚未创建');
      return;
    }
    if (Platform.isMacOS) {
      await Process.run('open', [file.path]);
    } else if (Platform.isWindows) {
      await Process.run('notepad', [file.path]);
    } else {
      await Process.run('xdg-open', [file.path]);
    }
  }

  Future<void> _revealFile(File file) async {
    if (!file.existsSync()) {
      _toast('日志文件尚未创建');
      return;
    }
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', file.path]);
    } else {
      await _openLog(file);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

class _LogEntry {
  const _LogEntry({
    required this.number,
    required this.time,
    required this.level,
    required this.message,
    required this.raw,
  });

  final int number;
  final String time;
  final _LogLevel level;
  final String message;
  final String raw;

  String get levelLabel => switch (level) {
    _LogLevel.info => 'INFO',
    _LogLevel.warning => 'WARN',
    _LogLevel.error => 'ERROR',
  };
}

// ---------------------------------------------------------------------------
// Stats strip
// ---------------------------------------------------------------------------

class _StatsStrip extends StatelessWidget {
  const _StatsStrip({required this.stats, required this.model});

  final ServerStats? stats;
  final String model;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final decode = stats?.decodeTokensPerSecond;
    final prefill = stats?.prefillTokensPerSecond;
    final completed = stats?.requestsCompleted;
    final failed = stats?.requestsFailed;
    final hasStats = stats != null;
    final failedTone = !hasStats
        ? t.text3
        : (failed ?? 0) > 0
        ? t.danger
        : t.success;

    final cells = <Widget>[
      _StatCell(
        label: '解码速度',
        value: decode == null ? '—' : flashNumber(decode, decimals: 1),
        unit: decode == null ? null : 'tok/s',
      ),
      _StatCell(
        label: '预填充',
        value: prefill == null ? '—' : flashNumber(prefill),
        unit: prefill == null ? null : 'tok/s',
      ),
      _StatCell(
        label: '完成请求',
        value: completed == null ? '—' : flashNumber(completed),
      ),
      _StatCell(
        label: '失败 / 取消',
        value: hasStats ? '${failed ?? 0}' : '—',
        valueColor: failedTone,
      ),
      _StatCell(
        label: '当前模型',
        value: model.isEmpty ? '—' : model,
        mono: true,
        tooltip: model.isEmpty ? null : model,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final showModel = width >= 900;
        if (width < 560) {
          final compact = cells.take(4).toList();
          return FlashCard(
            padding: EdgeInsets.zero,
            radius: 13,
            clip: Clip.antiAlias,
            child: Column(
              children: [
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: compact[0]),
                      Expanded(child: _cellBorder(t, compact[1], left: true)),
                    ],
                  ),
                ),
                Container(height: 1, color: t.border),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: compact[2]),
                      Expanded(child: _cellBorder(t, compact[3], left: true)),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        final visibleCells = showModel ? cells : cells.take(4).toList();
        return FlashCard(
          padding: EdgeInsets.zero,
          radius: 13,
          clip: Clip.antiAlias,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < visibleCells.length; i++)
                  Expanded(
                    flex: showModel && i == visibleCells.length - 1 ? 7 : 4,
                    child: i == 0
                        ? visibleCells[i]
                        : _cellBorder(t, visibleCells[i], left: true),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _cellBorder(FlashTokens t, Widget child, {required bool left}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: left ? t.border : Colors.transparent),
        ),
      ),
      child: child,
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({
    required this.label,
    required this.value,
    this.unit,
    this.mono = false,
    this.valueColor,
    this.tooltip,
  });

  final String label;
  final String value;
  final String? unit;
  final bool mono;
  final Color? valueColor;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final text = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 9.5, color: t.text3),
          ),
          SizedBox(height: mono ? 5 : 2),
          if (mono)
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: _monoFamily,
                fontFamilyFallback: _monoFallback,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: valueColor ?? t.text,
              ),
            )
          else
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: value,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -.5,
                      color: valueColor ?? t.text,
                    ),
                  ),
                  if (unit != null)
                    TextSpan(
                      text: ' $unit',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                        color: t.text3,
                      ),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
    if (tooltip == null) return text;
    return Tooltip(message: tooltip!, child: text);
  }
}

// ---------------------------------------------------------------------------
// Log panel
// ---------------------------------------------------------------------------

class _LogPanel extends StatelessWidget {
  const _LogPanel({
    required this.service,
    required this.visible,
    required this.total,
    required this.infoCount,
    required this.warnCount,
    required this.errorCount,
    required this.search,
    required this.query,
    required this.level,
    required this.autoScroll,
    required this.paused,
    required this.version,
    required this.scroll,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onLevelChanged,
    required this.onAutoScrollChanged,
    required this.onTogglePause,
    required this.onCopy,
    required this.onClear,
    required this.onOpenLog,
    required this.onRevealLog,
  });

  final ServerState service;
  final List<_LogEntry> visible;
  final int total;
  final int infoCount;
  final int warnCount;
  final int errorCount;
  final TextEditingController search;
  final String query;
  final _LogLevel? level;
  final bool autoScroll;
  final bool paused;
  final String? version;
  final ScrollController scroll;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;
  final ValueChanged<_LogLevel?> onLevelChanged;
  final ValueChanged<bool> onAutoScrollChanged;
  final VoidCallback onTogglePause;
  final VoidCallback? onCopy;
  final VoidCallback? onClear;
  final VoidCallback onOpenLog;
  final VoidCallback onRevealLog;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return FlashCard(
      padding: EdgeInsets.zero,
      radius: FlashRadius.lg,
      clip: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 640;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _LogToolbar(
                service: service,
                count: visible.length,
                total: total,
                infoCount: infoCount,
                warnCount: warnCount,
                errorCount: errorCount,
                search: search,
                level: level,
                autoScroll: autoScroll,
                paused: paused,
                hasSearch: query.isNotEmpty,
                onSearchChanged: onSearchChanged,
                onClearSearch: onClearSearch,
                onLevelChanged: onLevelChanged,
                onAutoScrollChanged: onAutoScrollChanged,
                onTogglePause: onTogglePause,
                onCopy: onCopy,
                onClear: onClear,
                onOpenLog: onOpenLog,
                onRevealLog: onRevealLog,
              ),
              Container(height: 1, color: t.border),
              Expanded(
                child: _LogBody(
                  entries: visible,
                  hasAnyLogs: total > 0,
                  query: query,
                  scroll: scroll,
                  compact: compact,
                ),
              ),
              Container(height: 1, color: t.border),
              _LogFooter(paused: paused, version: version),
            ],
          );
        },
      ),
    );
  }
}

class _LogToolbar extends StatelessWidget {
  const _LogToolbar({
    required this.service,
    required this.count,
    required this.total,
    required this.infoCount,
    required this.warnCount,
    required this.errorCount,
    required this.search,
    required this.level,
    required this.autoScroll,
    required this.paused,
    required this.hasSearch,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onLevelChanged,
    required this.onAutoScrollChanged,
    required this.onTogglePause,
    required this.onCopy,
    required this.onClear,
    required this.onOpenLog,
    required this.onRevealLog,
  });

  final ServerState service;
  final int count;
  final int total;
  final int infoCount;
  final int warnCount;
  final int errorCount;
  final TextEditingController search;
  final _LogLevel? level;
  final bool autoScroll;
  final bool paused;
  final bool hasSearch;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;
  final ValueChanged<_LogLevel?> onLevelChanged;
  final ValueChanged<bool> onAutoScrollChanged;
  final VoidCallback onTogglePause;
  final VoidCallback? onCopy;
  final VoidCallback? onClear;
  final VoidCallback onOpenLog;
  final VoidCallback onRevealLog;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      color: t.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final compact = width < 900;
          final denseLabels = width < 700;
          final searchWidth = width < 560 ? width : 220.0;

          final leading = <Widget>[
            _ServicePill(state: service),
            Text(
              '$count 行',
              style: TextStyle(
                fontSize: 10.5,
                color: t.text3,
                fontFamily: _monoFamily,
                fontFamilyFallback: _monoFallback,
              ),
            ),
            SizedBox(
              width: searchWidth,
              child: FlashSearchField(
                hint: '搜索日志',
                controller: search,
                onChanged: onSearchChanged,
                height: 30,
                suffix: hasSearch
                    ? FlashIconButton(
                        icon: Icons.close_rounded,
                        tooltip: '清除搜索',
                        size: 20,
                        iconSize: 12,
                        onPressed: onClearSearch,
                      )
                    : null,
              ),
            ),
            FlashSegmented<_LogLevel?>(
              value: level,
              height: 28,
              dense: true,
              onChanged: onLevelChanged,
              segments: [
                FlashSegment<_LogLevel?>(
                  null,
                  denseLabels ? '全部' : '全部 $total',
                ),
                FlashSegment<_LogLevel?>(
                  _LogLevel.info,
                  denseLabels ? '提示' : '提示 $infoCount',
                ),
                FlashSegment<_LogLevel?>(
                  _LogLevel.warning,
                  denseLabels ? '警告' : '警告 $warnCount',
                ),
                FlashSegment<_LogLevel?>(
                  _LogLevel.error,
                  denseLabels ? '错误' : '错误 $errorCount',
                ),
              ],
            ),
          ];

          final actions = _ToolbarActions(
            autoScroll: autoScroll,
            paused: paused,
            onAutoScrollChanged: onAutoScrollChanged,
            onTogglePause: onTogglePause,
            onCopy: onCopy,
            onClear: onClear,
            onOpenLog: onOpenLog,
            onRevealLog: onRevealLog,
          );

          if (!compact && width >= 920) {
            return Row(
              children: [
                for (final widget in leading) ...[
                  widget,
                  const SizedBox(width: 9),
                ],
                const Spacer(),
                actions,
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 9,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: leading,
              ),
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerLeft, child: actions),
            ],
          );
        },
      ),
    );
  }
}

class _ToolbarActions extends StatelessWidget {
  const _ToolbarActions({
    required this.autoScroll,
    required this.paused,
    required this.onAutoScrollChanged,
    required this.onTogglePause,
    required this.onCopy,
    required this.onClear,
    required this.onOpenLog,
    required this.onRevealLog,
  });

  final bool autoScroll;
  final bool paused;
  final ValueChanged<bool> onAutoScrollChanged;
  final VoidCallback onTogglePause;
  final VoidCallback? onCopy;
  final VoidCallback? onClear;
  final VoidCallback onOpenLog;
  final VoidCallback onRevealLog;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        GestureDetector(
          onSecondaryTap: onRevealLog,
          child: _ToolbarIcon(
            icon: Icons.folder_open_outlined,
            tooltip: '打开日志文件（右键在文件夹中显示）',
            onPressed: onOpenLog,
          ),
        ),
        _ToolbarIcon(
          icon: Icons.copy_rounded,
          tooltip: '复制筛选结果',
          onPressed: onCopy,
        ),
        _ToolbarIcon(
          icon: Icons.delete_outline_rounded,
          tooltip: '清空日志',
          onPressed: onClear,
        ),
        Container(
          width: 1,
          height: 18,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          color: t.border,
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('自动滚动', style: TextStyle(fontSize: 11.5, color: t.text3)),
            const SizedBox(width: 8),
            FlashSwitch(value: autoScroll, onChanged: onAutoScrollChanged),
          ],
        ),
        _ToolbarIcon(
          icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          tooltip: paused ? '继续实时输出' : '暂停实时输出',
          onPressed: onTogglePause,
          active: paused,
        ),
      ],
    );
  }
}

class _ToolbarIcon extends StatelessWidget {
  const _ToolbarIcon({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onPressed == null ? .4 : 1,
      child: FlashIconButton(
        icon: icon,
        tooltip: tooltip,
        onPressed: onPressed,
        size: 28,
        iconSize: 14,
        active: active,
        solid: true,
      ),
    );
  }
}

class _ServicePill extends StatelessWidget {
  const _ServicePill({required this.state});

  final ServerState state;

  @override
  Widget build(BuildContext context) {
    final (tone, label) = switch (state) {
      ServerState.ready => (FlashTone.success, '运行中'),
      ServerState.starting => (FlashTone.warning, '启动中'),
      ServerState.stopping => (FlashTone.warning, '停止中'),
      ServerState.failed => (FlashTone.danger, '异常'),
      ServerState.stopped => (FlashTone.neutral, '已停止'),
    };
    return FlashPill(label: label, tone: tone, dot: true);
  }
}

// ---------------------------------------------------------------------------
// Log body
// ---------------------------------------------------------------------------

class _LogBody extends StatelessWidget {
  const _LogBody({
    required this.entries,
    required this.hasAnyLogs,
    required this.query,
    required this.scroll,
    required this.compact,
  });

  final List<_LogEntry> entries;
  final bool hasAnyLogs;
  final String query;
  final ScrollController scroll;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return DecoratedBox(
      decoration: BoxDecoration(color: t.termBg),
      child: entries.isEmpty
          ? _LogEmpty(hasAnyLogs: hasAnyLogs)
          : Scrollbar(
              controller: scroll,
              child: ListView.builder(
                controller: scroll,
                padding: const EdgeInsets.only(top: 8, bottom: 14),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  return _LogRow(
                    entry: entries[index],
                    query: query,
                    compact: compact,
                  );
                },
              ),
            ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({
    required this.entry,
    required this.query,
    required this.compact,
  });

  final _LogEntry entry;
  final String query;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final levelColor = switch (entry.level) {
      _LogLevel.info => _Term.info,
      _LogLevel.warning => _Term.warn,
      _LogLevel.error => _Term.error,
    };
    final messageColor = switch (entry.level) {
      _LogLevel.info => _Term.message,
      _LogLevel.warning => _Term.warnMessage,
      _LogLevel.error => _Term.errorMessage,
    };
    final messageStyle = TextStyle(
      fontFamily: _monoFamily,
      fontFamilyFallback: _monoFallback,
      fontSize: 11.5,
      height: 1.75,
      color: messageColor,
    );

    return FlashHover(
      cursor: SystemMouseCursors.text,
      builder: (hovered) => Container(
        color: hovered ? _Term.hover : Colors.transparent,
        padding: const EdgeInsets.only(top: 1, bottom: 1, right: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: compact ? 36 : 46,
              child: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Text(
                  entry.number.toString().padLeft(3, '0'),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontFamily: _monoFamily,
                    fontFamilyFallback: _monoFallback,
                    fontSize: 11.5,
                    height: 1.75,
                    color: _Term.lineNo,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            if (!compact) ...[
              SizedBox(
                width: 96,
                child: Text(
                  entry.time,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  softWrap: false,
                  style: const TextStyle(
                    fontFamily: _monoFamily,
                    fontFamilyFallback: _monoFallback,
                    fontSize: 11.5,
                    height: 1.75,
                    color: _Term.time,
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
            SizedBox(
              width: 42,
              child: Text(
                entry.levelLabel,
                style: TextStyle(
                  fontFamily: _monoFamily,
                  fontFamilyFallback: _monoFallback,
                  fontSize: 9.5,
                  height: 1.75,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .4,
                  color: levelColor,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SelectableText.rich(
                TextSpan(
                  children: _highlightSpans(entry.message, query, messageStyle),
                ),
                style: messageStyle,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static List<TextSpan> _highlightSpans(
    String text,
    String query,
    TextStyle style,
  ) {
    if (query.isEmpty) {
      return [TextSpan(text: text, style: style)];
    }
    final lower = text.toLowerCase();
    final needle = query.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final hit = lower.indexOf(needle, start);
      if (hit < 0) break;
      if (hit > start) {
        spans.add(TextSpan(text: text.substring(start, hit), style: style));
      }
      spans.add(
        TextSpan(
          text: text.substring(hit, hit + needle.length),
          style: style.copyWith(
            color: _Term.highlightFg,
            backgroundColor: _Term.highlightBg,
          ),
        ),
      );
      start = hit + needle.length;
    }
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start), style: style));
    }
    return spans.isEmpty ? [TextSpan(text: text, style: style)] : spans;
  }
}

class _LogEmpty extends StatelessWidget {
  const _LogEmpty({required this.hasAnyLogs});

  final bool hasAnyLogs;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.terminal_rounded,
              size: 28,
              color: _Term.empty.withValues(alpha: .5),
            ),
            const SizedBox(height: 6),
            Text(
              hasAnyLogs ? '没有匹配的日志' : '还没有日志输出',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: _Term.emptyTitle,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              hasAnyLogs ? '调整搜索关键词或级别筛选后再试。' : '启动服务后，引擎日志会实时出现在这里。',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: _Term.empty),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Footer
// ---------------------------------------------------------------------------

class _LogFooter extends StatelessWidget {
  const _LogFooter({required this.paused, required this.version});

  final bool paused;
  final String? version;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final textStyle = TextStyle(fontSize: 9.5, color: t.text3);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: t.surface,
      child: Row(
        children: [
          FlashStatusDot(
            color: paused ? t.warning : t.success,
            size: 5,
            pulse: !paused,
          ),
          const SizedBox(width: 8),
          Text(paused ? '已暂停 · 显示快照' : '实时跟随 · 最新输出', style: textStyle),
          const Spacer(),
          Text('UTF-8', style: textStyle),
          const SizedBox(width: 10),
          Text('splash ${version ?? '—'}', style: textStyle),
        ],
      ),
    );
  }
}
