import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Expose the full semantics tree so assistive technology (and the
  // automation harness used for UI verification) can drive the app.
  if (kDebugMode) SemanticsBinding.instance.ensureSemantics();
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    await windowManager.ensureInitialized();
    final bounds = await _initialBounds();
    final options = WindowOptions(
      size: bounds.size,
      minimumSize: Size(
        math.min(940.0, bounds.width),
        math.min(620.0, bounds.height),
      ),
      title: 'flashCat',
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setPosition(bounds.topLeft);
      await windowManager.show();
      await windowManager.focus();
    });
  }
  final controller = AppController();
  await controller.initialize();
  // 窗口关闭时结束推理服务：它不会跟着应用一起退出，否则会成为孤儿进程，
  // 继续占着端口，下一次启动就报“端口已被占用”。
  await windowManager.setPreventClose(true);
  windowManager.addListener(_ShutdownListener(controller));
  runApp(FlashCatApp(controller: controller));
}

double _clamp(double value, double low, double high) {
  if (high < low) return low;
  return value.clamp(low, high);
}

/// 上次的窗口位置，前提是它仍然落在某块接着的屏幕上；否则按主屏幕居中。
Future<Rect> _initialBounds() async {
  final displays = await _displays();
  final saved = await _savedBounds();
  if (saved != null && _onSomeDisplay(saved, displays)) return saved;

  final display = _menuBarDisplay(displays);
  final visible = display.visibleSize ?? display.size;
  final origin = display.visiblePosition ?? Offset.zero;
  // Never ask for a window bigger than the display it opens on.
  final size = Size(
    math.min((visible.width - 96).clamp(940, 1260).toDouble(), visible.width),
    math.min((visible.height - 96).clamp(620, 800).toDouble(), visible.height),
  );
  // Center, then clamp into the visible area: a display laid out left of the
  // main one has a negative origin, and a window placed there on a machine
  // whose screens changed is easy to lose.
  return Rect.fromLTWH(
    _clamp(
      origin.dx + (visible.width - size.width) / 2,
      origin.dx,
      origin.dx + visible.width - size.width,
    ),
    _clamp(
      origin.dy + (visible.height - size.height) / 2,
      origin.dy,
      origin.dy + visible.height - size.height,
    ),
    size.width,
    size.height,
  );
}

Future<List<Display>> _displays() async {
  try {
    final displays = await screenRetriever.getAllDisplays();
    if (displays.isNotEmpty) return displays;
  } catch (_) {
    // Fall through to the primary display.
  }
  try {
    return [await screenRetriever.getPrimaryDisplay()];
  } catch (_) {
    return const [];
  }
}

/// 菜单栏所在的主显示器：它的可见区域顶边最靠上。
Display _menuBarDisplay(List<Display> displays) {
  if (displays.isEmpty) {
    return const Display(
      id: '0',
      size: Size(1440, 900),
      visiblePosition: Offset.zero,
      visibleSize: Size(1440, 860),
    );
  }
  var best = displays.first;
  for (final display in displays) {
    final dy = display.visiblePosition?.dy ?? 0;
    if (dy > (best.visiblePosition?.dy ?? 0)) best = display;
  }
  return best;
}

bool _onSomeDisplay(Rect bounds, List<Display> displays) {
  if (displays.isEmpty) return false;
  final probe = bounds.topLeft + const Offset(80, 40);
  for (final display in displays) {
    final origin = display.visiblePosition ?? Offset.zero;
    final size = display.visibleSize ?? display.size;
    if (probe.dx >= origin.dx &&
        probe.dx <= origin.dx + size.width &&
        probe.dy >= origin.dy &&
        probe.dy <= origin.dy + size.height) {
      return true;
    }
  }
  return false;
}

const _kLeft = 'window.left';
const _kTop = 'window.top';
const _kWidth = 'window.width';
const _kHeight = 'window.height';

Future<Rect?> _savedBounds() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final left = prefs.getDouble(_kLeft);
    final top = prefs.getDouble(_kTop);
    final width = prefs.getDouble(_kWidth);
    final height = prefs.getDouble(_kHeight);
    if (left == null || top == null || width == null || height == null) {
      return null;
    }
    if (width < 200 || height < 200) return null;
    return Rect.fromLTWH(left, top, width, height);
  } catch (_) {
    return null;
  }
}

Future<void> _rememberBounds() async {
  try {
    final position = await windowManager.getPosition();
    final size = await windowManager.getSize();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kLeft, position.dx);
    await prefs.setDouble(_kTop, position.dy);
    await prefs.setDouble(_kWidth, size.width);
    await prefs.setDouble(_kHeight, size.height);
  } catch (_) {
    // 记不住位置不影响使用。
  }
}

class _ShutdownListener extends WindowListener {
  _ShutdownListener(this.controller);

  final AppController controller;
  bool _closing = false;
  Timer? _save;

  @override
  void onWindowMove() => _scheduleSave();

  @override
  void onWindowResize() => _scheduleSave();

  void _scheduleSave() {
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 600), () {
      unawaited(_rememberBounds());
    });
  }

  @override
  void onWindowClose() {
    if (_closing) return;
    _closing = true;
    unawaited(_shutdown());
  }

  Future<void> _shutdown() async {
    _save?.cancel();
    await _rememberBounds();
    try {
      final server = controller.server;
      if (server != null) {
        await server.dispose().timeout(
          const Duration(seconds: 5),
          onTimeout: () {},
        );
      }
    } catch (_) {
      // 清理推理服务失败也必须让窗口关掉，否则应用会永远退不出去。
    }
    try {
      // destroy() 绕过 setPreventClose：close() 会被我们自己的防误关拦截，
      // 窗口因此永远关不掉。
      await windowManager.destroy();
    } catch (_) {
      exit(0);
    }
    // 窗口没了还没退出（例如系统没有按最后一个窗口关闭来终止），强制退出。
    await Future<void>.delayed(const Duration(milliseconds: 800));
    exit(0);
  }
}
