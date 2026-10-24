import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_controller.dart';
import '../core/app_section.dart';

class AppMenuBar extends StatelessWidget {
  const AppMenuBar({
    super.key,
    required this.controller,
    required this.child,
  });

  final AppController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return PlatformMenuBar(
          menus: [
            PlatformMenu(
              label: '文件',
              menus: [
                PlatformMenuItem(
                  label: '打开对话',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyO,
                    meta: true,
                  ),
                  onSelected: () =>
                      appSectionNotifier.value = AppSection.chat,
                ),
                PlatformMenuItem(
                  label: '打开设置',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.comma,
                    meta: true,
                  ),
                  onSelected: () =>
                      appSectionNotifier.value = AppSection.settings,
                ),
                PlatformMenuItem(
                  label: '关闭窗口',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyW,
                    meta: true,
                  ),
                  onSelected: windowManager.close,
                ),
              ],
            ),
            PlatformMenu(
              label: '服务',
              menus: [
                PlatformMenuItem(
                  label: controller.isRunning ? '停止服务' : '启动服务',
                  onSelected: controller.toggleService,
                ),
                PlatformMenuItem(
                  label: '重启服务',
                  onSelected: controller.restartService,
                ),
              ],
            ),
            PlatformMenu(
              label: '显示',
              menus: [
                PlatformMenuItem(
                  label: '概览',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.digit1,
                    meta: true,
                  ),
                  onSelected: () =>
                      appSectionNotifier.value = AppSection.overview,
                ),
                PlatformMenuItem(
                  label: '对话',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.digit2,
                    meta: true,
                  ),
                  onSelected: () =>
                      appSectionNotifier.value = AppSection.chat,
                ),
                PlatformMenuItem(
                  label: '模型',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.digit3,
                    meta: true,
                  ),
                  onSelected: () =>
                      appSectionNotifier.value = AppSection.models,
                ),
                PlatformMenuItem(
                  label: '日志',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.digit4,
                    meta: true,
                  ),
                  onSelected: () =>
                      appSectionNotifier.value = AppSection.logs,
                ),
                PlatformMenuItem(
                  label: '设置',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.digit5,
                    meta: true,
                  ),
                  onSelected: () =>
                      appSectionNotifier.value = AppSection.settings,
                ),
                PlatformMenuItem(
                  label: '折叠 / 展开侧边栏',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.backslash,
                    meta: true,
                  ),
                  onSelected: () => sidebarCollapsedNotifier.value =
                      !sidebarCollapsedNotifier.value,
                ),
              ],
            ),
          ],
          child: child,
        );
      },
    );
  }
}
