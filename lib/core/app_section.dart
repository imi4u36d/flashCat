import 'package:flutter/foundation.dart';

enum AppSection {
  overview('概览', 'gauge'),
  chat('对话', 'chat'),
  models('模型', 'models'),
  logs('日志', 'logs'),
  settings('设置', 'settings');

  const AppSection(this.label, this.key);

  final String label;
  final String key;
}

final appSectionNotifier = ValueNotifier<AppSection>(AppSection.overview);

/// Sidebar collapse state is shared with the native menu bar.
final sidebarCollapsedNotifier = ValueNotifier<bool>(false);
