import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/app_controller.dart';
import 'core/theme/app_theme.dart';
import 'features/shell/app_shell.dart';
import 'widgets/app_menu_bar.dart';

class AppScope extends InheritedNotifier<AppController> {
  const AppScope({
    super.key,
    required AppController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing');
    return scope!.notifier!;
  }

  static AppController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing');
    return scope!.notifier!;
  }
}

class FlashCatApp extends StatelessWidget {
  const FlashCatApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final app = MaterialApp(
      title: 'flashCat',
      debugShowCheckedModeBanner: false,
      theme: buildFlashCatTheme(Brightness.light),
      darkTheme: buildFlashCatTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const AppShell(),
    );
    final scoped = AppScope(controller: controller, child: app);
    if (!Platform.isMacOS) return scoped;
    return AppMenuBar(controller: controller, child: scoped);
  }
}
