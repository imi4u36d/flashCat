import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'models/model_catalog.dart';
import 'runtime/engine_runtime.dart';
import 'runtime/local_api.dart';
import 'runtime/runtime_updater.dart';
import 'runtime/server_controller.dart';
import 'settings/app_settings.dart';

class AppController extends ChangeNotifier {
  late AppSettings settings;
  EngineRuntime? runtime;
  ModelCatalog? catalog;
  ServerController? server;
  RuntimeUpdater? runtimeUpdater;
  String? startupError;
  final List<String> logs = [];
  bool _disposed = false;

  ServerStats? get stats => server?.stats;
  ServerState get serverState => server?.state ?? ServerState.stopped;
  bool get isReady => server?.isReady ?? false;
  bool get isRunning => server?.isRunning ?? false;
  int get port => server?.port ?? settings.port;
  String get currentModel => settings.model;
  List<String> get recommended => catalog?.recommended ?? const [];
  List<ModelInfo> get machineModels => catalog?.machine ?? const [];
  bool get runtimeReady => runtime != null;
  bool get usingManagedRuntime => EngineRuntime.usingManagedRuntime;
  File get logFile => File(
        p.join(
          EngineRuntime.home,
          'Library',
          'Logs',
          'flashCat',
          'server.log',
        ),
      );

  Future<void> initialize() async {
    settings = await AppSettings.load();
    final modelService = ModelCatalogService();
    if (Platform.isMacOS) {
      try {
        await modelService.migrateLegacyDirectory();
      } catch (error) {
        debugPrint('legacy model migration failed: $error');
      }
    }
    await ModelCatalogService.localDirectory.create(recursive: true);
    runtime = EngineRuntime.locate();
    if (runtime == null) {
      startupError =
          '未找到内置推理运行时。macOS 请使用 make app 打包；开发时可用 FLASHCAT_RUNTIME 指向运行时目录。';
    }
    catalog = await modelService.load(runtime);
    if (settings.model.isEmpty) {
      settings.model = catalog!.machine.firstOrNull?.id ??
          catalog!.recommended.firstOrNull ??
          '';
    }
    if (runtime != null) {
      server = ServerController(
        runtime: runtime!,
        settings: settings,
        catalog: catalog!,
        onChanged: _notify,
        onLog: _appendLog,
      )..port = settings.port;
      runtimeUpdater = RuntimeUpdater(
        currentVersion: runtime!.version,
        onStateChanged: _notify,
        onRuntimeInstalled: _switchRuntime,
      );
      if (settings.autoStart && settings.model.isNotEmpty) {
        unawaited(startService());
      }
    }
    notifyListeners();
  }

  Future<void> reloadModels({bool notify = true}) async {
    catalog = await ModelCatalogService().load(runtime);
    server?.updateCatalog(catalog!);
    if (settings.model.isEmpty) {
      settings.model = catalog!.machine.firstOrNull?.id ??
          catalog!.recommended.firstOrNull ??
          '';
    }
    if (notify) notifyListeners();
  }

  Future<void> startService() async {
    final currentServer = server;
    if (currentServer == null) return;
    final model = catalog?.localModel(settings.model);
    await currentServer.start(localModel: model);
  }

  Future<void> stopService() async {
    await server?.stop();
  }

  Future<void> toggleService() async {
    final currentServer = server;
    if (currentServer == null) return;
    if (currentServer.isRunning) {
      await currentServer.stop();
    } else {
      await currentServer.start(localModel: catalog?.localModel(settings.model));
    }
  }

  Future<void> restartService() async {
    final currentServer = server;
    if (currentServer == null) return;
    await currentServer.restart(localModel: catalog?.localModel(settings.model));
  }

  Future<void> applyModel(String id) async {
    final wasRunning = server?.isRunning ?? false;
    settings.model = id;
    settings.rememberModel(id);
    notifyListeners();
    if (wasRunning) {
      await restartService();
    }
  }

  Future<void> downloadModel(String id) async {
    final currentRuntime = runtime;
    if (currentRuntime == null) throw StateError('运行时不可用');
    final script = File(p.join(currentRuntime.root, 'install', 'models.py'));
    if (!script.existsSync()) {
      throw StateError('内置运行时缺少 install/models.py');
    }
    await ModelCatalogService.localDirectory.create(recursive: true);
    final args = <String>[
      '-u',
      script.path,
      '--models',
      ModelCatalogService.localDirectory.path,
      '--model',
      id,
    ];
    final draft = catalog?.draftRepository(id, null);
    if (draft != null) args.addAll(['--draft-model', draft]);
    args.add('prepare');
    final environment = Map<String, String>.from(Platform.environment)
      ..['PYTHONDONTWRITEBYTECODE'] = '1'
      ..['PYTHONUNBUFFERED'] = '1';
    if (settings.hfCache.trim().isNotEmpty) {
      environment['HF_HUB_CACHE'] = settings.hfCache.trim();
    }
    _appendLog('==> 准备下载模型：$id');
    final process = await Process.start(
      currentRuntime.pythonPath,
      args,
      workingDirectory: currentRuntime.root,
      environment: environment,
    );
    await Future.wait([
      _pipeProcessOutput(process.stdout),
      _pipeProcessOutput(process.stderr),
    ]);
    final code = await process.exitCode;
    if (code != 0) {
      throw StateError('模型下载失败，退出码 $code');
    }
    await reloadModels();
    await applyModel(id);
  }

  Future<ModelImportResult> importModel(
    Directory source, {
    bool move = false,
    void Function(double fraction, String message)? onProgress,
  }) async {
    final result = await ModelCatalogService().importDirectory(
      source,
      move: move,
      onProgress: onProgress,
    );
    await reloadModels();
    return result;
  }

  Future<void> deleteModel(ModelInfo model) async {
    await ModelCatalogService().deleteLocal(model);
    if (settings.model == model.id) {
      settings.model =
          catalog?.machine.firstWhereOrNull((item) => item.id != model.id)?.id ??
              '';
    }
    await reloadModels();
  }

  Future<void> clearLogs() async {
    logs.clear();
    notifyListeners();
  }

  Future<void> checkRuntimeUpdate() async {
    await runtimeUpdater?.check();
  }

  Future<void> installRuntimeUpdate() async {
    await runtimeUpdater?.install();
  }

  Future<void> restoreBundledRuntime() async {
    await runtimeUpdater?.restoreBundled();
  }

  void _switchRuntime(EngineRuntime newRuntime) {
    runtime = newRuntime;
    final serverWasRunning = server?.isRunning ?? false;
    if (serverWasRunning) unawaited(server?.stop());
    final replacement = ServerController(
      runtime: newRuntime,
      settings: settings,
      catalog: catalog ??
          const ModelCatalog(
            local: [],
            installed: [],
            recommended: [],
            draftRepositories: {},
          ),
      onChanged: _notify,
      onLog: _appendLog,
    )..port = settings.port;
    unawaited(server?.dispose());
    server = replacement;
    runtimeUpdater?.currentVersion = newRuntime.version;
    if (serverWasRunning) unawaited(startService());
    notifyListeners();
  }

  void _appendLog(String line) {
    logs.add(line);
    if (logs.length > 12000) {
      logs.removeRange(0, logs.length - 12000);
    }
    _notify();
  }

  Future<void> _pipeProcessOutput(Stream<List<int>> stream) async {
    var buffer = '';
    await for (final chunk in stream.transform(utf8.decoder)) {
      buffer += chunk;
      while (true) {
        final newline = buffer.indexOf('\n');
        if (newline < 0) break;
        final line = buffer.substring(0, newline).replaceAll('\r', '');
        buffer = buffer.substring(newline + 1);
        if (line.isNotEmpty) _appendLog(line);
      }
    }
    if (buffer.trim().isNotEmpty) _appendLog(buffer.trim());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(server?.dispose());
    super.dispose();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T item) predicate) {
    for (final item in this) {
      if (predicate(item)) return item;
    }
    return null;
  }
}
