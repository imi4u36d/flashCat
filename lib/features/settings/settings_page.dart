import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../core/app_controller.dart';
import '../../core/runtime/runtime_updater.dart';
import '../../core/settings/app_settings.dart';
import '../../design/flash_components.dart';
import '../../design/flash_tokens.dart';

const _navItems = <({IconData icon, String label})>[
  (icon: Icons.bolt_rounded, label: '服务'),
  (icon: Icons.memory_rounded, label: '性能'),
  (icon: Icons.auto_awesome_rounded, label: '思考'),
  (icon: Icons.view_in_ar_outlined, label: '模型'),
  (icon: Icons.download_rounded, label: '运行时'),
  (icon: Icons.terminal_rounded, label: '高级'),
];

const _wideBreakpoint = 900.0;

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _port;
  late final TextEditingController _memory;
  late final TextEditingController _context;
  late final TextEditingController _model;
  late final TextEditingController _extra;
  late final TextEditingController _cache;
  late bool _autoStart;
  late bool _launchAtLogin;
  late bool _keepWeights;
  late bool _languageOnly;
  late ThinkingMode _thinking;
  late ReasoningEffort _effort;
  bool _loaded = false;
  bool _dirty = false;

  final ScrollController _scroll = ScrollController();
  final List<GlobalKey> _sectionKeys = List.generate(
    _navItems.length,
    (_) => GlobalKey(),
  );
  int _activeSection = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateActiveSection);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final settings = AppScope.of(context).settings;
    _port = TextEditingController(text: '${settings.port}');
    _memory = TextEditingController(text: settings.maxMemory);
    _context = TextEditingController(text: settings.maxContext);
    _model = TextEditingController(text: settings.model);
    _extra = TextEditingController(text: settings.extraArgs);
    _cache = TextEditingController(text: settings.hfCache);
    _autoStart = settings.autoStart;
    _launchAtLogin = settings.launchAtLogin;
    _keepWeights = settings.idleReleaseOff;
    _languageOnly = settings.languageOnly;
    _thinking = settings.thinkingMode;
    _effort = settings.reasoningEffort;
    for (final controller in [
      _port,
      _memory,
      _context,
      _model,
      _extra,
      _cache,
    ]) {
      controller.addListener(_markDirty);
    }
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_updateActiveSection)
      ..dispose();
    for (final controller in [
      _port,
      _memory,
      _context,
      _model,
      _extra,
      _cache,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  void _updateActiveSection() {
    if (!_scroll.hasClients || !mounted) return;
    var active = 0;
    for (var index = 0; index < _sectionKeys.length; index++) {
      final box = _sectionKeys[index].currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      if (box.localToGlobal(Offset.zero).dy <= 190) active = index;
    }
    final position = _scroll.position;
    if (position.hasContentDimensions &&
        position.maxScrollExtent > 0 &&
        position.pixels >= position.maxScrollExtent - 1) {
      active = _sectionKeys.length - 1;
    }
    if (active != _activeSection) {
      setState(() => _activeSection = active);
    }
  }

  void _scrollToSection(int index) {
    setState(() => _activeSection = index);
    final section = _sectionKeys[index].currentContext;
    if (section == null) return;
    Scrollable.ensureVisible(
      section,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: .02,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final controller = AppScope.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wideBreakpoint;
        final forms = _buildForms(controller);
        final scrollArea = Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: EdgeInsets.only(right: wide ? 6 : 0, bottom: 12),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: forms,
              ),
            ),
          ),
        );
        return Column(
          children: [
            Expanded(
              child: Padding(
                padding: pagePadding,
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 178,
                            child: _SettingsNav(
                              active: _activeSection,
                              onSelect: _scrollToSection,
                            ),
                          ),
                          const SizedBox(width: 20),
                          Expanded(child: scrollArea),
                        ],
                      )
                    : scrollArea,
              ),
            ),
            if (_dirty) _buildSaveBar(wide),
          ],
        );
      },
    );
  }

  Widget _buildForms(AppController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsSection(
          key: _sectionKeys[0],
          title: '服务',
          detail: '本地 OpenAI 兼容接口',
          trailing: const FlashPill(
            label: '127.0.0.1',
            tone: FlashTone.success,
            dot: true,
          ),
          children: [
            _SettingRow(
              title: '端口',
              detail: 'OpenAI 兼容接口监听的本地端口',
              control: _SettingField(
                controller: _port,
                width: 116,
                keyboardType: TextInputType.number,
              ),
            ),
            _SettingRow(
              showBorderTop: true,
              title: '随 flashCat 启动',
              detail: '打开应用时自动拉起推理服务',
              control: FlashSwitch(
                value: _autoStart,
                onChanged: (value) => setState(() {
                  _autoStart = value;
                  _dirty = true;
                }),
              ),
            ),
            _SettingRow(
              showBorderTop: true,
              title: '登录时启动',
              detail: '把 flashCat 加入 macOS 登录项',
              control: FlashSwitch(
                value: _launchAtLogin,
                onChanged: (value) => setState(() {
                  _launchAtLogin = value;
                  _dirty = true;
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 13),
        _SettingsSection(
          key: _sectionKeys[1],
          title: '性能',
          detail: '引擎资源上限与内存策略',
          children: [
            _SettingRow(
              title: '内存上限',
              detail: '传给引擎的 --max-memory，留空表示自动',
              control: _SettingField(
                controller: _memory,
                width: 116,
                hint: '例如 24G',
              ),
            ),
            _SettingRow(
              showBorderTop: true,
              title: '上下文长度',
              detail: '传给引擎的 --max-context，留空表示模型默认',
              control: _SettingField(
                controller: _context,
                width: 116,
                hint: '例如 32K',
              ),
            ),
            _SettingRow(
              showBorderTop: true,
              title: '空闲时保留权重',
              detail: '关闭空闲释放，响应更快但常驻内存',
              control: FlashSwitch(
                value: _keepWeights,
                onChanged: (value) => setState(() {
                  _keepWeights = value;
                  _dirty = true;
                }),
              ),
            ),
            _SettingRow(
              showBorderTop: true,
              title: '仅语言模型',
              detail: '跳过视觉与多模态部分，加载更快',
              control: FlashSwitch(
                value: _languageOnly,
                onChanged: (value) => setState(() {
                  _languageOnly = value;
                  _dirty = true;
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 13),
        _SettingsSection(
          key: _sectionKeys[2],
          title: '思考',
          detail: '默认推理行为与推理等级',
          children: [
            _SettingRow(
              title: '思考模式',
              detail: _thinking.detail,
              control: FlashSegmented<ThinkingMode>(
                height: 32,
                segments: [
                  for (final item in ThinkingMode.values)
                    FlashSegment(item, item.label),
                ],
                value: _thinking,
                onChanged: (value) => setState(() {
                  _thinking = value;
                  _dirty = true;
                }),
              ),
            ),
            _SettingRow(
              showBorderTop: true,
              title: '推理等级',
              detail: '仅在思考模式为“开启”时生效',
              control: _SelectBox<ReasoningEffort>(
                width: 120,
                value: _effort,
                enabled: _thinking == ThinkingMode.on,
                options: [
                  for (final item in ReasoningEffort.values)
                    FlashSegment(item, item.label),
                ],
                onChanged: (value) => setState(() {
                  _effort = value;
                  _dirty = true;
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 13),
        _SettingsSection(
          key: _sectionKeys[3],
          title: '模型',
          detail: '启动服务时默认加载的权重',
          children: [
            _SettingRow(
              title: '默认模型',
              detail: '启动服务时使用的模型 ID',
              control: _SettingField(
                controller: _model,
                width: 300,
                hint: 'owner/repo',
                mono: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 13),
        _SettingsSection(
          key: _sectionKeys[4],
          title: '运行时',
          detail: '应用内更新 splash 引擎',
          trailing: _runtimePill(controller),
          children: [
            _RuntimeRow(
              controller: controller,
              onCheck: controller.checkRuntimeUpdate,
              onInstall: controller.installRuntimeUpdate,
              onRestore: controller.restoreBundledRuntime,
            ),
          ],
        ),
        const SizedBox(height: 13),
        _SettingsSection(
          key: _sectionKeys[5],
          title: '高级',
          detail: '附加参数与下载位置',
          children: [
            _SettingRow(
              title: '额外参数',
              detail: '原样追加到命令行，支持引号',
              control: _SettingField(
                controller: _extra,
                width: 300,
                hint: '例如 --draft-window 8',
                mono: true,
              ),
            ),
            _SettingRow(
              showBorderTop: true,
              title: '下载缓存目录',
              detail: '设置 HF_HUB_CACHE，留空使用默认位置',
              control: _SettingField(
                controller: _cache,
                width: 300,
                hint: '留空使用默认目录',
              ),
            ),
            _CommandPreview(command: _previewCommand(), onCopy: _copyCommand),
            _DangerRow(onReset: _reset),
          ],
        ),
      ],
    );
  }

  Widget _runtimePill(AppController controller) {
    final state =
        controller.runtimeUpdater?.state ?? const RuntimeUpdateState();
    return switch (state.phase) {
      RuntimeUpdatePhase.upToDate || RuntimeUpdatePhase.installed =>
        const FlashPill(label: '已是最新', tone: FlashTone.success, dot: true),
      RuntimeUpdatePhase.available => const FlashPill(
        label: '可更新',
        tone: FlashTone.warning,
        dot: true,
      ),
      RuntimeUpdatePhase.failed => const FlashPill(
        label: '检查失败',
        tone: FlashTone.danger,
        dot: true,
      ),
      RuntimeUpdatePhase.checking ||
      RuntimeUpdatePhase.preparing ||
      RuntimeUpdatePhase.downloading ||
      RuntimeUpdatePhase.verifying ||
      RuntimeUpdatePhase.installing => const FlashPill(
        label: '处理中',
        tone: FlashTone.warning,
        dot: true,
      ),
      RuntimeUpdatePhase.idle => FlashPill(
        label: controller.usingManagedRuntime ? '应用内' : '内置',
        tone: FlashTone.neutral,
        dot: true,
      ),
    };
  }

  Widget _buildSaveBar(bool wide) {
    return Padding(
      padding: EdgeInsets.fromLTRB(wide ? 30 : 18, 0, wide ? 30 : 18, 16),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) => Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 10 * (1 - value)),
            child: child,
          ),
        ),
        child: _SaveBar(
          onDiscard: _discard,
          onSave: () => _save(false),
          onSaveRestart: () => _save(true),
        ),
      ),
    );
  }

  String _previewCommand() {
    final parts = [
      'splash',
      'serve',
      '--model',
      _model.text.trim().isEmpty ? '<模型>' : _model.text.trim(),
      if (int.tryParse(_port.text) != null) ...['--port', _port.text],
      if (_memory.text.trim().isNotEmpty) ...[
        '--max-memory',
        _memory.text.trim(),
      ],
      if (_context.text.trim().isNotEmpty) ...[
        '--max-context',
        _context.text.trim(),
      ],
      if (_keepWeights) ...['--idle-release', 'off'],
      if (_languageOnly) '--language-only',
      if (_thinking == ThinkingMode.off) ...[
        '--default-reasoning-effort',
        'none',
      ],
      if (_thinking == ThinkingMode.on) ...[
        '--default-reasoning-effort',
        _effort.name,
      ],
      if (_extra.text.trim().isNotEmpty) _extra.text.trim(),
    ];
    return parts.join(' ');
  }

  Future<void> _copyCommand() async {
    await Clipboard.setData(ClipboardData(text: _previewCommand()));
    if (mounted) _toast('命令已复制');
  }

  Future<void> _save(bool restart) async {
    final controller = AppScope.read(context);
    final port = int.tryParse(_port.text);
    if (port == null || port < 1024 || port > 65535) {
      _toast('端口需要是 1024 到 65535 之间的数字');
      return;
    }
    final settings = controller.settings
      ..port = port
      ..maxMemory = _memory.text.trim()
      ..maxContext = _context.text.trim()
      ..extraArgs = _extra.text
      ..hfCache = _cache.text.trim()
      ..idleReleaseOff = _keepWeights
      ..languageOnly = _languageOnly
      ..thinkingMode = _thinking
      ..reasoningEffort = _effort
      ..autoStart = _autoStart
      ..launchAtLogin = _launchAtLogin;
    final model = _model.text.trim();
    if (model.isNotEmpty) {
      settings.model = model;
      settings.rememberModel(model);
    }
    await _setLaunchAtLogin(_launchAtLogin);
    await controller.reloadModels();
    if (restart && controller.isRunning) {
      await controller.restartService();
      if (mounted) _toast('设置已保存，正在重启服务');
    } else if (mounted) {
      _toast('设置已保存');
    }
    if (mounted) setState(() => _dirty = false);
  }

  Future<void> _setLaunchAtLogin(bool enabled) async {
    if (!Platform.isMacOS) return;
    final home = Platform.environment['HOME'];
    if (home == null) return;
    final file = File('$home/Library/LaunchAgents/com.zhuo.flashcat.plist');
    try {
      if (!enabled) {
        if (file.existsSync()) await file.delete();
        return;
      }
      await file.parent.create(recursive: true);
      final executable = Platform.resolvedExecutable
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;');
      await file.writeAsString('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.zhuo.flashcat</string>
  <key>ProgramArguments</key><array><string>$executable</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
''', flush: true);
    } catch (_) {
      if (mounted) _toast('登录项设置失败，应用仍可正常使用');
    }
  }

  void _discard() {
    final settings = AppScope.read(context).settings;
    _port.text = '${settings.port}';
    _memory.text = settings.maxMemory;
    _context.text = settings.maxContext;
    _model.text = settings.model;
    _extra.text = settings.extraArgs;
    _cache.text = settings.hfCache;
    setState(() {
      _autoStart = settings.autoStart;
      _launchAtLogin = settings.launchAtLogin;
      _keepWeights = settings.idleReleaseOff;
      _languageOnly = settings.languageOnly;
      _thinking = settings.thinkingMode;
      _effort = settings.reasoningEffort;
      _dirty = false;
    });
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复默认设置？'),
        content: const Text('端口、内存与上下文上限、额外参数、缓存目录和全部开关都会恢复默认值。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _port.text = '8000';
    _memory.clear();
    _context.clear();
    _extra.clear();
    _cache.clear();
    setState(() {
      _autoStart = false;
      _launchAtLogin = false;
      _keepWeights = false;
      _languageOnly = false;
      _thinking = ThinkingMode.automatic;
      _effort = ReasoningEffort.medium;
      _dirty = true;
    });
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

class _SettingsNav extends StatelessWidget {
  const _SettingsNav({required this.active, required this.onSelect});

  final int active;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: t.surface2.withValues(alpha: .65),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < _navItems.length; index++)
            FlashHover(
              onTap: () => onSelect(index),
              borderRadius: BorderRadius.circular(7),
              builder: (hovered) {
                final selected = index == active;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  decoration: BoxDecoration(
                    color: selected
                        ? t.raised
                        : hovered
                        ? t.surface.withValues(alpha: .6)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: selected ? t.border : Colors.transparent,
                    ),
                    boxShadow: selected ? t.shadow1 : null,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _navItems[index].icon,
                        size: 14,
                        color: selected ? t.text : t.text3,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _navItems[index].label,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: selected ? t.text : t.text3,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    super.key,
    required this.title,
    required this.detail,
    required this.children,
    this.trailing,
  });

  final String title;
  final String detail;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return FlashCard(
      padding: EdgeInsets.zero,
      clip: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 13),
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
                        title,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -.1,
                          color: t.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: TextStyle(fontSize: 11, color: t.text3),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 12), trailing!],
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.title,
    required this.detail,
    required this.control,
    this.showBorderTop = false,
  });

  final String title;
  final String detail;
  final Widget control;
  final bool showBorderTop;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Container(
      constraints: const BoxConstraints(minHeight: 58),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
      decoration: showBorderTop
          ? BoxDecoration(
              border: Border(
                top: BorderSide(color: t.border.withValues(alpha: .7)),
              ),
            )
          : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final copy = _SettingCopy(title: title, detail: detail);
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                copy,
                const SizedBox(height: 9),
                Align(alignment: Alignment.centerLeft, child: control),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: copy),
              const SizedBox(width: 24),
              control,
            ],
          );
        },
      ),
    );
  }
}

class _SettingCopy extends StatelessWidget {
  const _SettingCopy({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: t.text,
          ),
        ),
        const SizedBox(height: 2),
        _SettingDescription(text: detail),
      ],
    );
  }
}

class _SettingDescription extends StatelessWidget {
  const _SettingDescription({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'`[^`]+`|--[A-Za-z0-9_-]+|HF_HUB_CACHE');
    var last = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start)));
      }
      final raw = match.group(0)!;
      final code = raw.startsWith('`') ? raw.substring(1, raw.length - 1) : raw;
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 1),
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            decoration: BoxDecoration(
              color: t.surface2,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: t.border),
            ),
            child: Text(
              code,
              style: TextStyle(
                fontFamily: 'Menlo',
                fontSize: 9.5,
                height: 1.1,
                color: t.text2,
              ),
            ),
          ),
        ),
      );
      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 10.5, height: 1.45, color: t.text3),
    );
  }
}

class _SettingField extends StatelessWidget {
  const _SettingField({
    required this.controller,
    required this.width,
    this.hint,
    this.keyboardType,
    this.mono = false,
  });

  final TextEditingController controller;
  final double width;
  final String? hint;
  final TextInputType? keyboardType;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return SizedBox(
      width: width,
      height: 32,
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        cursorColor: t.brand,
        style: TextStyle(
          fontSize: 12,
          color: t.text,
          fontFamily: mono ? 'Menlo' : null,
        ),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: TextStyle(fontSize: 12, color: t.text3),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 11,
            vertical: 8,
          ),
          fillColor: t.surface2,
          filled: true,
        ),
      ),
    );
  }
}

class _SelectBox<T> extends StatelessWidget {
  const _SelectBox({
    required this.value,
    required this.options,
    required this.onChanged,
    required this.width,
    this.enabled = true,
  });

  final T value;
  final List<FlashSegment<T>> options;
  final ValueChanged<T> onChanged;
  final double width;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final label = options.firstWhere((option) => option.value == value).label;
    return Opacity(
      opacity: enabled ? 1 : .45,
      child: PopupMenuButton<T>(
        enabled: enabled,
        tooltip: '',
        position: PopupMenuPosition.under,
        onSelected: onChanged,
        itemBuilder: (context) => [
          for (final option in options)
            PopupMenuItem<T>(
              value: option.value,
              height: 34,
              child: Text(option.label),
            ),
        ],
        child: Container(
          width: width,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            color: t.surface2,
            borderRadius: BorderRadius.circular(FlashRadius.sm),
            border: Border.all(color: t.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 12, color: t.text),
                ),
              ),
              Icon(Icons.expand_more_rounded, size: 15, color: t.text3),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Runtime
// ---------------------------------------------------------------------------

class _RuntimeRow extends StatelessWidget {
  const _RuntimeRow({
    required this.controller,
    required this.onCheck,
    required this.onInstall,
    required this.onRestore,
  });

  final AppController controller;
  final Future<void> Function() onCheck;
  final Future<void> Function() onInstall;
  final Future<void> Function() onRestore;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final state =
        controller.runtimeUpdater?.state ?? const RuntimeUpdateState();
    final version = state.version ?? controller.runtime?.version ?? '—';
    final text = switch (state.phase) {
      RuntimeUpdatePhase.idle =>
        '${controller.usingManagedRuntime ? '应用内更新' : '内置'}运行时',
      RuntimeUpdatePhase.checking => '正在检查 GitHub Release…',
      RuntimeUpdatePhase.upToDate => '已是最新版本 · ${state.version}',
      RuntimeUpdatePhase.available =>
        '可更新到 ${state.availableVersion} · 当前 ${state.version}',
      RuntimeUpdatePhase.preparing => '正在获取更新校验值…',
      RuntimeUpdatePhase.downloading =>
        '正在下载 ${state.availableVersion}'
            '${state.progress == null ? '' : ' · ${(state.progress! * 100).toStringAsFixed(0)}%'}',
      RuntimeUpdatePhase.verifying => '正在校验 SHA-256…',
      RuntimeUpdatePhase.installing => '正在解包并切换运行时…',
      RuntimeUpdatePhase.installed => 'splash ${state.version} 已启用',
      RuntimeUpdatePhase.failed => state.message ?? '更新失败',
    };
    final busy = state.busy;
    final canInstall = state.phase == RuntimeUpdatePhase.available;
    final label = switch (state.phase) {
      RuntimeUpdatePhase.available => '更新',
      RuntimeUpdatePhase.installed => '再检查',
      RuntimeUpdatePhase.failed => '重试',
      _ => '检查更新',
    };
    final icon = canInstall ? Icons.download_rounded : Icons.refresh_rounded;
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy) ...[
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: t.brand),
          ),
          const SizedBox(width: 10),
        ],
        if (controller.usingManagedRuntime) ...[
          Opacity(
            opacity: busy ? .45 : 1,
            child: FlashGhostButton(
              label: '恢复内置',
              onPressed: busy ? null : onRestore,
            ),
          ),
          const SizedBox(width: 6),
        ],
        if (canInstall)
          FlashPrimaryButton(
            label: label,
            icon: icon,
            height: 31,
            onPressed: busy ? null : onInstall,
          )
        else
          FlashQuietButton(
            label: label,
            icon: icon,
            onPressed: busy ? null : onCheck,
          ),
      ],
    );
    final copy = Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: t.brandSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.bolt_rounded, size: 18, color: t.brand),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'splash $version',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                ),
              ),
              const SizedBox(height: 1),
              Text(text, style: TextStyle(fontSize: 10.5, color: t.text3)),
              if (state.phase == RuntimeUpdatePhase.downloading &&
                  state.progress != null) ...[
                const SizedBox(height: 7),
                SizedBox(width: 160, child: FlashMeter(value: state.progress!)),
              ],
            ],
          ),
        ),
      ],
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                copy,
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(left: 48),
                  child: Align(alignment: Alignment.centerLeft, child: actions),
                ),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: copy),
              const SizedBox(width: 12),
              actions,
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Command preview + danger row
// ---------------------------------------------------------------------------

class _CommandPreview extends StatelessWidget {
  const _CommandPreview({required this.command, required this.onCopy});

  final String command;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    const headerColor = Color(0xFF8A94A8);
    const codeColor = Color(0xFFC9D5E8);
    const cmdColor = Color(0xFF8FD6FF);
    const flagColor = Color(0xFFB9A1FF);
    const valueColor = Color(0xFF8EE0B8);
    final tokens = command.split(' ');
    final spans = <TextSpan>[];
    for (var index = 0; index < tokens.length; index++) {
      final token = tokens[index];
      final color = token.startsWith('--')
          ? flagColor
          : index < 2
          ? cmdColor
          : valueColor;
      spans.add(
        TextSpan(
          text: token,
          style: TextStyle(color: color),
        ),
      );
      if (index != tokens.length - 1) {
        spans.add(const TextSpan(text: ' '));
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Container(
        decoration: BoxDecoration(
          color: t.termBg,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: Colors.white.withValues(alpha: .08)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .035),
                border: Border(
                  bottom: BorderSide(
                    color: Colors.white.withValues(alpha: .05),
                  ),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.terminal_rounded,
                    size: 12,
                    color: headerColor,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    '将执行的命令',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: .5,
                      color: headerColor,
                    ),
                  ),
                  const Spacer(),
                  _TerminalIconButton(
                    icon: Icons.copy_rounded,
                    tooltip: '复制命令',
                    onTap: onCopy,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: SelectableText.rich(
                TextSpan(
                  style: const TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 10.5,
                    height: 1.7,
                    color: codeColor,
                  ),
                  children: spans,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TerminalIconButton extends StatelessWidget {
  const _TerminalIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: FlashHover(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        builder: (hovered) => AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: hovered
                ? Colors.white.withValues(alpha: .06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            icon,
            size: 13,
            color: hovered ? const Color(0xFFDBE4F3) : const Color(0xFF8A94A8),
          ),
        ),
      ),
    );
  }
}

class _DangerRow extends StatelessWidget {
  const _DangerRow({required this.onReset});

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: t.dangerSoft,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: t.danger.withValues(alpha: .16)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final copy = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '恢复默认设置',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: t.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '端口、上限、附加参数与全部开关恢复默认值',
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.45,
                    color: t.danger.withValues(alpha: .68),
                  ),
                ),
              ],
            );
            final button = OutlinedButton(
              onPressed: onReset,
              style: OutlinedButton.styleFrom(
                foregroundColor: t.danger,
                backgroundColor: Colors.transparent,
                side: BorderSide(color: t.danger.withValues(alpha: .3)),
                minimumSize: const Size(0, 31),
                padding: const EdgeInsets.symmetric(horizontal: 11),
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
              child: const Text('恢复默认'),
            );
            if (constraints.maxWidth < 420) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [copy, const SizedBox(height: 10), button],
              );
            }
            return Row(
              children: [
                Expanded(child: copy),
                const SizedBox(width: 20),
                button,
              ],
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Save bar
// ---------------------------------------------------------------------------

class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.onDiscard,
    required this.onSave,
    required this.onSaveRestart,
  });

  final VoidCallback onDiscard;
  final VoidCallback onSave;
  final VoidCallback onSaveRestart;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: t.surface.withValues(alpha: .94),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.border),
        boxShadow: t.shadow2,
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: t.warning,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: t.warning.withValues(alpha: .18),
                  spreadRadius: 3,
                ),
              ],
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '设置已修改，尚未应用到引擎',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: t.text2),
            ),
          ),
          const SizedBox(width: 9),
          FlashQuietButton(label: '放弃', onPressed: onDiscard),
          const SizedBox(width: 6),
          FlashQuietButton(label: '保存', onPressed: onSave),
          const SizedBox(width: 6),
          FlashPrimaryButton(
            label: '保存并重启',
            height: 31,
            onPressed: onSaveRestart,
          ),
        ],
      ),
    );
  }
}
