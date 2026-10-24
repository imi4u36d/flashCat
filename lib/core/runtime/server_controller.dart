import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/model_catalog.dart';
import '../settings/app_settings.dart';
import 'engine_runtime.dart';
import 'local_api.dart';

enum ServerState { stopped, starting, ready, stopping, failed }

class ServerController {
  ServerController({
    required this.runtime,
    required this.settings,
    required this.catalog,
    this.onChanged,
    this.onLog,
  }) : _api = LocalApi();

  EngineRuntime runtime;
  final AppSettings settings;
  ModelCatalog catalog;
  final void Function()? onChanged;
  final void Function(String line)? onLog;
  final LocalApi _api;

  ServerState state = ServerState.stopped;
  String? failureMessage;
  ServerStats? stats;
  int port = 8000;
  String model = '';
  DateTime? busySince;

  Process? _process;
  int? _attachedPid;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  Timer? _pollTimer;
  bool _pollInFlight = false;
  bool _stopping = false;
  String? _lastError;
  IOSink? _logSink;
  final List<String> _lineBuffers = ['', ''];

  bool get isRunning =>
      state == ServerState.starting ||
      state == ServerState.ready ||
      state == ServerState.stopping;

  bool get isReady => state == ServerState.ready;

  /// 当前服务进程：本应用启动的子进程，或接入的外部遗留服务进程。
  int? get serverPid => _process?.pid ?? _attachedPid;

  bool get attachedToExternalService => _process == null && _attachedPid != null;

  String get statusText {
    switch (state) {
      case ServerState.stopped:
        return '未运行';
      case ServerState.starting:
        return '启动中…';
      case ServerState.stopping:
        return '停止中…';
      case ServerState.ready:
        final parts = <String>['运行中'];
        final rate = stats?.decodeTokensPerSecond;
        if (rate != null && rate > 0) {
          parts.add('${rate.toStringAsFixed(0)} tok/s');
        }
        final requests = stats?.activeRequests ?? 0;
        if (requests > 0) parts.add('$requests 个请求');
        return parts.join(' · ');
      case ServerState.failed:
        return failureMessage ?? '服务异常';
    }
  }

  String get startupStage {
    if (state != ServerState.starting) return '';
    final lines = _recentLogs;
    for (final line in lines.reversed) {
      final lower = line.toLowerCase();
      if (lower.contains('download')) return '正在下载模型权重…';
      if (lower.contains('warmup') || lower.contains('warm-up')) {
        return '正在预热引擎…';
      }
      if (lower.contains('loading') || lower.contains('load model')) {
        return '正在加载模型…';
      }
      if (lower.contains('ready')) return '正在完成初始化…';
    }
    return '正在启动推理引擎…';
  }

  List<String> get _recentLogs => _logHistory.reversed.take(80).toList();
  final List<String> _logHistory = [];

  double? get downloadProgress {
    for (final line in _logHistory.reversed.take(40)) {
      final match = RegExp(r'([0-9]{1,3}(?:\.[0-9]+)?)%').firstMatch(line);
      if (match != null) {
        final value = double.tryParse(match.group(1)!);
        if (value != null) return (value / 100).clamp(0, 1);
      }
    }
    return null;
  }

  void updateCatalog(ModelCatalog value) {
    catalog = value;
  }

  void updateRuntime(EngineRuntime value) {
    runtime = value;
    if (isRunning) restart();
  }

  Future<void> start({ModelInfo? localModel, String? requestedModel}) async {
    if (_process != null) return;
    final selectedModel =
        requestedModel ?? (settings.model.isEmpty ? null : settings.model);
    if (selectedModel == null || selectedModel.isEmpty) {
      state = ServerState.failed;
      failureMessage = '还没有选择模型';
      onChanged?.call();
      return;
    }
    port = settings.port;
    model = selectedModel;

    final outcome = await _claimPort(selectedModel);
    if (outcome == null) {
      state = ServerState.failed;
      onChanged?.call();
      return;
    }
    if (outcome.attached != null) {
      _attach(outcome.attached!);
      return;
    }
    port = outcome.port;

    final serveScript = File(runtime.serveScriptPath).existsSync()
        ? runtime.serveScriptPath
        : p.join(
            EngineRuntime.bundledResourcesDirectory?.path ?? runtime.root,
            'flashcat_serve.py',
          );
    final arguments = <String>[];
    if (localModel != null) {
      if (!File(serveScript).existsSync()) {
        state = ServerState.failed;
        failureMessage = '缺少 flashcat_serve.py，无法启动本地模型';
        onChanged?.call();
        return;
      }
      arguments.addAll([
        '-u',
        serveScript,
        '--runtime',
        runtime.root,
        '--models-dir',
        ModelCatalogService.localDirectory.path,
        '--target',
        localModel.targetName,
        '--model',
        localModel.id,
        '--port',
        '$port',
      ]);
      if (localModel.draftPath != null) {
        arguments.addAll(['--draft', localModel.draftPath!]);
      }
      final languageOnly = settings.languageOnly;
      if (localModel.mmprojPath != null && !languageOnly) {
        arguments.addAll(['--mmproj', localModel.mmprojPath!]);
      }
      arguments.addAll(settings.serveArguments().where((item) => item != '--offline'));
    } else {
      arguments.addAll([
        '-u',
        runtime.launcherPath,
        'serve',
        '--model',
        selectedModel,
        '--port',
        '$port',
        ...settings.serveArguments(),
      ]);
    }

    _openLog();
    _appendLog('==> flashCat 启动服务：$selectedModel · 端口 $port');
    _appendLog('==> ${runtime.pythonPath} ${arguments.join(' ')}');

    try {
      final environment = Map<String, String>.from(Platform.environment)
        ..['PYTHONDONTWRITEBYTECODE'] = '1';
      final cache = settings.hfCache.trim();
      if (cache.isNotEmpty) environment['HF_HUB_CACHE'] = cache;
      final process = await Process.start(
        runtime.pythonPath,
        arguments,
        workingDirectory: runtime.root,
        environment: environment,
      );
      _process = process;
      _writePidFile(process.pid);
      state = ServerState.starting;
      failureMessage = null;
      stats = null;
      _stopping = false;
      busySince = DateTime.now();
      _stdout = process.stdout
          .transform(utf8.decoder)
          .listen((chunk) => _ingest(chunk, 0));
      _stderr = process.stderr
          .transform(utf8.decoder)
          .listen((chunk) => _ingest(chunk, 1));
      unawaited(process.exitCode.then(_processExited));
      _startPolling();
      onChanged?.call();
    } catch (error) {
      _closeLog();
      state = ServerState.failed;
      failureMessage = '无法启动服务：$error';
      onChanged?.call();
    }
  }

  Future<void> stop() async {
    final process = _process;
    final attached = _attachedPid;
    if (process == null && attached == null) {
      state = ServerState.stopped;
      onChanged?.call();
      return;
    }
    if (_stopping) return;
    _stopping = true;
    state = ServerState.stopping;
    busySince = DateTime.now();
    _appendLog('==> 正在停止服务…');
    onChanged?.call();
    if (process != null) {
      process.kill(ProcessSignal.sigint);
      unawaited(
        Future<void>.delayed(const Duration(seconds: 20), () {
          if (_process?.pid == process.pid) {
            _appendLog('==> 服务未在 20 秒内退出，强制结束');
            process.kill(ProcessSignal.sigkill);
          }
        }),
      );
      return;
    }
    // 接入的服务：它不是本应用启动的子进程，只能按 pid 结束。
    await _killPid(attached!, ProcessSignal.sigint);
    unawaited(
      Future<void>.delayed(const Duration(seconds: 20), () async {
        if (_attachedPid == attached) {
          _appendLog('==> 接入的服务未在 20 秒内退出，强制结束（pid $attached）');
          await _killPid(attached, ProcessSignal.sigkill);
          _attachedPid = null;
          _removePidFile();
          _pollTimer?.cancel();
          if (state == ServerState.stopping) {
            state = ServerState.stopped;
            onChanged?.call();
          }
        }
      }),
    );
  }

  Future<void> restart({ModelInfo? localModel}) async {
    if (isRunning) {
      await stop();
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline)) {
        final stillRunning =
            _process != null || _attachedPid != null || await _portOpen(port);
        if (!stillRunning) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    await start(localModel: localModel);
  }

  void toggle({ModelInfo? localModel}) {
    if (isRunning) {
      unawaited(stop());
    } else {
      unawaited(start(localModel: localModel));
    }
  }

  Future<void> dispose() async {
    _pollTimer?.cancel();
    await _stdout?.cancel();
    await _stderr?.cancel();
    if (_process != null) {
      _process!.kill(ProcessSignal.sigint);
      try {
        await _process!.exitCode.timeout(const Duration(seconds: 8));
      } on TimeoutException {
        _process?.kill(ProcessSignal.sigkill);
      }
    }
    if (_attachedPid != null) {
      final pid = _attachedPid!;
      await _killPid(pid, ProcessSignal.sigint);
      unawaited(
        Future<void>.delayed(const Duration(seconds: 15), () async {
          if (_attachedPid == pid && await _portOpen(port)) {
            await _killPid(pid, ProcessSignal.sigkill);
            _attachedPid = null;
          }
        }),
      );
    }
    _removePidFile();
    _api.close();
    _closeLog();
  }

  Future<void> _processExited(int code) async {
    if (_process == null) return;
    _removePidFile();
    _pollTimer?.cancel();
    _pollTimer = null;
    await _stdout?.cancel();
    await _stderr?.cancel();
    _stdout = null;
    _stderr = null;
    _process = null;
    _flushBuffers();
    _closeLog();
    stats = null;
    busySince = null;
    final wasStopping = _stopping;
    _stopping = false;
    if (wasStopping) {
      _appendLog('==> 服务已停止');
      state = ServerState.stopped;
    } else if (code == 0) {
      state = ServerState.stopped;
    } else {
      state = ServerState.failed;
      failureMessage = _lastError ?? '服务异常退出（退出码 $code）';
      _appendLog('==> $failureMessage');
    }
    onChanged?.call();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_pollInFlight || (_process == null && _attachedPid == null)) return;
    _pollInFlight = true;
    try {
      final ready = await _api.ready(port);
      if (ready) {
        if (state == ServerState.starting) {
          state = ServerState.ready;
          onChanged?.call();
        }
        final value = await _api.status(port);
        if (value != null) {
          stats = value;
          onChanged?.call();
        }
      } else if (_process == null && _attachedPid != null) {
          // 接入的外部服务已经退出。
          if (!await _portOpen(port)) {
            _attachedPid = null;
            _removePidFile();
            _pollTimer?.cancel();
            if (state != ServerState.stopping) {
              state = ServerState.stopped;
              onChanged?.call();
            }
          }
        }
    } finally {
      _pollInFlight = false;
    }
  }

  void _ingest(String chunk, int index) {
    var buffer = _lineBuffers[index] + chunk;
    while (true) {
      final newline = buffer.indexOf('\n');
      if (newline < 0) break;
      final line = buffer.substring(0, newline).replaceAll('\r', '');
      buffer = buffer.substring(newline + 1);
      _appendLog(line);
    }
    _lineBuffers[index] = buffer;
  }

  void _flushBuffers() {
    for (var index = 0; index < _lineBuffers.length; index++) {
      if (_lineBuffers[index].isNotEmpty) {
        _appendLog(_lineBuffers[index]);
        _lineBuffers[index] = '';
      }
    }
  }

  void appendExternalLog(String line) => _appendLog(line);

  void _appendLog(String line) {
    if (_logHistory.length >= 20000) {
      _logHistory.removeRange(0, _logHistory.length - 20000);
    }
    _logHistory.add(line);
    if (line.contains('Ready ·')) {
      _lastError = null;
      if (state == ServerState.starting) state = ServerState.ready;
    } else if (line.contains('Error ·')) {
      _lastError = line;
    }
    _logSink?.writeln(line);
    onLog?.call(line);
  }

  void _openLog() {
    final file = File(
      p.join(
        EngineRuntime.home,
        'Library',
        'Logs',
        'flashCat',
        'server.log',
      ),
    );
    file.parent.createSync(recursive: true);
    _closeLog();
    _logSink = file.openWrite(mode: FileMode.append);
  }

  void _closeLog() {
    _logSink?.close();
    _logSink = null;
  }

  static Future<bool> _portOpen(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 350),
      );
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _waitForPortFree(int port, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!await _portOpen(port)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return !await _portOpen(port);
  }

  /// 端口被占用时判断：是本应用已经跑着的同一服务（接入），是本应用上次遗留
  /// 的进程（回收），还是其它程序（换端口）。
  Future<_PortOutcome?> _claimPort(String selectedModel) async {
    final wanted = settings.port;
    if (!await _portOpen(wanted)) {
      final stale = _readPidFile();
      if (stale != null) {
        _note('==> 清理上次遗留的服务进程（pid $stale）…');
        await _killPid(stale, ProcessSignal.sigint);
        await _waitForPortFree(wanted, const Duration(seconds: 10));
      }
      return _PortOutcome(port: wanted);
    }

    final listener = await _api.status(wanted);
    if (listener != null) {
      if (listener.model == selectedModel) {
        _note(
          '==> 端口 $wanted 上已有相同模型的服务（pid ${listener.instancePid ?? '未知'}），直接接入，不重复启动',
        );
        return _PortOutcome(port: wanted, attached: listener);
      }
      final pid = listener.instancePid;
      if (pid != null && pid == _readPidFile()) {
        _note('==> 端口 $wanted 上是本应用上次遗留的服务（pid $pid），正在结束它…');
        await _killPid(pid, ProcessSignal.sigint);
        if (await _waitForPortFree(wanted, const Duration(seconds: 60))) {
          _removePidFile();
          return _PortOutcome(port: wanted);
        }
        failureMessage =
            '遗留的服务进程（pid $pid）未能退出，端口 $wanted 仍被占用';
        return null;
      }
      failureMessage =
          '端口 $wanted 已被其它推理服务占用（模型 ${listener.model ?? '未知'}，pid ${pid ?? '未知'}）。请改用其它端口，或先结束该进程。';
      return null;
    }

    // 端口上是其它程序：尝试邻近端口，并记住成功的那个。
    for (var candidate = wanted + 1; candidate <= wanted + 10; candidate++) {
      if (candidate > 65535) break;
      if (!await _portOpen(candidate)) {
        _note('==> 端口 $wanted 被其它程序占用，自动改用 $candidate');
        settings.port = candidate;
        return _PortOutcome(port: candidate);
      }
    }

    failureMessage = '端口 $wanted 已被占用，请在设置中选择其它端口';
    return null;
  }

  void _attach(ServerStats listener) {
    _attachedPid = listener.instancePid;
    _stopping = false;
    stats = listener;
    failureMessage = null;
    busySince = DateTime.now();
    state = ServerState.ready;
    _openLog();
    _appendLog(
      '==> flashCat 接入已有服务：${listener.model} · 端口 $port · pid ${listener.instancePid ?? '未知'}',
    );
    if (_attachedPid != null) _writePidFile(_attachedPid!);
    _startPolling();
    onChanged?.call();
  }

  void _note(String line) {
    _openLog();
    _appendLog(line);
    _closeLog();
  }

  Future<bool> _killPid(int pid, ProcessSignal signal) async {
    try {
      final result = await Process.run('/bin/kill', ['-${signal.name}', '$pid']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  File get _pidFile => File(
        p.join(EngineRuntime.supportDirectory.path, 'server.pid'),
      );

  void _writePidFile(int pid) {
    try {
      _pidFile.writeAsString('$pid');
    } catch (_) {
      // 记录失败不影响启动。
    }
  }

  int? _readPidFile() {
    try {
      if (!_pidFile.existsSync()) return null;
      return int.tryParse(_pidFile.readAsStringSync().trim());
    } catch (_) {
      return null;
    }
  }

  void _removePidFile() {
    try {
      if (_pidFile.existsSync()) _pidFile.delete();
    } catch (_) {
      // 忽略。
    }
  }
}

class _PortOutcome {
  const _PortOutcome({required this.port, this.attached});

  final int port;
  final ServerStats? attached;
}
