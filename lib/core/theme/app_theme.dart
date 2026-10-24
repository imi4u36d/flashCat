import 'package:flutter/material.dart';

import '../../design/flash_tokens.dart';

/// Legacy colour extension kept so older widgets keep compiling while the UI
/// migrates to [FlashTokens]. New code should prefer `context.flash`.
@immutable
class FlashCatColors extends ThemeExtension<FlashCatColors> {
  const FlashCatColors({
    required this.success,
    required this.warning,
    required this.info,
    required this.surfaceSunken,
    required this.border,
    required this.chartFill,
  });

  final Color success;
  final Color warning;
  final Color info;
  final Color surfaceSunken;
  final Color border;
  final Color chartFill;

  static const light = FlashCatColors(
    success: Color(0xFF0F9D6E),
    warning: Color(0xFFB0781B),
    info: Color(0xFF2F7CD6),
    surfaceSunken: Color(0xFFEFEEE9),
    border: Color(0x1615171E),
    chartFill: Color(0x266558F5),
  );

  static const dark = FlashCatColors(
    success: Color(0xFF41D99B),
    warning: Color(0xFFF0C05A),
    info: Color(0xFF6FB4FF),
    surfaceSunken: Color(0xFF1D222C),
    border: Color(0x13FFFFFF),
    chartFill: Color(0x338677FF),
  );

  @override
  FlashCatColors copyWith({
    Color? success,
    Color? warning,
    Color? info,
    Color? surfaceSunken,
    Color? border,
    Color? chartFill,
  }) {
    return FlashCatColors(
      success: success ?? this.success,
      warning: warning ?? this.warning,
      info: info ?? this.info,
      surfaceSunken: surfaceSunken ?? this.surfaceSunken,
      border: border ?? this.border,
      chartFill: chartFill ?? this.chartFill,
    );
  }

  @override
  FlashCatColors lerp(ThemeExtension<FlashCatColors>? other, double t) {
    if (other is! FlashCatColors) return this;
    return FlashCatColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      info: Color.lerp(info, other.info, t)!,
      surfaceSunken: Color.lerp(surfaceSunken, other.surfaceSunken, t)!,
      border: Color.lerp(border, other.border, t)!,
      chartFill: Color.lerp(chartFill, other.chartFill, t)!,
    );
  }
}

extension FlashCatTheme on BuildContext {
  FlashCatColors get flashColors =>
      Theme.of(this).extension<FlashCatColors>()!;

  Color get mutedText => Theme.of(this).colorScheme.onSurfaceVariant;
}

ThemeData buildFlashCatTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final tokens = dark ? FlashTokens.dark : FlashTokens.light;

  final scheme = ColorScheme.fromSeed(
    seedColor: tokens.brand,
    brightness: brightness,
  ).copyWith(
    primary: tokens.brand,
    onPrimary: Colors.white,
    secondary: tokens.brand2,
    onSecondary: Colors.white,
    surface: tokens.surface,
    onSurface: tokens.text,
    onSurfaceVariant: tokens.text3,
    outline: tokens.borderStrong,
    outlineVariant: tokens.border,
    error: tokens.danger,
    onError: Colors.white,
    surfaceContainerHighest: tokens.surface2,
    surfaceContainerHigh: tokens.surface2,
    surfaceContainer: tokens.surface3,
    inverseSurface: tokens.text,
    onInverseSurface: tokens.bg,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: tokens.bg,
    visualDensity: VisualDensity.compact,
  );

  final textTheme = TextTheme(
    displayLarge: TextStyle(
      fontSize: 42,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.5,
      height: 1.06,
      color: tokens.text,
    ),
    displayMedium: TextStyle(
      fontSize: 34,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.1,
      height: 1.08,
      color: tokens.text,
    ),
    headlineMedium: TextStyle(
      fontSize: 25,
      fontWeight: FontWeight.w700,
      letterSpacing: -.8,
      height: 1.15,
      color: tokens.text,
    ),
    headlineSmall: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w700,
      letterSpacing: -.4,
      color: tokens.text,
    ),
    titleLarge: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w700,
      letterSpacing: -.3,
      color: tokens.text,
    ),
    titleMedium: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: -.1,
      color: tokens.text,
    ),
    titleSmall: TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      color: tokens.text,
    ),
    bodyLarge: TextStyle(fontSize: 14, height: 1.55, color: tokens.text),
    bodyMedium: TextStyle(fontSize: 13.5, height: 1.55, color: tokens.text),
    bodySmall: TextStyle(fontSize: 11.5, height: 1.5, color: tokens.text3),
    labelLarge: TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      color: tokens.text,
    ),
    labelMedium: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      color: tokens.text2,
    ),
    labelSmall: TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w500,
      letterSpacing: .2,
      color: tokens.text3,
    ),
  );

  final inputBorder = OutlineInputBorder(
    borderRadius: FlashRadius.rSm,
    borderSide: BorderSide(color: tokens.border),
  );

  return base.copyWith(
    extensions: [tokens, dark ? FlashCatColors.dark : FlashCatColors.light],
    textTheme: textTheme,
    canvasColor: tokens.bg,
    dividerColor: tokens.border,
    dividerTheme: DividerThemeData(color: tokens.border, thickness: 1, space: 1),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: tokens.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: FlashRadius.rLg,
        side: BorderSide(color: tokens.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: tokens.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FlashRadius.xl),
        side: BorderSide(color: tokens.border),
      ),
      titleTextStyle: textTheme.titleLarge,
      contentTextStyle: textTheme.bodyMedium,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: tokens.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: FlashRadius.rMd,
        side: BorderSide(color: tokens.border),
      ),
      textStyle: TextStyle(fontSize: 12.5, color: tokens.text),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: tokens.brand,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: FlashRadius.rSm),
        minimumSize: const Size(46, 34),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: tokens.text2,
        side: BorderSide(color: tokens.border),
        shape: RoundedRectangleBorder(borderRadius: FlashRadius.rSm),
        minimumSize: const Size(46, 34),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: tokens.brand,
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: FlashRadius.rXs),
      ),
    ),
    iconTheme: IconThemeData(color: tokens.text2, size: 18),
    chipTheme: ChipThemeData(
      backgroundColor: tokens.surface2,
      side: BorderSide(color: tokens.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
      labelStyle: TextStyle(fontSize: 11, color: tokens.text2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: tokens.surface2,
      hintStyle: TextStyle(fontSize: 12, color: tokens.text3),
      labelStyle: TextStyle(fontSize: 12, color: tokens.text3),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: tokens.brand, width: 1.2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : tokens.surface,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? tokens.brand
            : tokens.surface3,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : tokens.border,
      ),
      trackOutlineWidth: const WidgetStatePropertyAll(1),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: tokens.brand,
      inactiveTrackColor: tokens.surface3,
      thumbColor: Colors.white,
      overlayColor: tokens.brandSoft,
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(99),
      thumbColor: WidgetStatePropertyAll(tokens.text3.withValues(alpha: .28)),
      crossAxisMargin: 2,
    ),
    // Tooltips are floating cards, not black system bubbles: the old near-black
    // decoration read as a second dark background next to the hovered control.
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 420),
      decoration: BoxDecoration(
        color: tokens.raised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tokens.borderStrong),
        boxShadow: tokens.shadow1,
      ),
      textStyle: TextStyle(
        color: tokens.text,
        fontSize: 11.5,
        fontWeight: FontWeight.w500,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF262B36) : const Color(0xFF20242C),
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 12.5),
      shape: RoundedRectangleBorder(borderRadius: FlashRadius.rSm),
      insetPadding: const EdgeInsets.all(18),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 62,
      backgroundColor: tokens.surface,
      indicatorColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 10,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? tokens.brand
              : tokens.text3,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 19,
          color: states.contains(WidgetState.selected)
              ? tokens.brand
              : tokens.text3,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: tokens.surface2,
      indicatorColor: tokens.brandSoft,
      selectedIconTheme: IconThemeData(color: tokens.brand),
      unselectedIconTheme: IconThemeData(color: tokens.text3),
      selectedLabelTextStyle: TextStyle(
        color: tokens.text,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: TextStyle(color: tokens.text3),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: tokens.brand),
  );
}
