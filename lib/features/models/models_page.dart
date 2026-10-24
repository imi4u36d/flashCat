import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/models/model_catalog.dart';
import '../../core/runtime/server_controller.dart';
import '../../design/flash_components.dart';
import '../../design/flash_tokens.dart';

enum _ModelFilter { all, local, remote }

class _ModelEntry {
  const _ModelEntry(this.model, {this.draftRepository});

  final ModelInfo model;
  final String? draftRepository;

  bool get installed => model.origin != ModelOrigin.recommended;
}

class ModelsPage extends StatefulWidget {
  const ModelsPage({super.key});

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  final _custom = TextEditingController();
  final _search = TextEditingController();
  _ModelFilter _filter = _ModelFilter.all;
  String _query = '';

  @override
  void dispose() {
    _custom.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final catalog = controller.catalog;
    final machine = controller.machineModels;
    final recommendations = catalog?.missingRecommendations ?? const <String>[];
    final remote = recommendations.take(8).toList();

    final all = <_ModelEntry>[
      for (final model in machine)
        _ModelEntry(
          model,
          draftRepository: catalog?.draftRepository(model.id, model.family),
        ),
      for (final id in remote)
        _ModelEntry(
          ModelInfo(
            id: id,
            path: '',
            bytes: 0,
            origin: ModelOrigin.recommended,
          ),
          draftRepository: catalog?.draftRepository(id, null),
        ),
    ];

    final entries = all.where((entry) {
      if (_filter == _ModelFilter.local && !entry.installed) return false;
      if (_filter == _ModelFilter.remote && entry.installed) return false;
      return _matches(entry);
    }).toList();

    return Scrollbar(
      child: SingleChildScrollView(
        padding: pagePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ModelsToolbar(
              search: _search,
              onSearch: (value) => setState(() => _query = value),
              filter: _filter,
              onFilter: (value) => setState(() => _filter = value),
              allCount: all.length,
              state: controller.serverState,
              onOpenDirectory: () =>
                  _openDirectory(ModelCatalogService.localDirectory),
              onImport: _import,
            ),
            const SizedBox(height: 14),
            if (entries.isEmpty)
              const _EmptyModels()
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 900
                      ? 3
                      : constraints.maxWidth >= 660
                      ? 2
                      : 1;
                  return _ModelGrid(
                    columns: columns,
                    children: [
                      for (final entry in entries)
                        _ModelCard(
                          key: ValueKey(entry.model.id),
                          model: entry.model,
                          draftRepository: entry.draftRepository,
                          selected: entry.model.id == controller.currentModel,
                          contextTokens:
                              entry.model.id == controller.currentModel
                              ? controller.stats?.maximumContextTokens
                              : null,
                          onUse: () => _use(entry.model.id),
                          onReveal: entry.installed
                              ? () =>
                                    _openDirectory(Directory(entry.model.path))
                              : null,
                          onDelete: entry.model.origin == ModelOrigin.local
                              ? () => _delete(entry.model)
                              : null,
                        ),
                    ],
                  );
                },
              ),
            const SizedBox(height: 14),
            _ImportSection(
              customController: _custom,
              onApplyCustom: _applyCustom,
              recent: controller.settings.recentModels,
              onUseRecent: _use,
              onImport: _import,
            ),
          ],
        ),
      ),
    );
  }

  bool _matches(_ModelEntry entry) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    final model = entry.model;
    return model.id.toLowerCase().contains(query) ||
        _ownerOf(model).toLowerCase().contains(query) ||
        _familyOf(model).toLowerCase().contains(query);
  }

  Future<void> _applyCustom() async {
    final value = _custom.text.trim();
    if (value.isEmpty) return;
    await _use(value);
    if (mounted) _custom.clear();
  }

  Future<void> _use(String id) async {
    final controller = AppScope.read(context);
    final machine = controller.catalog?.machineModel(id);
    if (machine != null) {
      await controller.applyModel(id);
      if (mounted) _toast(id == controller.currentModel ? '已切换模型' : '正在切换模型');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _ConfirmDialog(
        icon: Icons.download_rounded,
        title: '下载这个模型？',
        message: '$id\n\n模型会下载到 ~/.flashcat/models，可能需要几十 GB 磁盘空间。',
        confirmLabel: '下载',
      ),
    );
    if (confirmed != true || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DownloadDialog(modelId: id),
    );
  }

  Future<void> _import() async {
    final source = await getDirectoryPath(
      confirmButtonText: '选择模型文件夹',
      initialDirectory: Directory.current.path,
    );
    if (source == null || !mounted) return;
    final directory = Directory(source);
    final mode = await showDialog<bool>(
      context: context,
      builder: (context) => _ConfirmDialog(
        icon: Icons.folder_open_rounded,
        title: '导入模型',
        message:
            '${directory.path}\n\n“移动到模型目录”适合同盘整理；“复制”会保留原文件。'
            '大模型可能需要较长时间。',
        extraLabel: '复制',
        extraValue: false,
        confirmLabel: '移动',
      ),
    );
    if (mode == null || !mounted) return;
    final result = await showDialog<ModelImportResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ImportDialog(directory: directory, move: mode),
    );
    if (result != null && mounted) {
      _toast('已导入 ${result.id}');
      await _use(result.id);
    }
  }

  Future<void> _delete(ModelInfo model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _ConfirmDialog(
        icon: Icons.delete_outline_rounded,
        title: '删除本地模型？',
        message: '${model.id}\n\n这会删除 ${model.sizeText} 的权重，无法撤销。',
        confirmLabel: '删除',
        danger: true,
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await AppScope.read(context).deleteModel(model);
      if (mounted) _toast('已删除 ${model.id}');
    } catch (error) {
      if (mounted) _toast('删除失败：$error');
    }
  }

  Future<void> _openDirectory(Directory directory) async {
    await directory.create(recursive: true);
    final command = switch (Platform.operatingSystem) {
      'macos' => 'open',
      'windows' => 'explorer',
      _ => 'xdg-open',
    };
    await Process.run(command, [directory.path]);
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

// ---------------------------------------------------------------------------
// Toolbar
// ---------------------------------------------------------------------------

class _ModelsToolbar extends StatelessWidget {
  const _ModelsToolbar({
    required this.search,
    required this.onSearch,
    required this.filter,
    required this.onFilter,
    required this.allCount,
    required this.state,
    required this.onOpenDirectory,
    required this.onImport,
  });

  final TextEditingController search;
  final ValueChanged<String> onSearch;
  final _ModelFilter filter;
  final ValueChanged<_ModelFilter> onFilter;
  final int allCount;
  final ServerState state;
  final VoidCallback onOpenDirectory;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final searchField = FlashSearchField(
      hint: '搜索模型、机构或参数规模',
      controller: search,
      onChanged: onSearch,
      height: 38,
    );
    final segmented = FlashSegmented<_ModelFilter>(
      segments: [
        FlashSegment(_ModelFilter.all, '全部 $allCount'),
        const FlashSegment(_ModelFilter.local, '本机'),
        const FlashSegment(_ModelFilter.remote, '可下载'),
      ],
      value: filter,
      onChanged: onFilter,
      height: 36,
    );
    final status = _ServiceStatus(state: state);
    final openButton = FlashIconButton(
      icon: Icons.folder_open_rounded,
      tooltip: '打开模型目录',
      solid: true,
      size: 34,
      iconSize: 16,
      onPressed: onOpenDirectory,
    );
    final importButton = FlashPrimaryButton(
      label: '导入模型',
      icon: Icons.download_rounded,
      onPressed: onImport,
      height: 34,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 900) {
          return Row(
            children: [
              Expanded(child: searchField),
              const SizedBox(width: 10),
              segmented,
              const SizedBox(width: 10),
              status,
              const SizedBox(width: 12),
              openButton,
              const SizedBox(width: 8),
              importButton,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            searchField,
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                segmented,
                if (constraints.maxWidth >= 620) status,
                openButton,
                importButton,
              ],
            ),
          ],
        );
      },
    );
  }
}

class _ServiceStatus extends StatelessWidget {
  const _ServiceStatus({required this.state});

  final ServerState state;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final busy = state == ServerState.starting || state == ServerState.stopping;
    final (color, label) = switch (state) {
      ServerState.ready => (t.success, '运行中'),
      ServerState.starting => (t.warning, '启动中'),
      ServerState.stopping => (t.warning, '停止中'),
      ServerState.failed => (t.danger, '异常'),
      ServerState.stopped => (t.text3, '未运行'),
    };
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(FlashRadius.sm),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FlashStatusDot(color: color, size: 7, pulse: busy),
          const SizedBox(width: 7),
          Text(label, style: TextStyle(fontSize: 11, color: t.text3)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Grid + model card
// ---------------------------------------------------------------------------

class _ModelGrid extends StatelessWidget {
  const _ModelGrid({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var start = 0; start < children.length; start += columns) {
      final end = math.min(start + columns, children.length);
      final cells = <Widget>[];
      for (var index = 0; index < columns; index++) {
        if (index > 0) cells.add(const SizedBox(width: 12));
        cells.add(
          Expanded(
            child: start + index < end
                ? children[start + index]
                : const SizedBox.shrink(),
          ),
        );
      }
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 12));
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: cells,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

class _EmptyModels extends StatelessWidget {
  const _EmptyModels();

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 44),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.surface.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(FlashRadius.lg),
        border: Border.all(color: t.border),
      ),
      child: Text(
        '没有匹配的模型。试试别的关键词，或切换到「可下载」。',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: t.text3),
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    super.key,
    required this.model,
    required this.draftRepository,
    required this.selected,
    required this.contextTokens,
    required this.onUse,
    required this.onReveal,
    required this.onDelete,
  });

  final ModelInfo model;
  final String? draftRepository;
  final bool selected;
  final int? contextTokens;
  final VoidCallback onUse;
  final VoidCallback? onReveal;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final local = model.origin == ModelOrigin.local;
    final splash = model.origin == ModelOrigin.splash;
    final installed = model.origin != ModelOrigin.recommended;
    final draftReady = installed && model.draftPath != null;
    final family = _familyOf(model);
    final params = _paramText(model);
    final active = _activeParams(model);
    final quant = _quantText(model);
    final displayName = _displayName(model);

    final avatarIndex = _avatarIndex(model.id);
    final tags = <Widget>[
      if (draftReady)
        const _ModelTag('DFlash2 就绪', tone: FlashTone.success)
      else if (draftRepository != null)
        const _ModelTag('DFlash2 可下载', tone: FlashTone.brand)
      else
        const _ModelTag('标准解码'),
      if (model.mmprojPath != null)
        const _ModelTag('视觉', tone: FlashTone.brand),
      if (family == 'MoE') const _ModelTag('MoE', tone: FlashTone.brand),
      if (model.bytes > 0 && model.bytes < 6 * 1000 * 1000 * 1000)
        const _ModelTag('轻量'),
      if (local) const _ModelTag('本机'),
      if (splash) const _ModelTag('Splash'),
    ];

    final specs = <Widget>[
      if (params != null) _SpecText(params, bold: true),
      if (active != null) _SpecText('$active 激活'),
      if (model.bytes > 0) _SpecText(model.sizeText),
      if (quant.isNotEmpty && quant != family) _SpecText(quant),
      _SpecText(family),
      if (contextTokens != null)
        _SpecText('${_shortTokens(contextTokens!)} 上下文'),
    ];

    final actions = installed
        ? Row(
            children: [
              Expanded(
                child: _WideButton(
                  label: selected ? '使用中' : '使用',
                  icon: selected
                      ? Icons.check_rounded
                      : Icons.play_arrow_rounded,
                  onPressed: selected ? null : onUse,
                ),
              ),
              if (onReveal != null) ...[
                const SizedBox(width: 5),
                _CardIconButton(
                  icon: Icons.folder_open_rounded,
                  tooltip: '在文件管理器中显示',
                  onPressed: onReveal,
                ),
              ],
              if (onDelete != null) ...[
                const SizedBox(width: 5),
                _CardIconButton(
                  icon: Icons.delete_outline_rounded,
                  tooltip: '删除模型',
                  danger: true,
                  onPressed: onDelete,
                ),
              ],
            ],
          )
        : _WideButton(
            label: '下载',
            icon: Icons.download_rounded,
            download: true,
            onPressed: onUse,
          );

    return FlashHover(
      cursor: SystemMouseCursors.basic,
      borderRadius: BorderRadius.circular(15),
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        transform: Matrix4.translationValues(0, hovered ? -2 : 0, 0),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? null : t.surface,
          gradient: selected
              ? RadialGradient(
                  center: const Alignment(1.05, -1),
                  radius: 1.5,
                  colors: [Color.alphaBlend(t.brandSoft, t.surface), t.surface],
                  stops: const [0, .72],
                )
              : null,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: selected
                ? t.brand.withValues(alpha: .4)
                : hovered
                ? t.borderStrong
                : t.border,
          ),
          boxShadow: hovered ? t.shadow2 : t.shadow1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ModelAvatar(
                      label: _avatarLabel(displayName),
                      index: avatarIndex,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Tooltip(
                            message: model.id,
                            waitDuration: const Duration(milliseconds: 400),
                            child: Text(
                              displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -.15,
                                height: 1.3,
                                color: t.text,
                              ),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _ownerOf(model),
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
                    if (selected) ...[
                      const SizedBox(width: 8),
                      const FlashPill(
                        label: '使用中',
                        tone: FlashTone.success,
                        icon: Icons.check_rounded,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 11),
                Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: specs,
                ),
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(spacing: 4, runSpacing: 4, children: tags),
                ],
              ],
            ),
            Padding(padding: const EdgeInsets.only(top: 11), child: actions),
          ],
        ),
      ),
    );
  }
}

class _SpecText extends StatelessWidget {
  const _SpecText(this.label, {this.bold = false});

  final String label;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Text(
      label,
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
        color: bold ? t.text2 : t.text3,
      ),
    );
  }
}

class _ModelTag extends StatelessWidget {
  const _ModelTag(this.label, {this.tone = FlashTone.neutral});

  final String label;
  final FlashTone tone;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final neutral = tone == FlashTone.neutral;
    return Container(
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: neutral ? t.surface2 : tone.soft(t),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: neutral ? t.border : Colors.transparent),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w500,
              color: neutral ? t.text3 : tone.fg(t),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelAvatar extends StatelessWidget {
  const _ModelAvatar({required this.label, required this.index});

  final String label;
  final int index;

  static const _gradients = <List<Color>>[
    [Color(0xFF6558F5), Color(0xFF06B6D4)],
    [Color(0xFFF09A4A), Color(0xFFF2C14E)],
    [Color(0xFF3A8EF6), Color(0xFF36D1DC)],
    [Color(0xFFEF6BA8), Color(0xFFB06BFF)],
    [Color(0xFF64748B), Color(0xFF94A3B8)],
  ];

  @override
  Widget build(BuildContext context) {
    final pair = _gradients[index % _gradients.length];
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: pair,
        ),
        borderRadius: BorderRadius.circular(11),
        boxShadow: index == 4
            ? null
            : [
                BoxShadow(
                  color: pair.first.withValues(alpha: .42),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w700,
          letterSpacing: -.3,
          height: 1,
        ),
      ),
    );
  }
}

class _WideButton extends StatelessWidget {
  const _WideButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.download = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool download;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final enabled = onPressed != null;
    final downloadColor = Color.alphaBlend(t.brandSoft, t.surface);
    return FlashHover(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onTap: onPressed,
      borderRadius: BorderRadius.circular(9),
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 30,
        decoration: BoxDecoration(
          color: download
              ? (hovered
                    ? Color.alphaBlend(
                        t.brand.withValues(alpha: .16),
                        t.surface,
                      )
                    : downloadColor)
              : enabled
              ? (hovered ? t.surface2 : t.surface)
              : t.surface,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: download
                ? (hovered
                      ? t.brand.withValues(alpha: .38)
                      : t.brand.withValues(alpha: .24))
                : enabled
                ? (hovered ? t.borderStrong : t.border)
                : t.border,
          ),
        ),
        child: Opacity(
          opacity: enabled ? 1 : .7,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 14,
                color: download ? t.brand : (enabled ? t.text2 : t.text3),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: download ? t.brand : (enabled ? t.text : t.text3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardIconButton extends StatelessWidget {
  const _CardIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.danger = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final button = FlashHover(
      cursor: SystemMouseCursors.click,
      onTap: onPressed,
      borderRadius: BorderRadius.circular(9),
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: hovered ? (danger ? t.dangerSoft : t.surface2) : t.surface,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: danger && hovered
                ? t.danger.withValues(alpha: .3)
                : hovered
                ? t.borderStrong
                : t.border,
          ),
        ),
        child: Icon(
          icon,
          size: 15,
          color: danger && hovered ? t.danger : t.text2,
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

// ---------------------------------------------------------------------------
// Import local / custom model id
// ---------------------------------------------------------------------------

class _ImportSection extends StatelessWidget {
  const _ImportSection({
    required this.customController,
    required this.onApplyCustom,
    required this.recent,
    required this.onUseRecent,
    required this.onImport,
  });

  final TextEditingController customController;
  final VoidCallback onApplyCustom;
  final List<String> recent;
  final ValueChanged<String> onUseRecent;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final dropzone = _Dropzone(onTap: onImport);
    final custom = _CustomModelCard(
      controller: customController,
      onApply: onApplyCustom,
      recent: recent,
      onUseRecent: onUseRecent,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [dropzone, const SizedBox(height: 12), custom],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 4, child: dropzone),
              const SizedBox(width: 12),
              Expanded(flex: 5, child: custom),
            ],
          ),
        );
      },
    );
  }
}

class _Dropzone extends StatelessWidget {
  const _Dropzone({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final base = Color.alphaBlend(t.surface.withValues(alpha: .55), t.bg);
    return FlashHover(
      onTap: onTap,
      borderRadius: BorderRadius.circular(FlashRadius.lg),
      builder: (hovered) => CustomPaint(
        foregroundPainter: _DashedBorderPainter(
          color: hovered
              ? t.brand.withValues(alpha: .85)
              : t.text3.withValues(alpha: .34),
          radius: FlashRadius.lg,
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          constraints: const BoxConstraints(minHeight: 186),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 26),
          decoration: BoxDecoration(
            color: hovered ? Color.alphaBlend(t.brandSoft, t.bg) : base,
            borderRadius: BorderRadius.circular(FlashRadius.lg),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: t.brandSoft,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  Icons.folder_open_rounded,
                  size: 18,
                  color: t.brand,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '导入本地模型',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                ),
              ),
              const SizedBox(height: 4),
              Text.rich(
                TextSpan(
                  style: TextStyle(fontSize: 11, color: t.text3, height: 1.5),
                  children: const [
                    TextSpan(text: '点击选择包含 '),
                    TextSpan(
                      text: '.gguf',
                      style: TextStyle(fontFamily: 'SF Mono', fontSize: 10.5),
                    ),
                    TextSpan(text: ' 或 MLX 权重的文件夹。'),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                '支持 safetensors · gguf · 自动识别草稿模型',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 9.5, color: t.text3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(.75, .75, size.width - 1.5, size.height - 1.5),
          Radius.circular(radius),
        ),
      );
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = math.min(distance + 6, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance += 11;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}

class _CustomModelCard extends StatelessWidget {
  const _CustomModelCard({
    required this.controller,
    required this.onApply,
    required this.recent,
    required this.onUseRecent,
  });

  final TextEditingController controller;
  final VoidCallback onApply;
  final List<String> recent;
  final ValueChanged<String> onUseRecent;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final recentItems = recent.take(3).toList();
    return FlashCard(
      padding: const EdgeInsets.fromLTRB(18, 17, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: FlashSectionHeader(
                  title: '自定义模型 ID',
                  subtitle: '填写 Hub 上的 owner/repo，确认后下载',
                  titleSize: 13,
                ),
              ),
              const SizedBox(width: 8),
              FlashPill(
                label: 'Hub',
                tone: FlashTone.neutral,
                icon: Icons.view_in_ar_outlined,
              ),
            ],
          ),
          const SizedBox(height: 13),
          Row(
            children: [
              Expanded(
                child: _ModelTextField(
                  controller: controller,
                  hint: 'owner/repo，例如 mlx-community/Qwen3.8-27B-4bit',
                  onSubmitted: (_) => onApply(),
                ),
              ),
              const SizedBox(width: 8),
              FlashPrimaryButton(label: '使用', onPressed: onApply, height: 36),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            '支持 owner/repo:VARIANT 形式，下载位置可在设置中修改。',
            style: TextStyle(fontSize: 9.5, color: t.text3),
          ),
          if (recentItems.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.only(top: 11),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: t.border)),
              ),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('最近使用', style: TextStyle(fontSize: 10, color: t.text3)),
                  for (final id in recentItems)
                    _MiniModelButton(
                      label: id.split('/').last.split(':').first,
                      onTap: () => onUseRecent(id),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModelTextField extends StatefulWidget {
  const _ModelTextField({
    required this.controller,
    required this.hint,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onSubmitted;

  @override
  State<_ModelTextField> createState() => _ModelTextFieldState();
}

class _ModelTextFieldState extends State<_ModelTextField> {
  late final FocusNode _focus = FocusNode()..addListener(_handleFocus);
  bool _focused = false;

  void _handleFocus() {
    if (_focused == _focus.hasFocus) return;
    setState(() => _focused = _focus.hasFocus);
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_handleFocus)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(FlashRadius.sm),
      borderSide: BorderSide(color: _focused ? t.brand : t.border),
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      height: 36,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(FlashRadius.sm),
        boxShadow: _focused
            ? [BoxShadow(color: t.brandSoft, spreadRadius: 3)]
            : null,
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        onSubmitted: widget.onSubmitted,
        maxLines: 1,
        style: TextStyle(fontSize: 12.5, color: t.text),
        cursorColor: t.brand,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: _focused ? t.surface : t.surface2,
          hintText: widget.hint,
          hintStyle: TextStyle(fontSize: 12.5, color: t.text3),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 11,
            vertical: 8,
          ),
          border: border,
          enabledBorder: border,
          focusedBorder: border,
          disabledBorder: border,
        ),
      ),
    );
  }
}

class _MiniModelButton extends StatelessWidget {
  const _MiniModelButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return FlashHover(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: t.surface2,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: hovered ? t.borderStrong : t.border),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 10, color: hovered ? t.text : t.text2),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------------

class _DialogShell extends StatelessWidget {
  const _DialogShell({required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(FlashRadius.xl),
            border: Border.all(color: t.border),
            boxShadow: t.shadow2,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({
    required this.icon,
    required this.title,
    this.subtitle,
    this.tone = FlashTone.brand,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final FlashTone tone;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final color = danger ? t.danger : tone.fg(t);
    final soft = danger ? t.dangerSoft : tone.soft(t);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: soft,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, size: 18, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.2,
                  height: 1.35,
                  color: t.text,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'SF Mono',
                    fontSize: 10,
                    height: 1.45,
                    color: t.text3,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    required this.icon,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.extraLabel,
    this.extraValue,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final String confirmLabel;
  final String? extraLabel;
  final bool? extraValue;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return _DialogShell(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DialogHeader(
            icon: icon,
            title: title,
            danger: danger,
            tone: danger ? FlashTone.danger : FlashTone.brand,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: TextStyle(fontSize: 12.5, height: 1.55, color: t.text2),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FlashQuietButton(
                label: '取消',
                height: 34,
                onPressed: () => Navigator.pop(context, null),
              ),
              if (extraLabel != null) ...[
                const SizedBox(width: 6),
                FlashQuietButton(
                  label: extraLabel!,
                  height: 34,
                  onPressed: () => Navigator.pop(context, extraValue),
                ),
              ],
              const SizedBox(width: 8),
              if (danger)
                _DangerButton(
                  label: confirmLabel,
                  onPressed: () => Navigator.pop(context, true),
                )
              else
                FlashPrimaryButton(
                  label: confirmLabel,
                  height: 34,
                  onPressed: () => Navigator.pop(context, true),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DangerButton extends StatelessWidget {
  const _DangerButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return FlashHover(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(FlashRadius.sm),
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: hovered ? Color.lerp(t.danger, Colors.black, .08) : t.danger,
          borderRadius: BorderRadius.circular(FlashRadius.sm),
          boxShadow: hovered
              ? [
                  BoxShadow(
                    color: t.danger.withValues(alpha: .32),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      decoration: BoxDecoration(
        color: t.dangerSoft,
        borderRadius: BorderRadius.circular(FlashRadius.sm),
        border: Border.all(color: t.danger.withValues(alpha: .3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 15, color: t.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, height: 1.5, color: t.danger),
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog({required this.modelId});

  final String modelId;

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  String _message = '正在准备…';
  String? _error;
  bool _done = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _run();
  }

  Future<void> _run() async {
    try {
      await AppScope.read(context).downloadModel(widget.modelId);
      if (!mounted) return;
      setState(() {
        _done = true;
        _message = '下载完成';
      });
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final t = context.flash;
    final lines = controller.logs;
    final last = lines.isEmpty ? _message : lines.last;
    return _DialogShell(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DialogHeader(
            icon: _done ? Icons.check_rounded : Icons.download_rounded,
            title: _done ? '模型已就绪' : '正在下载模型',
            subtitle: widget.modelId,
            tone: _done ? FlashTone.success : FlashTone.brand,
          ),
          const SizedBox(height: 16),
          if (_error == null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: _done ? 1 : null,
                minHeight: 5,
                backgroundColor: t.surface3,
                color: t.brand,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: t.surface2,
                borderRadius: BorderRadius.circular(FlashRadius.sm),
                border: Border.all(color: t.border),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.terminal_rounded, size: 13, color: t.text3),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      last,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'SF Mono',
                        fontSize: 10.5,
                        height: 1.5,
                        color: t.text3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (_done) ...[
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: t.brand,
                    ),
                  ),
                  const SizedBox(width: 7),
                ],
                Expanded(
                  child: Text(
                    _done ? '下载完成，正在切换模型…' : '下载完成后会自动切换到该模型',
                    style: TextStyle(fontSize: 10.5, color: t.text3),
                  ),
                ),
              ],
            ),
          ] else ...[
            _ErrorBox(_error!),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: FlashQuietButton(
                label: '关闭',
                height: 34,
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.directory, required this.move});

  final Directory directory;
  final bool move;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  double _progress = 0;
  String _message = '正在准备…';
  String? _error;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _run();
  }

  Future<void> _run() async {
    try {
      final result = await AppScope.read(context).importModel(
        widget.directory,
        move: widget.move,
        onProgress: (fraction, message) {
          if (mounted) {
            setState(() {
              _progress = fraction;
              _message = message;
            });
          }
        },
      );
      if (mounted) Navigator.pop(context, result);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final percent = (_progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0);
    return _DialogShell(
      width: 500,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DialogHeader(
            icon: Icons.folder_open_rounded,
            title: widget.move ? '正在移动模型' : '正在复制模型',
            subtitle: widget.directory.path,
          ),
          const SizedBox(height: 16),
          if (_error == null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  percent,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.6,
                    height: 1,
                    color: t.text,
                  ),
                ),
                const SizedBox(width: 2),
                Text('%', style: TextStyle(fontSize: 11, color: t.text3)),
                const Spacer(),
                FlashPill(
                  label: widget.move ? '移动' : '复制',
                  tone: FlashTone.neutral,
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: _progress.clamp(0.0, 1.0).toDouble(),
                minHeight: 6,
                backgroundColor: t.surface3,
                color: t.brand,
              ),
            ),
            const SizedBox(height: 9),
            Text(
              _message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, height: 1.5, color: t.text3),
            ),
          ] else ...[
            _ErrorBox(_error!),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: FlashQuietButton(
                label: '关闭',
                height: 34,
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Model metadata helpers
// ---------------------------------------------------------------------------

String _ownerOf(ModelInfo model) {
  if (model.id.contains('/')) return model.id.split('/').first;
  return switch (model.origin) {
    ModelOrigin.local => 'flashCat',
    ModelOrigin.splash => 'Splash',
    ModelOrigin.recommended => 'Hub',
  };
}

String _displayName(ModelInfo model) => model.shortName.split(':').first;

String? _paramText(ModelInfo model) {
  final match = RegExp(
    r'(\d+(?:\.\d+)?)\s*B(?![a-zA-Z])',
    caseSensitive: false,
  ).firstMatch(model.shortName);
  if (match == null) return null;
  return '${match.group(1)}B';
}

String? _activeParams(ModelInfo model) {
  final match = RegExp(
    r'A(\d+(?:\.\d+)?)B',
    caseSensitive: false,
  ).firstMatch(model.id);
  if (match == null) return null;
  return '${match.group(1)}B';
}

String _familyOf(ModelInfo model) {
  final id = model.id.toLowerCase();
  if (id.contains('gguf')) return 'GGUF';
  if (RegExp(r'a\d+(?:\.\d+)?b').hasMatch(id) || id.contains('moe')) {
    return 'MoE';
  }
  return 'Dense';
}

String _quantText(ModelInfo model) {
  final name = model.shortName;
  final variant = RegExp(
    r'(UD-Q\d+[A-Za-z0-9_]*)',
    caseSensitive: false,
  ).firstMatch(name);
  if (variant != null) return variant.group(1)!.toUpperCase();
  final bits = RegExp(
    r'(\d+)\s*-?\s*bit',
    caseSensitive: false,
  ).firstMatch(name);
  if (bits != null) return '${bits.group(1)}-bit';
  if (model.id.toLowerCase().contains('gguf')) return 'GGUF';
  return '';
}

String _avatarLabel(String name) {
  final letter = RegExp(r'[A-Za-z]').firstMatch(name);
  var label = letter?.group(0)?.toUpperCase() ?? '#';
  final singleDigitParam = RegExp(r'-(\d)B(?:-|$)').firstMatch(name);
  if (singleDigitParam != null) {
    label += singleDigitParam.group(1)!;
  }
  return label;
}

int _avatarIndex(String id) {
  var hash = 0;
  for (final unit in id.codeUnits) {
    hash = (hash + unit * 31) % 5;
  }
  return hash;
}

String _shortTokens(int tokens) {
  if (tokens >= 1000) {
    final value = tokens / 1000;
    return value >= 100
        ? '${value.toStringAsFixed(0)}K'
        : '${value.toStringAsFixed(value >= 10 ? 0 : 1)}K';
  }
  return '$tokens';
}
