import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'flash_tokens.dart';

/// Semantic colour roles used by chips, pills and meters.
enum FlashTone { neutral, brand, cyan, violet, success, warning, danger, info }

extension FlashToneColors on FlashTone {
  Color fg(FlashTokens t) => switch (this) {
        FlashTone.neutral => t.text2,
        FlashTone.brand => t.brand,
        FlashTone.cyan => t.brand2,
        FlashTone.violet => t.brand3,
        FlashTone.success => t.success,
        FlashTone.warning => t.warning,
        FlashTone.danger => t.danger,
        FlashTone.info => t.info,
      };

  Color soft(FlashTokens t) => switch (this) {
        FlashTone.neutral => t.surface2,
        FlashTone.brand => t.brandSoft,
        FlashTone.cyan => t.brand2.withValues(alpha: .12),
        FlashTone.violet => t.brand3.withValues(alpha: .14),
        FlashTone.success => t.successSoft,
        FlashTone.warning => t.warningSoft,
        FlashTone.danger => t.dangerSoft,
        FlashTone.info => t.info.withValues(alpha: .12),
      };
}

/// A soft hover wrapper: no ink ripple, just a colour blend like the web.
class FlashHover extends StatefulWidget {
  const FlashHover({
    super.key,
    required this.builder,
    this.cursor = SystemMouseCursors.click,
    this.onTap,
    this.borderRadius,
    this.scaleOnPress = true,
  });

  final Widget Function(bool hovered) builder;
  final MouseCursor cursor;
  final VoidCallback? onTap;
  final BorderRadius? borderRadius;
  final bool scaleOnPress;

  @override
  State<FlashHover> createState() => _FlashHoverState();
}

class _FlashHoverState extends State<FlashHover> {
  bool _hovered = false;
  bool _pressed = false;

  void _setPressed(bool value) {
    if (!widget.scaleOnPress || widget.onTap == null) return;
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    Widget child = AnimatedScale(
      scale: _pressed ? .975 : 1,
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
      child: widget.builder(_hovered),
    );
    if (widget.onTap != null) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: widget.onTap,
        child: child,
      );
    }
    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: child,
    );
  }
}

/// The signature surface: white card, hairline border, quiet shadow.
class FlashCard extends StatelessWidget {
  const FlashCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = FlashRadius.lg,
    this.color,
    this.borderColor,
    this.shadow,
    this.clip = Clip.none,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;
  final Color? borderColor;
  final List<BoxShadow>? shadow;
  final Clip clip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? t.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? t.border),
        boxShadow: shadow ?? t.shadow1,
      ),
      clipBehavior: clip,
      child: child,
    );
    if (onTap == null) return card;
    return FlashHover(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radius),
      builder: (_) => card,
    );
  }
}

/// flashCat mark: gradient rounded square, cat ears and a lightning bolt.
class FlashLogo extends StatelessWidget {
  const FlashLogo({super.key, this.size = 36, this.glow = true});

  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: glow
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(size * .26),
              boxShadow: [
                BoxShadow(
                  color: context.flash.brand.withValues(alpha: .28),
                  blurRadius: size * .38,
                  offset: Offset(0, size * .14),
                ),
              ],
            )
          : null,
      child: CustomPaint(
        painter: _FlashLogoPainter(context.flash.brandGradient),
      ),
    );
  }
}

class _FlashLogoPainter extends CustomPainter {
  _FlashLogoPainter(this.gradient);

  final Gradient gradient;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()..shader = gradient.createShader(Offset.zero & size);

    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * .125, h * .18, w * .75, h * .69),
      Radius.circular(w * .24),
    );
    canvas.drawRRect(body, paint);

    final earLeft = Path()
      ..moveTo(w * .28, h * .23)
      ..lineTo(w * .30, h * .085)
      ..lineTo(w * .46, h * .19)
      ..close();
    final earRight = Path()
      ..moveTo(w * .72, h * .23)
      ..lineTo(w * .70, h * .085)
      ..lineTo(w * .54, h * .19)
      ..close();
    canvas.drawPath(earLeft, paint);
    canvas.drawPath(earRight, paint);

    final bolt = Path()
      ..moveTo(w * .56, h * .29)
      ..lineTo(w * .35, h * .545)
      ..lineTo(w * .49, h * .545)
      ..lineTo(w * .42, h * .765)
      ..lineTo(w * .63, h * .50)
      ..lineTo(w * .49, h * .50)
      ..close();
    canvas.drawPath(bolt, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _FlashLogoPainter old) =>
      old.gradient != gradient;
}

class FlashPrimaryButton extends StatelessWidget {
  const FlashPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.expanded = false,
    this.height = 34,
    this.loading = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool expanded;
  final double height;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final enabled = onPressed != null && !loading;
    return FlashHover(
      onTap: enabled ? onPressed : null,
      borderRadius: BorderRadius.circular(FlashRadius.sm),
      builder: (hovered) => AnimatedOpacity(
        duration: const Duration(milliseconds: 140),
        opacity: enabled ? 1 : .5,
        child: Container(
          height: height,
          width: expanded ? double.infinity : null,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            gradient: t.brandGradient,
            borderRadius: BorderRadius.circular(FlashRadius.sm),
            boxShadow: hovered ? t.shadowBrand : null,
          ),
          child: Row(
            mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (loading) ...[
                SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: Colors.white.withValues(alpha: .9),
                  ),
                ),
                const SizedBox(width: 7),
              ] else if (icon != null) ...[
                Icon(icon, size: 14, color: Colors.white),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FlashQuietButton extends StatelessWidget {
  const FlashQuietButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.danger = false,
    this.height = 31,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool danger;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final enabled = onPressed != null;
    return FlashHover(
      onTap: enabled ? onPressed : null,
      borderRadius: BorderRadius.circular(FlashRadius.xs),
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: !enabled
              ? Colors.transparent
              : danger && hovered
                  ? t.dangerSoft
                  : hovered
                      ? t.surface
                      : t.surface.withValues(alpha: .55),
          borderRadius: BorderRadius.circular(FlashRadius.xs),
          border: Border.all(
            color: danger && hovered
                ? t.danger.withValues(alpha: .32)
                : hovered
                    ? t.borderStrong
                    : t.border,
          ),
        ),
        child: Opacity(
          opacity: enabled ? 1 : .45,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 14,
                  color: danger && hovered ? t.danger : t.text2.withValues(alpha: .8),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: danger && hovered ? t.danger : t.text2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FlashGhostButton extends StatelessWidget {
  const FlashGhostButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.tone,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final fg = tone ?? t.text2;
    return FlashHover(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(FlashRadius.xs),
      builder: (hovered) => Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: hovered ? t.surface2 : Colors.transparent,
          borderRadius: BorderRadius.circular(FlashRadius.xs),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: fg),
            ),
          ],
        ),
      ),
    );
  }
}

class FlashIconButton extends StatelessWidget {
  const FlashIconButton({
    super.key,
    required this.icon,
    this.tooltip,
    this.onPressed,
    this.size = 30,
    this.iconSize = 16,
    this.active = false,
    this.solid = false,
  });

  final IconData icon;
  final String? tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final bool active;
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final button = FlashHover(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(FlashRadius.xs),
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: active
              ? t.brandSoft
              : solid
                  ? (hovered ? t.surface : t.surface2)
                  : (hovered ? t.surface2 : Colors.transparent),
          borderRadius: BorderRadius.circular(FlashRadius.xs),
          border: Border.all(
            color: solid
                ? (hovered ? t.borderStrong : t.border)
                : Colors.transparent,
          ),
        ),
        child: Icon(
          icon,
          size: iconSize,
          color: active ? t.brand : t.text2,
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

class FlashChip extends StatelessWidget {
  const FlashChip({
    super.key,
    required this.label,
    this.icon,
    this.tone = FlashTone.neutral,
    this.outlined = false,
    this.bold = false,
  });

  final String label;
  final IconData? icon;
  final FlashTone tone;
  final bool outlined;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final fg = tone == FlashTone.neutral ? t.text2 : tone.fg(t);
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: outlined ? Colors.transparent : tone.soft(t),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(
          color: outlined ? t.border : (tone == FlashTone.neutral ? t.border : Colors.transparent),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11.5, color: fg),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: bold ? FontWeight.w600 : FontWeight.w500,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

class FlashPill extends StatelessWidget {
  const FlashPill({
    super.key,
    required this.label,
    this.tone = FlashTone.success,
    this.dot = false,
    this.icon,
  });

  final String label;
  final FlashTone tone;
  final bool dot;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final fg = tone.fg(t);
    return Container(
      height: 21,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: tone.soft(t),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
          ] else if (icon != null) ...[
            Icon(icon, size: 11, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: fg),
          ),
        ],
      ),
    );
  }
}

class FlashSegment<T> {
  const FlashSegment(this.value, this.label, {this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

class FlashSegmented<T> extends StatelessWidget {
  const FlashSegmented({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
    this.height = 28,
    this.dense = false,
  });

  final List<FlashSegment<T>> segments;
  final T value;
  final ValueChanged<T>? onChanged;
  final double height;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Container(
      height: height,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(FlashRadius.xs),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final seg in segments)
            _segment(context, t, seg),
        ],
      ),
    );
  }

  Widget _segment(BuildContext context, FlashTokens t, FlashSegment<T> seg) {
    final active = seg.value == value;
    return FlashHover(
      onTap: onChanged == null ? null : () => onChanged!(seg.value),
      borderRadius: BorderRadius.circular(6),
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? t.raised : (hovered ? t.surface.withValues(alpha: .6) : Colors.transparent),
          borderRadius: BorderRadius.circular(6),
          boxShadow: active ? t.shadow1 : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (seg.icon != null) ...[
              Icon(seg.icon, size: 12, color: active ? t.text : t.text3),
              const SizedBox(width: 5),
            ],
            Text(
              seg.label,
              style: TextStyle(
                fontSize: dense ? 10.5 : 11,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color: active ? t.text : t.text3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FlashSwitch extends StatelessWidget {
  const FlashSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return FlashHover(
      cursor: SystemMouseCursors.click,
      scaleOnPress: false,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 38,
        height: 22,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          gradient: value ? t.brandGradient : null,
          color: value ? null : t.surface3,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
            color: value ? Colors.transparent : t.border,
          ),
          boxShadow: hovered && value ? t.shadowBrand : null,
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: const [
                BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 1)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class FlashMeter extends StatelessWidget {
  const FlashMeter({super.key, required this.value, this.tone = FlashTone.brand});

  final double value;
  final FlashTone tone;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    final gradient = switch (tone) {
      FlashTone.cyan => LinearGradient(colors: [t.brand2, t.brand]),
      FlashTone.warning => LinearGradient(colors: [const Color(0xFFF3C76B), t.warning]),
      FlashTone.violet => LinearGradient(colors: [t.brand3, const Color(0xFFD3A2FF)]),
      _ => LinearGradient(colors: [t.brand, t.brand2]),
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: Container(
        height: 3,
        color: t.surface3,
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: value.clamp(0, 1),
          child: Container(decoration: BoxDecoration(gradient: gradient)),
        ),
      ),
    );
  }
}

class FlashStatusDot extends StatelessWidget {
  const FlashStatusDot({
    super.key,
    required this.color,
    this.size = 7,
    this.pulse = false,
  });

  final Color color;
  final double size;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    if (!pulse) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
    }
    return _PulsingDot(color: color, size: size);
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: .5 * (1 - t)),
                blurRadius: 4 + 8 * t,
                spreadRadius: 1 + 3 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Section title used inside cards ("解码吞吐", "运行指标"...).
class FlashSectionHeader extends StatelessWidget {
  const FlashSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.titleSize = 14,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final double titleSize;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.2,
                  color: t.text,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: TextStyle(fontSize: 11, color: t.text3),
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class FlashSearchField extends StatelessWidget {
  const FlashSearchField({
    super.key,
    required this.hint,
    this.controller,
    this.onChanged,
    this.prefixIcon = Icons.search_rounded,
    this.suffix,
    this.height = 36,
  });

  final String hint;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final IconData? prefixIcon;
  final Widget? suffix;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(FlashRadius.sm),
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: [
          if (prefixIcon != null) ...[
            Icon(prefixIcon, size: 15, color: t.text3),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              cursorColor: t.brand,
              style: TextStyle(fontSize: 12, color: t.text),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: hint,
                hintStyle: TextStyle(fontSize: 12, color: t.text3),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          ?suffix,
        ],
      ),
    );
  }
}

/// Small keycap, used by shortcut hints.
class FlashKbd extends StatelessWidget {
  const FlashKbd({super.key, required this.label, this.height = 18});

  final String label;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: t.border),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: t.text3,
          fontFamily: 'SF Mono',
        ),
      ),
    );
  }
}

/// Radial tint used behind the hero card.
class FlashHeroGlow extends StatelessWidget {
  const FlashHeroGlow({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            right: -60,
            top: -110,
            child: _glow(360, t.brand.withValues(alpha: t.isDark ? .3 : .22)),
          ),
          Positioned(
            right: 140,
            bottom: -140,
            child: _glow(300, t.brand2.withValues(alpha: t.isDark ? .2 : .18)),
          ),
        ],
      ),
    );
  }

  Widget _glow(double size, Color color) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      );
}

/// Draws the faint grid that sits on top of the hero glow.
class FlashGridPainter extends CustomPainter {
  FlashGridPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const step = 44.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant FlashGridPainter old) => old.color != color;
}

/// Standard page padding used by every page.
const pagePadding = EdgeInsets.fromLTRB(30, 22, 30, 30);

/// Number formatting helper shared by metric widgets.
String flashNumber(num value, {int decimals = 0}) {
  if (value.isNaN || value.isInfinite) return '—';
  final fixed = value.toStringAsFixed(decimals);
  final parts = fixed.split('.');
  final intPart = parts.first.replaceFirstMapped(
    RegExp(r'^(-?)(\d+)'),
    (m) => '${m[1]}${_group(m[2]!)}',
  );
  return parts.length > 1 ? '$intPart.${parts[1]}' : intPart;
}

String _group(String digits) {
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Approximate a smooth monotone path, used by sparklines.
Path flashSmoothPath(List<Offset> points) {
  final path = Path();
  if (points.isEmpty) return path;
  path.moveTo(points.first.dx, points.first.dy);
  for (var i = 0; i < points.length - 1; i++) {
    final p0 = i == 0 ? points[i] : points[i - 1];
    final p1 = points[i];
    final p2 = points[i + 1];
    final p3 = i + 2 < points.length ? points[i + 2] : p2;
    final c1 = Offset(p1.dx + (p2.dx - p0.dx) / 6, p1.dy + (p2.dy - p0.dy) / 6);
    final c2 = Offset(p2.dx - (p3.dx - p1.dx) / 6, p2.dy - (p3.dy - p1.dy) / 6);
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
  }
  return path;
}

double flashClamp(double v, double min, double max) => math.min(max, math.max(min, v));
