import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class EngineRuntime {
  const EngineRuntime(this.root);

  final String root;

  static String get home =>
      Platform.environment['HOME'] ?? Directory.current.path;

  static Directory get supportDirectory {
    final root = switch (Platform.operatingSystem) {
      'macos' => p.join(home, 'Library', 'Application Support', 'flashCat'),
      'windows' => p.join(
          Platform.environment['APPDATA'] ?? home,
          'flashCat',
        ),
      _ => p.join(
          Platform.environment['XDG_CONFIG_HOME'] ?? p.join(home, '.config'),
          'flashCat',
        ),
    };
    return Directory(root);
  }

  static Directory get runtimesDirectory =>
      Directory(p.join(supportDirectory.path, 'runtimes'));

  static File get activeRuntimeFile =>
      File(p.join(supportDirectory.path, 'active-runtime'));

  String get pythonPath => p.join(
        root,
        'python',
        'bin',
        Platform.isWindows ? 'python.exe' : 'python3',
      );

  String get launcherPath => p.join(root, 'install', 'launcher.py');
  String get enginePath =>
      p.join(root, 'engine', Platform.isWindows ? 'splash.exe' : 'splash');
  String get serveScriptPath => p.join(root, 'flashcat_serve.py');

  File get releaseFile => File(p.join(root, 'release.json'));

  bool get exists {
    return releaseFile.existsSync() &&
        File(pythonPath).existsSync() &&
        File(launcherPath).existsSync() &&
        File(enginePath).existsSync();
  }

  String get version {
    try {
      final data = jsonDecode(releaseFile.readAsStringSync());
      return data is Map ? (data['version'] as String? ?? 'unknown') : 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  List<String> get suggestedModels {
    final file = File(
      p.join(root, 'install', 'completions', 'suggested-models.txt'),
    );
    if (!file.existsSync()) return const [];
    try {
      return file
          .readAsLinesSync()
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Map<String, String> get draftRepositories {
    final file = File(p.join(root, 'install', 'families.py'));
    if (!file.existsSync()) return Map.of(knownDrafts);
    try {
      final text = file.readAsStringSync();
      final expression = RegExp(
        r'ModelFamily\(\s*"([^"]+)"\s*,\s*(?:"([^"]+)"|None)',
      );
      final result = <String, String>{};
      for (final match in expression.allMatches(text)) {
        result[match.group(1)!] = match.group(2) ?? '';
      }
      return result.isEmpty ? Map.of(knownDrafts) : result;
    } catch (_) {
      return Map.of(knownDrafts);
    }
  }

  static const knownDrafts = {
    'Qwen3.8-27B': 'incoai/Qwen3.8-27B-DFlash2',
    'Qwen3.6-35B-A3B': 'incoai/Qwen3.6-35B-A3B-DFlash2',
    'Qwen3.8-Flash-Next': 'incoai/Qwen3.8-Flash-Next-DFlash2',
  };

  static EngineRuntime? locate() {
    final candidates = <String>{};
    final override = Platform.environment['FLASHCAT_RUNTIME'];
    if (override != null && override.isNotEmpty) candidates.add(override);

    final active = _managedVersion();
    if (active != null) {
      candidates.add(p.join(runtimesDirectory.path, active));
    }

    final resources = bundledResourcesDirectory;
    if (resources != null) {
      candidates.add(p.join(resources.path, 'runtime'));
    }

    candidates.add(p.join(Directory.current.path, '.runtime'));
    for (final candidate in candidates) {
      final runtime = EngineRuntime(candidate);
      if (runtime.exists) return runtime;
    }
    return null;
  }

  static Directory? get bundledResourcesDirectory {
    if (!Platform.isMacOS) return null;
    final executable = File(Platform.resolvedExecutable);
    final contents = executable.parent.parent;
    final resources = Directory(p.join(contents.path, 'Resources'));
    return resources.existsSync() ? resources : null;
  }

  static String? _managedVersion() {
    if (!activeRuntimeFile.existsSync()) return null;
    try {
      final value = activeRuntimeFile.readAsStringSync().trim();
      if (value.isEmpty || !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value)) {
        return null;
      }
      return value;
    } catch (_) {
      return null;
    }
  }

  static bool get usingManagedRuntime => _managedVersion() != null;

  static Future<void> selectRuntime(String? version) async {
    await supportDirectory.create(recursive: true);
    if (version == null) {
      if (activeRuntimeFile.existsSync()) await activeRuntimeFile.delete();
      return;
    }
    await activeRuntimeFile.writeAsString(version, flush: true);
  }
}
