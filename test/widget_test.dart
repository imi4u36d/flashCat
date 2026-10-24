// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flash_cat/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds Material 3 light and dark themes', () {
    final light = buildFlashCatTheme(Brightness.light);
    final dark = buildFlashCatTheme(Brightness.dark);
    expect(light.useMaterial3, isTrue);
    expect(light.colorScheme.brightness, Brightness.light);
    expect(dark.colorScheme.brightness, Brightness.dark);
    expect(light.extension<FlashCatColors>(), isNotNull);
    expect(dark.extension<FlashCatColors>(), isNotNull);
  });
}
