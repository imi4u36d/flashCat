import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'engine_runtime.dart';

enum RuntimeUpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  preparing,
  downloading,
  verifying,
  installing,
  installed,
  failed,
}

class RuntimeUpdateState {
  const RuntimeUpdateState({
    this.phase = RuntimeUpdatePhase.idle,
    this.version,
    this.availableVersion,
    this.progress,
    this.message,
  });

  final RuntimeUpdatePhase phase;
  final String? version;
  final String? availableVersion;
  final double? progress;
  final String? message;

  bool get busy => {
        RuntimeUpdatePhase.checking,
        RuntimeUpdatePhase.preparing,
        RuntimeUpdatePhase.downloading,
        RuntimeUpdatePhase.verifying,
        RuntimeUpdatePhase.installing,
      }.contains(phase);
}

class RuntimeUpdater {
  RuntimeUpdater({
    required this.currentVersion,
    required this.onStateChanged,
    required this.onRuntimeInstalled,
  });

  final void Function() onStateChanged;
  final void Function(EngineRuntime runtime) onRuntimeInstalled;
  String currentVersion;
  RuntimeUpdateState state = const RuntimeUpdateState();
  String? _assetUrl;
  String? _assetDigest;
  String? _checksumUrl;

  Future<void> check() async {
    if (state.busy) return;
    state = RuntimeUpdateState(
      phase: RuntimeUpdatePhase.checking,
      version: currentVersion,
    );
    onStateChanged();
    try {
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/incoai/splash/releases/latest'),
        headers: const {
          'User-Agent': 'flashCat',
          'Accept': 'application/vnd.github+json',
        },
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('GitHub 返回 HTTP ${response.statusCode}');
      }
      final release = jsonDecode(utf8.decode(response.bodyBytes));
      if (release is! Map) throw Exception('无法解析发布信息');
      final tag = release['tag_name'] as String? ?? '';
      final assets = release['assets'];
      if (assets is! List) throw Exception('发布信息缺少资源列表');
      final expectedName = 'splash-$tag-arm64-macos26.tar.gz';
      Map? asset;
      for (final item in assets) {
        if (item is Map && item['name'] == expectedName) {
          asset = item;
          break;
        }
      }
      if (asset == null) throw Exception('版本 $tag 没有 macOS 运行时归档');
      _assetUrl = asset['browser_download_url'] as String?;
      final digest = asset['digest'] as String?;
      _assetDigest = digest?.toLowerCase().replaceFirst('sha256:', '');
      _checksumUrl = null;
      for (final item in assets) {
        if (item is! Map) continue;
        final name = item['name'] as String?;
        if (name == '$expectedName.sha256' || name == 'SHA256SUMS') {
          _checksumUrl = item['browser_download_url'] as String?;
          break;
        }
      }
      final newer = _isNewer(tag, currentVersion);
      state = RuntimeUpdateState(
        phase: newer
            ? RuntimeUpdatePhase.available
            : RuntimeUpdatePhase.upToDate,
        version: currentVersion,
        availableVersion: tag,
      );
    } catch (error) {
      state = RuntimeUpdateState(
        phase: RuntimeUpdatePhase.failed,
        version: currentVersion,
        message: '检查更新失败：$error',
      );
    }
    onStateChanged();
  }

  Future<void> install() async {
    if (state.busy) return;
    if (state.phase != RuntimeUpdatePhase.available ||
        _assetUrl == null ||
        state.availableVersion == null) {
      await check();
      return;
    }
    final version = state.availableVersion!;
    final directory = EngineRuntime.runtimesDirectory;
    await directory.create(recursive: true);
    final archive = File(
      p.join(directory.path, '.download-${DateTime.now().microsecondsSinceEpoch}.tar.gz'),
    );
    try {
      state = RuntimeUpdateState(
        phase: RuntimeUpdatePhase.downloading,
        version: currentVersion,
        availableVersion: version,
        progress: 0,
      );
      onStateChanged();
      final request = http.Request('GET', Uri.parse(_assetUrl!))
        ..headers['User-Agent'] = 'flashCat'
        ..headers['Accept'] = 'application/octet-stream';
      final response = await http.Client().send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('下载失败：HTTP ${response.statusCode}');
      }
      final total = response.contentLength;
      final sink = archive.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total != null && total > 0) {
          state = RuntimeUpdateState(
            phase: RuntimeUpdatePhase.downloading,
            version: currentVersion,
            availableVersion: version,
            progress: received / total,
          );
          onStateChanged();
        }
      }
      await sink.flush();
      await sink.close();

      state = RuntimeUpdateState(
        phase: RuntimeUpdatePhase.verifying,
        version: currentVersion,
        availableVersion: version,
      );
      onStateChanged();
      if ((_assetDigest == null || _assetDigest!.length != 64) &&
          _checksumUrl != null) {
        final checksumResponse = await http.get(
          Uri.parse(_checksumUrl!),
          headers: const {'User-Agent': 'flashCat'},
        );
        if (checksumResponse.statusCode >= 200 &&
            checksumResponse.statusCode < 300) {
          final text = utf8.decode(checksumResponse.bodyBytes);
          final match = RegExp(r'[0-9a-fA-F]{64}').firstMatch(text);
          _assetDigest = match?.group(0);
        }
      }
      if (_assetDigest == null || _assetDigest!.length != 64) {
        throw Exception('发布页没有提供 SHA-256 校验值');
      }
      final actual = await _sha256(archive);
      if (actual.toLowerCase() != _assetDigest!.toLowerCase()) {
        throw Exception('SHA-256 校验失败');
      }

      state = RuntimeUpdateState(
        phase: RuntimeUpdatePhase.installing,
        version: currentVersion,
        availableVersion: version,
      );
      onStateChanged();
      final destination = Directory(p.join(EngineRuntime.runtimesDirectory.path, version));
      if (destination.existsSync()) {
        await destination.delete(recursive: true);
      }
      await destination.create(recursive: true);
      final result = await Process.run(
        '/usr/bin/tar',
        ['-xzf', archive.path, '--strip-components=1', '-C', destination.path],
      );
      if (result.exitCode != 0) {
        throw Exception('解包失败：${result.stderr}');
      }
      final runtime = EngineRuntime(destination.path);
      if (!runtime.exists) throw Exception('更新包缺少运行时文件');
      if (runtime.version != version) {
        throw Exception('运行时版本不匹配：${runtime.version}');
      }
      await EngineRuntime.selectRuntime(version);
      currentVersion = version;
      state = RuntimeUpdateState(
        phase: RuntimeUpdatePhase.installed,
        version: version,
        availableVersion: version,
      );
      onRuntimeInstalled(runtime);
    } catch (error) {
      state = RuntimeUpdateState(
        phase: RuntimeUpdatePhase.failed,
        version: currentVersion,
        availableVersion: version,
        message: '安装更新失败：$error',
      );
    } finally {
      if (archive.existsSync()) {
        try {
          await archive.delete();
        } catch (_) {}
      }
      onStateChanged();
    }
  }

  Future<void> restoreBundled() async {
    final resources = EngineRuntime.bundledResourcesDirectory;
    if (resources == null) return;
    final bundled = EngineRuntime(p.join(resources.path, 'runtime'));
    if (!bundled.exists) {
      state = RuntimeUpdateState(
        phase: RuntimeUpdatePhase.failed,
        version: currentVersion,
        message: '内置运行时不可用，无法恢复',
      );
      onStateChanged();
      return;
    }
    await EngineRuntime.selectRuntime(null);
    currentVersion = bundled.version;
    state = RuntimeUpdateState(
      phase: RuntimeUpdatePhase.installed,
      version: bundled.version,
    );
    onRuntimeInstalled(bundled);
    onStateChanged();
  }

  Future<String> _sha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  static bool _isNewer(String candidate, String current) {
    List<int>? parse(String value) {
      final clean = value.replaceFirst(RegExp(r'^v'), '').split('-').first;
      final parts = clean.split('.').map(int.tryParse).toList();
      if (parts.isEmpty || parts.any((item) => item == null)) return null;
      return parts.cast<int>();
    }

    final left = parse(candidate);
    final right = parse(current);
    if (left == null || right == null) return candidate != current;
    final length = left.length > right.length ? left.length : right.length;
    for (var index = 0; index < length; index++) {
      final a = index < left.length ? left[index] : 0;
      final b = index < right.length ? right[index] : 0;
      if (a != b) return a > b;
    }
    return false;
  }
}
