import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../core/app_controller.dart';
import '../../core/models/model_catalog.dart';
import '../../core/runtime/local_api.dart';
import '../../core/runtime/server_controller.dart';
import '../../design/flash_components.dart';
import '../../design/flash_tokens.dart';

class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key});

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  static const _maxSamples = 300;

  final List<double> _throughput = [];
  Timer? _timer;
  AppController? _controller;
  int _range = 45;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = AppScope.of(context);
    if (_controller == controller) return;
    _controller?.removeListener(_sample);
    _controller = controller..addListener(_sample);
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => _sample());
  }

  void _sample() {
    if (!mounted) return;
    final rate = _controller?.stats?.decodeTokensPerSecond ?? 0;
    if (rate <= 0) {
      setState(() {});
      return;
    }
    if (_throughput.length >= _maxSamples) _throughput.removeAt(0);
    _throughput.add(rate);
    setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_sample);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final stats = controller.stats;
    final state = controller.serverState;
    final local = controller.catalog?.localModel(controller.currentModel);

    return Scrollbar(
      child: SingleChildScrollView(
        padding: pagePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (controller.startupError != null) ...[
              _StartupError(message: controller.startupError!),
              const SizedBox(height: 14),
            ],
            _ServiceHero(
              controller: controller,
              stats: stats,
              local: local,
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 900;
                final chart = _ThroughputCard(
                  values: _throughput,
                  ready: state == ServerState.ready,
                  range: _range,
                  onRangeChanged: (value) => setState(() => _range = value),
                );
                final side = _OverviewSide(
                  controller: controller,
                  stats: stats,
                  wide: wide,
                );
                if (!wide) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(height: 420, child: chart),
                      const SizedBox(height: 14),
                      side,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 16,
                      child: SizedBox(height: 552, child: chart),
                    ),
                    const SizedBox(width: 14),
                    Expanded(flex: 10, child: side),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hero
// ---------------------------------------------------------------------------

class _ServiceHero extends StatelessWidget {
  const _ServiceHero({
    required this.controller,
    required this.stats,
    required this.local,
  });

  final AppController controller;
  final ServerStats? stats;
  final ModelInfo? local;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final state = controller.serverState;
    final running = state == ServerState.ready;
    final busy = state == ServerState.starting || state == ServerState.stopping;
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
    final speed = stats?.decodeTokensPerSecond;
    final model = controller.currentModel;
    final title = _modelTitle(model);
    final quant = _modelQuant(model);
    final device = stats?.deviceName ?? Platform.localHostname;
    final deviceLine = stats?.gpuCores == null
        ? device
        : '$device · ${stats!.gpuCores} 核 GPU';

    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(FlashRadius.xl),
        border: Border.all(color: t.border),
        boxShadow: t.shadow1,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          const Positioned.fill(child: IgnorePointer(child: FlashHeroGlow())),
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final showGauge = constraints.maxWidth >= 700;
                final copy = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        FlashStatusDot(
                          color: dotColor,
                          size: 7,
                          pulse: busy,
                        ),
                        const SizedBox(width: 7),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: t.text2,
                          ),
                        ),
                        _dot(context),
                        Text(
                          speed == null || speed <= 0
                              ? '— tok/s'
                              : '${speed.toStringAsFixed(1)} tok/s',
                          style: TextStyle(fontSize: 12, color: t.text2),
                        ),
                        _dot(context),
                        Text(
                          '${stats?.activeRequests ?? 0} 个请求',
                          style: TextStyle(fontSize: 12, color: t.text2),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    RichText(
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: title,
                            style: TextStyle(
                              fontSize: title.length > 24
                                  ? 28
                                  : title.length > 18
                                      ? 33
                                      : 40,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -1.2,
                              height: 1.04,
                              color: t.text,
                            ),
                          ),
                          if (quant.isNotEmpty)
                            TextSpan(
                              text: '  $quant',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                letterSpacing: -.2,
                                color: t.text3,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      model.isEmpty ? '尚未选择模型' : model,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'SF Mono',
                        fontSize: 11,
                        color: t.text3,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        if (local != null)
                          const FlashChip(
                            label: '本机权重',
                            icon: Icons.check_rounded,
                            tone: FlashTone.success,
                          ),
                        if (local?.draftPath != null)
                          const FlashChip(
                            label: 'DFlash2 就绪',
                            icon: Icons.bolt_rounded,
                            tone: FlashTone.brand,
                          ),
                        FlashChip(
                          label: deviceLine,
                          icon: Icons.memory_rounded,
                        ),
                        const FlashChip(
                          label: '完全离线',
                          icon: Icons.shield_outlined,
                        ),
                      ],
                    ),
                    if (state == ServerState.starting) ...[
                      const SizedBox(height: 12),
                      Text(
                        controller.server?.startupStage ?? '正在启动推理引擎…',
                        style: TextStyle(fontSize: 11, color: t.text3),
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          value: controller.server?.downloadProgress,
                          minHeight: 3,
                          backgroundColor: t.surface3,
                          color: t.brand,
                        ),
                      ),
                    ],
                    if (state == ServerState.failed) ...[
                      const SizedBox(height: 10),
                      Text(
                        controller.server?.failureMessage ?? '服务启动失败',
                        style: TextStyle(fontSize: 12, color: t.danger),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        FlashQuietButton(
                          label: '重启引擎',
                          icon: Icons.refresh_rounded,
                          onPressed: running ? controller.restartService : null,
                        ),
                        const SizedBox(width: 6),
                        FlashQuietButton(
                          label: running ? '停止' : '启动',
                          icon: running
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                          danger: running,
                          onPressed: busy ? null : controller.toggleService,
                        ),
                      ],
                    ),
                  ],
                );

                if (!showGauge) return copy;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: copy),
                    const SizedBox(width: 24),
                    SizedBox(
                      width: 296,
                      child: _Gauge(
                        speed: speed ?? 0,
                        active: stats?.activeRequests ?? 0,
                        ttft: stats?.ttftMilliseconds,
                        contextTokens: stats?.maximumContextTokens,
                        live: running,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7),
        child: Container(
          width: 3,
          height: 3,
          decoration: BoxDecoration(
            color: context.flash.text3.withValues(alpha: .5),
            shape: BoxShape.circle,
          ),
        ),
      );
}

class _Gauge extends StatelessWidget {
  const _Gauge({
    required this.speed,
    required this.active,
    required this.ttft,
    required this.contextTokens,
    required this.live,
  });

  final double speed;
  final int active;
  final double? ttft;
  final int? contextTokens;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 260,
          height: 150,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _GaugePainter(
                    progress: (speed / 100).clamp(0.0, 1.0),
                    gradient: t.brandGradient,
                    track: t.surface3,
                  ),
                ),
              ),
              Positioned(
                bottom: 22,
                child: Column(
                  children: [
                    Text(
                      speed > 0 ? speed.toStringAsFixed(1) : '—',
                      style: TextStyle(
                        fontSize: 38,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1.8,
                        height: 1,
                        color: t.text,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'TOK/S',
                      style: TextStyle(
                        fontFamily: 'SF Mono',
                        fontSize: 10,
                        letterSpacing: 1.4,
                        color: t.text3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          live ? '解码速度 · 实时' : '解码速度 · 等待服务',
          style: TextStyle(fontSize: 10.5, color: t.text3),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.only(top: 6),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: t.border)),
          ),
          child: Row(
            children: [
              _MiniStat(label: '首字延迟', value: ttft == null ? '—' : ttft!.toStringAsFixed(0), unit: 'ms'),
              _MiniStat(label: '活跃请求', value: '$active'),
              _MiniStat(
                label: '上下文',
                value: contextTokens == null ? '—' : _shortTokens(contextTokens!),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value, this.unit});

  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Expanded(
      child: Column(
        children: [
          Text(label, style: TextStyle(fontSize: 10, color: t.text3)),
          const SizedBox(height: 4),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -.4,
                    color: t.text2,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                ),
                if (unit != null && unit!.isNotEmpty)
                  TextSpan(
                    text: unit,
                    style: TextStyle(fontSize: 9.5, color: t.text3),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.progress,
    required this.gradient,
    required this.track,
  });

  final double progress;
  final Gradient gradient;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height - 8);
    final radius = math.min(size.width / 2 - 14, size.height - 26);
    final rect = Rect.fromCircle(center: center, radius: radius);
    const start = math.pi;
    const sweep = math.pi;

    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, start, sweep, false, trackPaint);

    if (progress <= 0) return;
    final paint = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, start, sweep * progress, false, paint);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.progress != progress || old.track != track;
}

// ---------------------------------------------------------------------------
// Right column: 2x2 metrics + runtime details
// ---------------------------------------------------------------------------

class _OverviewSide extends StatelessWidget {
  const _OverviewSide({
    required this.controller,
    required this.stats,
    required this.wide,
  });

  final AppController controller;
  final ServerStats? stats;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final memoryTotal = stats?.physicalMemoryBytes ?? 36 * 1024 * 1024 * 1024;
    final memory = stats?.memoryBytes;
    final acceptance = stats?.draftAcceptance;
    final prefill = stats?.prefillTokensPerSecond;
    final context = stats?.maximumContextTokens;

    final cards = <Widget>[
      _MetricCard(
        icon: Icons.bolt_rounded,
        tone: FlashTone.brand,
        title: '预填充',
        delta: prefill == null ? null : '${prefill.toStringAsFixed(0)} tok/s',
        value: prefill == null ? '—' : flashNumber(prefill, decimals: 0),
        unit: prefill == null ? '' : 'tok/s',
        meter: prefill == null ? 0 : (prefill / 2000).clamp(0.0, 1.0),
        note: '引擎 prefill 采样',
      ),
      _MetricCard(
        icon: Icons.auto_awesome_rounded,
        tone: FlashTone.cyan,
        title: '草稿接受率',
        delta: acceptance == null
            ? null
            : '${(acceptance * 100).toStringAsFixed(0)}%',
        value: acceptance == null
            ? '—'
            : (acceptance * 100).toStringAsFixed(0),
        unit: acceptance == null ? '' : '%',
        meter: acceptance ?? 0,
        note: 'DFlash2 草稿命中比例',
      ),
      _MetricCard(
        icon: Icons.memory_rounded,
        tone: FlashTone.warning,
        title: '内存占用',
        delta: stats?.peakMemoryBytes == null
            ? null
            : '峰值 ${(stats!.peakMemoryBytes! / (1024 * 1024 * 1024)).toStringAsFixed(1)}',
        value: memory == null
            ? '—'
            : (memory / (1024 * 1024 * 1024)).toStringAsFixed(1),
        unit: memory == null
            ? ''
            : 'GB / ${(memoryTotal / (1024 * 1024 * 1024)).round()} GB',
        meter: memory == null ? 0 : (memory / memoryTotal).clamp(0.0, 1.0),
        note: '统一内存占用',
      ),
      _MetricCard(
        icon: Icons.view_in_ar_outlined,
        tone: FlashTone.violet,
        title: '上下文窗口',
        delta: context == null ? null : _shortTokens(context),
        value: context == null ? '—' : _shortTokens(context),
        unit: context == null ? '' : 'tokens',
        meter: 0,
        note: stats?.kvFormat == null ? '最大上下文' : 'KV 缓存 ${stats!.kvFormat}',
      ),
    ];

    final grid = LayoutBuilder(
      builder: (context, constraints) {
        final columns = wide
            ? 2
            : constraints.maxWidth >= 900
                ? 4
                : constraints.maxWidth >= 520
                    ? 2
                    : 1;
        const gap = 10.0;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final card in cards) SizedBox(width: width, child: card),
          ],
        );
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        grid,
        const SizedBox(height: 14),
        _RuntimeDetails(controller: controller, stats: stats),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.tone,
    required this.title,
    required this.value,
    required this.unit,
    required this.meter,
    required this.note,
    this.delta,
  });

  final IconData icon;
  final FlashTone tone;
  final String title;
  final String value;
  final String unit;
  final double meter;
  final String note;
  final String? delta;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return FlashCard(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
      radius: FlashRadius.lg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 23,
                height: 23,
                decoration: BoxDecoration(
                  color: tone.soft(t),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(icon, size: 13, color: tone.fg(t)),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: t.text2,
                  ),
                ),
              ),
              if (delta != null)
                Text(
                  delta!,
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: t.text3,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1,
                    height: 1.1,
                    color: t.text,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  unit,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: t.text3),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          FlashMeter(value: meter, tone: tone),
          const SizedBox(height: 4),
          Text(
            note,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: t.text3),
          ),
        ],
      ),
    );
  }
}

class _RuntimeDetails extends StatelessWidget {
  const _RuntimeDetails({required this.controller, required this.stats});

  final AppController controller;
  final ServerStats? stats;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final server = controller.server;
    final pidText = server?.serverPid == null
        ? '—'
        : 'pid ${server!.serverPid}${server.attachedToExternalService ? '（接入）' : ''}';
    final device = stats?.deviceName ?? Platform.localHostname;
    final deviceText =
        stats?.gpuCores == null ? device : '$device · ${stats!.gpuCores} 核 GPU';
    final endpoint = 'http://127.0.0.1:${controller.port}/v1';

    final rows = <(String, String)>[
      ('引擎', 'splash ${controller.runtime?.version ?? '—'}'),
      ('进程', pidText),
      ('设备', deviceText),
      ('请求', '${stats?.requestsCompleted ?? 0} 完成 · ${stats?.requestsFailed ?? 0} 失败'),
      (
        '首字延迟',
        stats?.ttftMilliseconds == null
            ? '—'
            : '${stats!.ttftMilliseconds!.toStringAsFixed(0)} ms  p50',
      ),
      ('热状态', stats?.thermalText ?? '—'),
    ];

    return FlashCard(
      padding: const EdgeInsets.fromLTRB(18, 17, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: FlashSectionHeader(
                  title: '运行指标',
                  subtitle: '引擎与设备信息',
                ),
              ),
              const FlashPill(
                label: '健康',
                tone: FlashTone.success,
                icon: Icons.shield_outlined,
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < rows.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8.5),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: i == 0 ? Colors.transparent : t.border,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Text(
                    rows[i].$1,
                    style: TextStyle(fontSize: 11.5, color: t.text3),
                  ),
                  const Spacer(),
                  Flexible(
                    child: Text(
                      rows[i].$2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: t.text2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.only(top: 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: t.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'OpenAI 兼容接口',
                        style: TextStyle(fontSize: 10, color: t.text3),
                      ),
                      const SizedBox(height: 3),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: t.surface2,
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: t.border),
                        ),
                        child: Text(
                          endpoint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'SF Mono',
                            fontSize: 10.5,
                            color: t.text2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FlashIconButton(
                  icon: Icons.copy_rounded,
                  tooltip: '复制接口地址',
                  solid: true,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: endpoint));
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        const SnackBar(content: Text('已复制接口地址')),
                      );
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

// ---------------------------------------------------------------------------
// Throughput chart
// ---------------------------------------------------------------------------

class _ThroughputCard extends StatelessWidget {
  const _ThroughputCard({
    required this.values,
    required this.ready,
    required this.range,
    required this.onRangeChanged,
  });

  final List<double> values;
  final bool ready;
  final int range;
  final ValueChanged<int> onRangeChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final visible = values.length > range
        ? values.sublist(values.length - range)
        : values;
    final latest = visible.isEmpty ? 0.0 : visible.last;
    final average = visible.isEmpty
        ? 0.0
        : visible.reduce((a, b) => a + b) / visible.length;
    final peak = visible.isEmpty ? 0.0 : visible.reduce(math.max);

    return FlashCard(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: FlashSectionHeader(
                  title: '解码吞吐',
                  subtitle: 'tokens / second · 最近 ${range == 45 ? '45 秒' : '5 分钟'}',
                ),
              ),
              FlashSegmented<int>(
                segments: const [
                  FlashSegment(45, '45 秒'),
                  FlashSegment(300, '5 分钟'),
                ],
                value: range,
                onChanged: onRangeChanged,
                height: 28,
                dense: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                latest > 0 ? latest.toStringAsFixed(1) : '—',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.2,
                  height: 1,
                  color: t.text,
                  fontFeatures: const [ui.FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 7),
              Text('tok/s', style: TextStyle(fontSize: 11, color: t.text3)),
              const SizedBox(width: 10),
              Text(
                visible.isEmpty
                    ? '等待采样'
                    : '峰值 ${peak.toStringAsFixed(1)} · 均值 ${average.toStringAsFixed(1)}',
                style: TextStyle(fontSize: 10.5, color: t.text3),
              ),
              const Spacer(),
              FlashPill(
                label: ready ? '实时' : '未就绪',
                tone: ready ? FlashTone.success : FlashTone.neutral,
                dot: true,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (visible.isEmpty) {
                  return Center(
                    child: Text(
                      '等待请求',
                      style: TextStyle(fontSize: 12, color: t.text3),
                    ),
                  );
                }
                return CustomPaint(
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                  painter: _ChartPainter(
                    values: visible,
                    range: range,
                    lineGradient: t.brandTextGradient,
                    grid: t.border,
                    textColor: t.text3,
                    fill: t.brand,
                    labelStyle: const TextStyle(fontSize: 9.5),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: t.border)),
            ),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: t.brand,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text('解码速度', style: TextStyle(fontSize: 10.5, color: t.text3)),
                const SizedBox(width: 14),
                Container(
                  width: 12,
                  height: 1,
                  color: t.text3.withValues(alpha: .5),
                ),
                const SizedBox(width: 5),
                Text(
                  '平均 ${average.toStringAsFixed(1)}',
                  style: TextStyle(fontSize: 10.5, color: t.text3),
                ),
                const Spacer(),
                Text('自动刷新 · 1s', style: TextStyle(fontSize: 10.5, color: t.text3)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.values,
    required this.range,
    required this.lineGradient,
    required this.grid,
    required this.textColor,
    required this.fill,
    required this.labelStyle,
  });

  final List<double> values;
  final int range;
  final Gradient lineGradient;
  final Color grid;
  final Color textColor;
  final Color fill;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    const padL = 34.0;
    const padR = 6.0;
    const padT = 10.0;
    const padB = 22.0;
    final plotW = size.width - padL - padR;
    final plotH = size.height - padT - padB;
    if (plotW <= 0 || plotH <= 0) return;

    const yMin = 50.0;
    const yMax = 90.0;
    double yFor(double value) =>
        padT + plotH - ((value.clamp(yMin, yMax) - yMin) / (yMax - yMin)) * plotH;
    double xFor(int index) =>
        padL + (values.length == 1 ? plotW : plotW * index / (values.length - 1));

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final value = yMax - (yMax - yMin) / 4 * i;
      final y = padT + plotH / 4 * i;
      _dashedLine(canvas, Offset(padL, y), Offset(size.width - padR, y), gridPaint);
      _text(
        canvas,
        value.toStringAsFixed(0),
        Offset(padL - 8, y + 3.5),
        align: TextAlign.right,
      );
    }

    final points = <Offset>[
      for (var i = 0; i < values.length; i++) Offset(xFor(i), yFor(values[i])),
    ];
    final line = flashSmoothPath(points);

    final area = Path.from(line)
      ..lineTo(points.last.dx, padT + plotH)
      ..lineTo(points.first.dx, padT + plotH)
      ..close();
    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          fill.withValues(alpha: .26),
          fill.withValues(alpha: .03),
        ],
      ).createShader(Rect.fromLTWH(padL, padT, plotW, plotH));
    canvas.drawPath(area, fillPaint);

    final average = values.reduce((a, b) => a + b) / values.length;
    final avgY = yFor(average);
    _dashedLine(
      canvas,
      Offset(padL, avgY),
      Offset(size.width - padR, avgY),
      Paint()
        ..color = textColor.withValues(alpha: .55)
        ..strokeWidth = 1,
    );

    final linePaint = Paint()
      ..shader = lineGradient.createShader(
        Rect.fromLTWH(padL, 0, plotW, 0),
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(line, linePaint);

    canvas.drawCircle(
      points.last,
      7,
      Paint()..color = fill.withValues(alpha: .16),
    );
    canvas.drawCircle(points.last, 3.2, Paint()..color = fill);
    canvas.drawCircle(
      points.last,
      3.2,
      Paint()
        ..color = Colors.white.withValues(alpha: .9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final labels = range <= 45
        ? const ['-45s', '-30s', '-15s', '现在']
        : const ['-5m', '-3m', '-1m', '现在'];
    for (var i = 0; i < labels.length; i++) {
      final x = padL + plotW * i / (labels.length - 1);
      final align = i == 0
          ? TextAlign.left
          : i == labels.length - 1
              ? TextAlign.right
              : TextAlign.center;
      _text(
        canvas,
        labels[i],
        Offset(x, size.height - 6),
        align: align,
      );
    }
  }

  void _text(Canvas canvas, String text, Offset offset,
      {TextAlign align = TextAlign.left}) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: labelStyle.copyWith(color: textColor)),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = switch (align) {
      TextAlign.right => offset.dx - painter.width,
      TextAlign.center => offset.dx - painter.width / 2,
      _ => offset.dx,
    };
    painter.paint(canvas, Offset(dx, offset.dy - painter.height));
  }

  void _dashedLine(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dash = 4.0;
    const gap = 5.0;
    final dx = to.dx - from.dx;
    final dy = to.dy - from.dy;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) return;
    final stepX = dx / length * dash;
    final stepY = dy / length * dash;
    var progress = 0.0;
    while (progress < length) {
      final start = Offset(
        from.dx + dx / length * progress,
        from.dy + dy / length * progress,
      );
      final endProgress = math.min(progress + dash, length);
      final end = Offset(
        from.dx + dx / length * endProgress,
        from.dy + dy / length * endProgress,
      );
      canvas.drawLine(start, end, paint);
      progress += dash + gap;
      if (stepX == 0 && stepY == 0) break;
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.values != values || old.range != range || old.grid != grid;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class _StartupError extends StatelessWidget {
  const _StartupError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: t.dangerSoft,
        borderRadius: BorderRadius.circular(FlashRadius.sm),
        border: Border.all(color: t.danger.withValues(alpha: .3)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 16, color: t.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12, color: t.danger),
            ),
          ),
        ],
      ),
    );
  }
}

String _modelTitle(String id) {
  if (id.isEmpty) return '未选择模型';
  var name = id.split('/').last;
  final colon = name.indexOf(':');
  if (colon >= 0) name = name.substring(0, colon);
  name = name.replaceAll(
    RegExp(r'[-_](?:\d+bit|GGUF|MLX)$', caseSensitive: false),
    '',
  );
  name = name.replaceAll(
    RegExp(r'[-_](?:UD-)?Q\d.*$', caseSensitive: false),
    '',
  );
  return name;
}

String _modelQuant(String id) {
  if (id.isEmpty) return '';
  final bits = RegExp(r'(\d+)\s*bit', caseSensitive: false).firstMatch(id);
  final family = id.toLowerCase().contains('gguf') ? 'GGUF' : 'MLX';
  if (bits == null) return family;
  return '${bits.group(1)}-bit · $family';
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
