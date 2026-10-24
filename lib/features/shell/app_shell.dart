import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_section.dart';
import '../../design/flash_tokens.dart';
import '../chat/chat_page.dart';
import '../logs/logs_page.dart';
import '../models/models_page.dart';
import '../overview/overview_page.dart';
import '../settings/settings_page.dart';
import 'sidebar.dart';

const _sidebarPrefKey = 'flashcat.sidebar.collapsed';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  @override
  void initState() {
    super.initState();
    _restoreSidebar();
    sidebarCollapsedNotifier.addListener(_persistSidebar);
  }

  @override
  void dispose() {
    sidebarCollapsedNotifier.removeListener(_persistSidebar);
    super.dispose();
  }

  Future<void> _restoreSidebar() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    sidebarCollapsedNotifier.value =
        prefs.getBool(_sidebarPrefKey) ?? false;
  }

  void _persistSidebar() {
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setBool(
        _sidebarPrefKey,
        sidebarCollapsedNotifier.value,
      ),
    );
  }

  void _toggleSidebar() {
    sidebarCollapsedNotifier.value = !sidebarCollapsedNotifier.value;
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.digit1, meta: true): () =>
            appSectionNotifier.value = AppSection.overview,
        const SingleActivator(LogicalKeyboardKey.digit2, meta: true): () =>
            appSectionNotifier.value = AppSection.chat,
        const SingleActivator(LogicalKeyboardKey.digit3, meta: true): () =>
            appSectionNotifier.value = AppSection.models,
        const SingleActivator(LogicalKeyboardKey.digit4, meta: true): () =>
            appSectionNotifier.value = AppSection.logs,
        const SingleActivator(LogicalKeyboardKey.digit5, meta: true): () =>
            appSectionNotifier.value = AppSection.settings,
        const SingleActivator(LogicalKeyboardKey.backslash, meta: true):
            _toggleSidebar,
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true): _toggleSidebar,
      },
      child: Focus(
        autofocus: true,
        child: ValueListenableBuilder<AppSection>(
          valueListenable: appSectionNotifier,
          builder: (context, section, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: sidebarCollapsedNotifier,
              builder: (context, collapsed, _) => LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 760;
                  final content = _Content(section: section);
                  if (compact) {
                    return Scaffold(
                      body: SafeArea(child: content),
                      bottomNavigationBar: _CompactNav(section: section),
                    );
                  }
                  return Scaffold(
                    body: SafeArea(
                      child: Row(
                        children: [
                          AppSidebar(
                            section: section,
                            collapsed: collapsed,
                            onToggle: _toggleSidebar,
                          ),
                          Expanded(child: content),
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Content extends StatefulWidget {
  const _Content({required this.section});

  final AppSection section;

  @override
  State<_Content> createState() => _ContentState();
}

class _ContentState extends State<_Content>
    with SingleTickerProviderStateMixin {
  /// The prototype fades each page up over 420ms with this curve.
  static const _curve = Cubic(.2, .8, .2, 1);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  )..forward();

  @override
  void didUpdateWidget(covariant _Content oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section) {
      _controller.forward(from: 0);
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.bg,
        gradient: RadialGradient(
          center: const Alignment(1.1, -1.05),
          radius: 1.35,
          colors: [
            t.brand.withValues(alpha: t.isDark ? .08 : .028),
            t.bg,
          ],
          stops: const [0, .62],
        ),
      ),
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _controller,
          child: IndexedStack(
            index: widget.section.index,
            children: const [
              OverviewPage(),
              ChatPage(),
              ModelsPage(),
              LogsPage(),
              SettingsPage(),
            ],
          ),
          builder: (context, child) {
            final value = _curve.transform(_controller.value);
            return Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, 9 * (1 - value)),
                child: child,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CompactNav extends StatelessWidget {
  const _CompactNav({required this.section});

  final AppSection section;

  @override
  Widget build(BuildContext context) {
    final t = context.flash;
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: NavigationBar(
        selectedIndex: section.index,
        onDestinationSelected: (index) =>
            appSectionNotifier.value = AppSection.values[index],
        destinations: [
          for (final item in AppSection.values)
            NavigationDestination(
              icon: Icon(appSectionIcon(item)),
              selectedIcon: Icon(appSectionIcon(item)),
              label: item.label,
            ),
        ],
      ),
    );
  }
}
