import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/app_section.dart';
import '../../core/chat/chat_history.dart';
import '../../core/runtime/server_controller.dart';
import '../../design/flash_components.dart';
import '../../design/flash_tokens.dart';

/// The prototype uses `cubic-bezier(.2, .8, .2, 1)` for the sidebar width.
const _sidebarCurve = Cubic(.2, .8, .2, 1);

IconData appSectionIcon(AppSection section) => switch (section) {
      AppSection.overview => Icons.speed_rounded,
      AppSection.chat => Icons.chat_bubble_outline_rounded,
      AppSection.models => Icons.inventory_2_outlined,
      AppSection.logs => Icons.terminal_rounded,
      AppSection.settings => Icons.tune_rounded,
    };

const _expandedWidth = 232.0;
const _collapsedWidth = 72.0;
const _expandedContent = 208.0;
const _collapsedContent = 52.0;

/// A single-tree sidebar.
///
/// The previous implementation stacked two complete layouts (expanded and
/// compact) on top of each other and cross-faded them. During the transition
/// both highlighted pills were visible at once, which read as "two dark
/// backgrounds". This version animates one layout, so there is exactly one
/// highlight, one label and one hover surface at any time.
class AppSidebar extends StatefulWidget {
  const AppSidebar({
    super.key,
    required this.section,
    required this.collapsed,
    required this.onToggle,
  });

  final AppSection section;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  State<AppSidebar> createState() => _AppSidebarState();
}

class _AppSidebarState extends State<AppSidebar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: widget.collapsed ? 1 : 0,
  );

  @override
  void didUpdateWidget(covariant AppSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collapsed != widget.collapsed) {
      _controller.animateTo(widget.collapsed ? 1 : 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final progress = _sidebarCurve.transform(_controller.value);
        final width = lerpDouble(_expandedWidth, _collapsedWidth, progress)!;
        final pad = lerpDouble(12, 10, progress)!;
        final contentWidth = width - pad * 2;
        return Container(
          width: width,
          decoration: BoxDecoration(
            color: t.surface2.withValues(alpha: .82),
            border: Border(right: BorderSide(color: t.border)),
          ),
          child: ClipRect(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, 16, pad, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildBrand(context, progress, contentWidth),
                  _buildNavLabel(context, progress),
                  for (final item in AppSection.values)
                    _NavItem(
                      section: item,
                      selected: item == widget.section,
                      progress: progress,
                    ),
                  _RecentSection(progress: progress),
                  const Spacer(),
                  _EngineCard(collapsed: widget.collapsed),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _toggle(BuildContext context, double progress) {
    return _SidebarTip(
      message: progress > .5 ? '展开侧边栏' : '折叠侧边栏',
      hint: '⌘\\',
      child: FlashIconButton(
        icon: Icons.view_sidebar_outlined,
        onPressed: widget.onToggle,
        size: 26,
        iconSize: 15,
      ),
    );
  }

  Widget _buildBrand(BuildContext context, double progress, double contentWidth) {
    final t = context.flash;
    final expandedOpacity = (1 - progress * 2.2).clamp(0.0, 1.0);
    final compactOpacity = ((progress - .32) / .3).clamp(0.0, 1.0);

    final expanded = Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
      child: Row(
        children: [
          const FlashLogo(size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'flashCat',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.3,
                    color: t.text,
                  ),
                ),
                Text(
                  '本地推理控制台',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: .4,
                    color: t.text3,
                  ),
                ),
              ],
            ),
          ),
          _toggle(context, progress),
        ],
      ),
    );

    final compact = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const FlashLogo(size: 32),
        const SizedBox(height: 9),
        _toggle(context, progress),
      ],
    );

    final height = lerpDouble(36, 67, progress)!;
    final bottom = lerpDouble(18, 14, progress)!;
    return SizedBox(
      height: height + bottom,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            left: 0,
            top: 0,
            width: _expandedContent,
            child: IgnorePointer(
              ignoring: progress > .5,
              child: Opacity(opacity: expandedOpacity, child: expanded),
            ),
          ),
          Positioned(
            left: (contentWidth - _collapsedContent) / 2,
            top: 0,
            width: _collapsedContent,
            child: IgnorePointer(
              ignoring: progress <= .5,
              child: Opacity(opacity: compactOpacity, child: compact),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavLabel(BuildContext context, double progress) {
    final t = context.flash;
    return ClipRect(
      child: Align(
        alignment: Alignment.topLeft,
        heightFactor: (1 - progress).clamp(0.0, 1.0),
        child: Opacity(
          opacity: (1 - progress * 1.6).clamp(0.0, 1.0),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 7),
            child: Text(
              '工作区',
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
                color: t.text3,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.section,
    required this.selected,
    required this.progress,
  });

  final AppSection section;
  final bool selected;
  final double progress;


  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final controller = AppScope.of(context);
    final badge = section == AppSection.models
        ? '${controller.machineModels.length}'
        : null;
    final labelFade = (1 - progress * 1.9).clamp(0.0, 1.0);
    final miniFade = ((progress - .55) / .45).clamp(0.0, 1.0);
    final iconColor = selected ? t.brand : t.text3;
    final labelStyle = TextStyle(
      fontSize: 12.5,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      color: selected ? t.text : t.text2,
      height: 1.2,
    );

    final tile = FlashHover(
      onTap: () => appSectionNotifier.value = section,
      borderRadius: BorderRadius.circular(9),
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 38,
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: selected
              ? t.raised
              : hovered
                  ? t.surface.withValues(alpha: .55)
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: selected ? t.border : Colors.transparent),
          boxShadow: selected ? t.shadow1 : null,
        ),
        child: Stack(
          // Centre every child; the old top-left stack pushed the icon and the
          // label to the top edge of the highlighted card.
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(left: 10 * (1 - progress)),
                child: Align(
                  alignment: Alignment.lerp(
                    Alignment.centerLeft,
                    Alignment.center,
                    progress,
                  )!,
                  child: TweenAnimationBuilder<Color?>(
                    tween: ColorTween(end: iconColor),
                    duration: const Duration(milliseconds: 150),
                    builder: (context, color, _) => Icon(
                      appSectionIcon(section),
                      size: 17,
                      color: color ?? iconColor,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 37,
              right: 10,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Opacity(
                  opacity: labelFade,
                  child: Row(
                    children: [
                      Expanded(
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 150),
                          style: labelStyle,
                          child: Text(
                            section.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 8),
                        _Badge(
                          value: badge,
                          selected: selected,
                          mini: false,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (badge != null)
              Positioned(
                top: 2,
                right: 2,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: miniFade,
                    child: _Badge(
                      value: badge,
                      selected: selected,
                      mini: true,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return _SidebarTip(
      message: section.label,
      hint: '⌘${section.index + 1}',
      enabled: progress > .96,
      child: tile,
    );
  }
}

class _RecentSection extends StatelessWidget {
  const _RecentSection({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return AnimatedBuilder(
      animation: ChatHistory.instance,
      builder: (context, _) {
        final threads = ChatHistory.instance.threads;
        if (threads.isEmpty) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: Alignment.topLeft,
            heightFactor: (1 - progress).clamp(0.0, 1.0),
            child: Opacity(
              opacity: (1 - progress * 1.6).clamp(0.0, 1.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 18, 10, 7),
                    child: Text(
                      '最近',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                        color: t.text3,
                      ),
                    ),
                  ),
                  for (final thread in threads.take(3))
                    _RecentItem(thread: thread),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RecentItem extends StatelessWidget {
  const _RecentItem({required this.thread});

  final ChatThread thread;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return FlashHover(
      onTap: () {
        appSectionNotifier.value = AppSection.chat;
        ChatHistory.instance.openRequest.value = thread;
      },
      borderRadius: BorderRadius.circular(7),
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: hovered
              ? t.surface.withValues(alpha: .55)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: t.text3.withValues(alpha: .55),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                thread.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: hovered ? t.text2 : t.text3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.value,
    required this.selected,
    required this.mini,
  });

  final String value;
  final bool selected;
  final bool mini;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Container(
      constraints: BoxConstraints(minWidth: mini ? 14 : 18),
      height: mini ? 14 : 17,
      padding: EdgeInsets.symmetric(horizontal: mini ? 3 : 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? t.brandSoft : t.surface2,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(
          color: selected ? Colors.transparent : t.border,
        ),
      ),
      child: Text(
        value,
        style: TextStyle(
          fontSize: mini ? 8.5 : 10,
          fontWeight: FontWeight.w600,
          height: 1,
          color: selected ? t.brand : t.text3,
        ),
      ),
    );
  }
}

/// A floating label that matches the app surfaces instead of the stock black
/// material tooltip.
class _SidebarTip extends StatefulWidget {
  const _SidebarTip({
    required this.message,
    required this.child,
    this.detail,
    this.hint,
    this.enabled = true,
  });

  final String message;
  final String? detail;
  final String? hint;
  final bool enabled;
  final Widget child;

  @override
  State<_SidebarTip> createState() => _SidebarTipState();
}

class _SidebarTipState extends State<_SidebarTip> {
  final _portal = OverlayPortalController();
  Timer? _timer;
  Offset _position = Offset.zero;

  @override
  void didUpdateWidget(covariant _SidebarTip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _hide();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    if (!widget.enabled) return;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 240), () {
      if (!mounted || !widget.enabled || _portal.isShowing) return;
      final box = context.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final origin = box.localToGlobal(Offset.zero);
        // Place the card just outside the 72px rail, on the tile's centre line.
        _position = Offset(origin.dx + box.size.width + 10, origin.dy - 14);
      }
      _portal.show();
    });
  }

  void _hide() {
    _timer?.cancel();
    if (_portal.isShowing) _portal.hide();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _schedule(),
      onExit: (_) => _hide(),
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _buildTip,
        child: widget.child,
      ),
    );
  }

  Widget _buildTip(BuildContext context) {
    final t = context.flash;
    // Deliberately a plain Positioned overlay rather than a
    // CompositedTransformFollower: the follower's transform layer left a
    // blank rectangle over the page under the Metal/Impeller backend.
    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          builder: (context, value, child) => Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(-4 * (1 - value), 0),
              child: child,
            ),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            decoration: BoxDecoration(
              color: t.raised,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: t.borderStrong),
              boxShadow: t.shadow1,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.message,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                    color: t.text,
                  ),
                ),
                if (widget.detail != null) ...[
                  const SizedBox(width: 7),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 170),
                    child: Text(
                      widget.detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.2,
                        color: t.text3,
                      ),
                    ),
                  ),
                ],
                if (widget.hint != null) ...[
                  const SizedBox(width: 7),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: t.surface2,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: t.border),
                    ),
                    child: Text(
                      widget.hint!,
                      style: TextStyle(
                        fontFamily: 'SF Mono',
                        fontSize: 9.5,
                        height: 1.2,
                        color: t.text3,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EngineCard extends StatelessWidget {
  const _EngineCard({required this.collapsed});

  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final controller = AppScope.of(context);
    final state = controller.serverState;
    final running = state == ServerState.ready;
    final busy = state == ServerState.starting || state == ServerState.stopping;
    final speed = controller.stats?.decodeTokensPerSecond;
    final model = controller.currentModel;
    final shortModel = model.contains('/') ? model.split('/').last : model;
    final memory = controller.stats?.memoryBytes;
    final memoryTotal =
        controller.stats?.physicalMemoryBytes ?? 36 * 1024 * 1024 * 1024;

    final dotColor = switch (state) {
      ServerState.ready => t.success,
      ServerState.starting || ServerState.stopping => t.warning,
      ServerState.failed => t.danger,
      ServerState.stopped => t.text3,
    };
    final label = switch (state) {
      ServerState.ready => '运行中',
      ServerState.starting => '启动中',
      ServerState.stopping => '停止中',
      ServerState.failed => '异常',
      ServerState.stopped => '未运行',
    };

    final compact = KeyedSubtree(
      key: const ValueKey('engine-compact'),
      child: _SidebarTip(
        message: label,
        detail: shortModel.isEmpty ? null : shortModel,
        enabled: collapsed,
        child: FlashCard(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          radius: 12,
          child: Center(
            child: FlashStatusDot(color: dotColor, size: 8, pulse: busy),
          ),
        ),
      ),
    );

    final expanded = KeyedSubtree(
      key: const ValueKey('engine-expanded'),
      child: FlashCard(
        padding: const EdgeInsets.all(12),
        radius: 14,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                FlashStatusDot(color: dotColor, size: 7, pulse: busy),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: t.text2,
                  ),
                ),
                const Spacer(),
                Text(
                  speed != null && speed > 0
                      ? '${speed.toStringAsFixed(1)} tok/s'
                      : '—',
                  style: TextStyle(
                    fontFamily: 'SF Mono',
                    fontSize: 10.5,
                    color: t.text3,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              shortModel.isEmpty ? '未选择模型' : shortModel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: -.1,
                color: t.text,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'splash ${controller.runtime?.version ?? '—'} · 端口 ${controller.port}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'SF Mono',
                fontSize: 10,
                color: t.text3,
              ),
            ),
            const SizedBox(height: 9),
            FlashMeter(
              value: memory == null
                  ? 0
                  : (memory / memoryTotal).clamp(0.0, 1.0),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    memory == null
                        ? '内存 —'
                        : '内存 ${(memory / (1024 * 1024 * 1024)).toStringAsFixed(1)}'
                            ' / ${(memoryTotal / (1024 * 1024 * 1024)).round()} GB',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: t.text3),
                  ),
                ),
                FlashHover(
                  onTap: busy ? null : controller.toggleService,
                  borderRadius: BorderRadius.circular(6),
                  builder: (hovered) => Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: hovered ? t.surface2 : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: hovered ? t.borderStrong : t.border,
                      ),
                    ),
                    child: Text(
                      running || busy ? '停止' : '启动',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: t.text2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    return ClipRect(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 260),
        curve: _sidebarCurve,
        alignment: Alignment.bottomCenter,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: collapsed ? compact : expanded,
        ),
      ),
    );
  }
}
