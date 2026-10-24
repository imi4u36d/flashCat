import 'package:flutter/material.dart';

/// Design tokens lifted from `design/styles.css`.
///
/// Every colour, radius and shadow here has a direct counterpart in the web
/// high-fidelity prototype so the Flutter app and the prototype stay in sync.
@immutable
class FlashTokens extends ThemeExtension<FlashTokens> {
  const FlashTokens({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.raised,
    required this.glass,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.text2,
    required this.text3,
    required this.brand,
    required this.brand2,
    required this.brand3,
    required this.brandSoft,
    required this.success,
    required this.successSoft,
    required this.warning,
    required this.warningSoft,
    required this.danger,
    required this.dangerSoft,
    required this.info,
    required this.termBg,
    required this.termBg2,
    required this.shadow1,
    required this.shadow2,
    required this.shadowBrand,
  });

  final Brightness brightness;

  final Color bg;
  final Color surface;
  final Color surface2;
  final Color surface3;
  final Color raised;
  final Color glass;
  final Color border;
  final Color borderStrong;

  final Color text;
  final Color text2;
  final Color text3;

  final Color brand;
  final Color brand2;
  final Color brand3;
  final Color brandSoft;

  final Color success;
  final Color successSoft;
  final Color warning;
  final Color warningSoft;
  final Color danger;
  final Color dangerSoft;
  final Color info;

  final Color termBg;
  final Color termBg2;

  final List<BoxShadow> shadow1;
  final List<BoxShadow> shadow2;
  final List<BoxShadow> shadowBrand;

  bool get isDark => brightness == Brightness.dark;

  /// 靛蓝 → 青色闪电渐变。
  LinearGradient get brandGradient => const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF6F5CF6), Color(0xFF5B7CFA), Color(0xFF13C4EC)],
        stops: [0, .55, 1],
      );

  LinearGradient get brandTextGradient => LinearGradient(
        colors: [brand, brand2],
      );

  static const _lightShadow1 = [
    BoxShadow(color: Color(0x0A131723), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x1A131723), blurRadius: 24, offset: Offset(0, 10)),
  ];
  static const _lightShadow2 = [
    BoxShadow(color: Color(0x0F131723), blurRadius: 8, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x53131723), blurRadius: 80, offset: Offset(0, 30)),
  ];
  static const _darkShadow1 = [
    BoxShadow(color: Color(0x59000000), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0xB3000000), blurRadius: 34, offset: Offset(0, 14)),
  ];
  static const _darkShadow2 = [
    BoxShadow(color: Color(0x66000000), blurRadius: 10, offset: Offset(0, 2)),
    BoxShadow(color: Color(0xE6000000), blurRadius: 100, offset: Offset(0, 40)),
  ];

  static const light = FlashTokens(
    brightness: Brightness.light,
    bg: Color(0xFFF5F4F0),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF8F7F4),
    surface3: Color(0xFFEFEEE9),
    raised: Color(0xFFFFFFFF),
    glass: Color(0xC7FFFFFF),
    border: Color(0x1615171E),
    borderStrong: Color(0x2915171E),
    text: Color(0xFF16181E),
    text2: Color(0xFF565D6B),
    text3: Color(0xFF717887),
    brand: Color(0xFF6558F5),
    brand2: Color(0xFF06B6D4),
    brand3: Color(0xFF8B7DFF),
    brandSoft: Color(0x1A6558F5),
    success: Color(0xFF0F9D6E),
    successSoft: Color(0x1C0F9D6E),
    warning: Color(0xFFB0781B),
    warningSoft: Color(0x1FB0781B),
    danger: Color(0xFFD94A4A),
    dangerSoft: Color(0x1AD94A4A),
    info: Color(0xFF2F7CD6),
    termBg: Color(0xFF0D1017),
    termBg2: Color(0xFF10141C),
    shadow1: _lightShadow1,
    shadow2: _lightShadow2,
    shadowBrand: [
      BoxShadow(color: Color(0x8C6558F5), blurRadius: 26, offset: Offset(0, 10)),
    ],
  );

  static const dark = FlashTokens(
    brightness: Brightness.dark,
    bg: Color(0xFF0B0D12),
    surface: Color(0xFF12151C),
    surface2: Color(0xFF171B23),
    surface3: Color(0xFF1D222C),
    raised: Color(0xFF1D222C),
    glass: Color(0xC712151C),
    border: Color(0x13FFFFFF),
    borderStrong: Color(0x26FFFFFF),
    text: Color(0xFFECEEF4),
    text2: Color(0xFFAEB5C4),
    text3: Color(0xFF8B93A5),
    brand: Color(0xFF8677FF),
    brand2: Color(0xFF2BD4F2),
    brand3: Color(0xFFA99BFF),
    brandSoft: Color(0x248677FF),
    success: Color(0xFF41D99B),
    successSoft: Color(0x1F41D99B),
    warning: Color(0xFFF0C05A),
    warningSoft: Color(0x1FF0C05A),
    danger: Color(0xFFFF7D7D),
    dangerSoft: Color(0x1CFF7D7D),
    info: Color(0xFF6FB4FF),
    termBg: Color(0xFF080A0F),
    termBg2: Color(0xFF0B0E14),
    shadow1: _darkShadow1,
    shadow2: _darkShadow2,
    shadowBrand: [
      BoxShadow(color: Color(0xA68677FF), blurRadius: 30, offset: Offset(0, 12)),
    ],
  );

  @override
  FlashTokens copyWith({
    Brightness? brightness,
    Color? bg,
    Color? surface,
    Color? surface2,
    Color? surface3,
    Color? raised,
    Color? glass,
    Color? border,
    Color? borderStrong,
    Color? text,
    Color? text2,
    Color? text3,
    Color? brand,
    Color? brand2,
    Color? brand3,
    Color? brandSoft,
    Color? success,
    Color? successSoft,
    Color? warning,
    Color? warningSoft,
    Color? danger,
    Color? dangerSoft,
    Color? info,
    Color? termBg,
    Color? termBg2,
    List<BoxShadow>? shadow1,
    List<BoxShadow>? shadow2,
    List<BoxShadow>? shadowBrand,
  }) {
    return FlashTokens(
      brightness: brightness ?? this.brightness,
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      surface3: surface3 ?? this.surface3,
      raised: raised ?? this.raised,
      glass: glass ?? this.glass,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      text: text ?? this.text,
      text2: text2 ?? this.text2,
      text3: text3 ?? this.text3,
      brand: brand ?? this.brand,
      brand2: brand2 ?? this.brand2,
      brand3: brand3 ?? this.brand3,
      brandSoft: brandSoft ?? this.brandSoft,
      success: success ?? this.success,
      successSoft: successSoft ?? this.successSoft,
      warning: warning ?? this.warning,
      warningSoft: warningSoft ?? this.warningSoft,
      danger: danger ?? this.danger,
      dangerSoft: dangerSoft ?? this.dangerSoft,
      info: info ?? this.info,
      termBg: termBg ?? this.termBg,
      termBg2: termBg2 ?? this.termBg2,
      shadow1: shadow1 ?? this.shadow1,
      shadow2: shadow2 ?? this.shadow2,
      shadowBrand: shadowBrand ?? this.shadowBrand,
    );
  }

  @override
  FlashTokens lerp(covariant FlashTokens? other, double t) {
    if (other == null) return this;
    return FlashTokens(
      brightness: t < .5 ? brightness : other.brightness,
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      surface3: Color.lerp(surface3, other.surface3, t)!,
      raised: Color.lerp(raised, other.raised, t)!,
      glass: Color.lerp(glass, other.glass, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      text: Color.lerp(text, other.text, t)!,
      text2: Color.lerp(text2, other.text2, t)!,
      text3: Color.lerp(text3, other.text3, t)!,
      brand: Color.lerp(brand, other.brand, t)!,
      brand2: Color.lerp(brand2, other.brand2, t)!,
      brand3: Color.lerp(brand3, other.brand3, t)!,
      brandSoft: Color.lerp(brandSoft, other.brandSoft, t)!,
      success: Color.lerp(success, other.success, t)!,
      successSoft: Color.lerp(successSoft, other.successSoft, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningSoft: Color.lerp(warningSoft, other.warningSoft, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      dangerSoft: Color.lerp(dangerSoft, other.dangerSoft, t)!,
      info: Color.lerp(info, other.info, t)!,
      termBg: Color.lerp(termBg, other.termBg, t)!,
      termBg2: Color.lerp(termBg2, other.termBg2, t)!,
      shadow1: BoxShadow.lerpList(shadow1, other.shadow1, t)!,
      shadow2: BoxShadow.lerpList(shadow2, other.shadow2, t)!,
      shadowBrand: BoxShadow.lerpList(shadowBrand, other.shadowBrand, t)!,
    );
  }
}

extension FlashTokensX on BuildContext {
  FlashTokens get flash => Theme.of(this).extension<FlashTokens>()!;
  Color get flashText2 => flash.text2;
  Color get flashText3 => flash.text3;
  Color get flashMuted => Theme.of(this).colorScheme.onSurfaceVariant;
}

/// Shared corner radii.
abstract final class FlashRadius {
  static const double xs = 8;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 18;
  static const double xl = 24;

  static const BorderRadius rXs = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius rSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius rMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius rLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius rXl = BorderRadius.all(Radius.circular(xl));
}

/// Spacing scale used by the prototype.
abstract final class FlashSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 30;
}
