import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../runtime/engine_runtime.dart';

enum ModelOrigin { local, splash, recommended }

class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.path,
    required this.bytes,
    required this.origin,
    this.targetName = '',
    this.family,
    this.draftPath,
    this.mmprojPath,
  });

  final String id;
  final String path;
  final int bytes;
  final ModelOrigin origin;
  final String targetName;
  final String? family;
  final String? draftPath;
  final String? mmprojPath;

  String get shortName => id.split('/').last;

  String get sizeText {
    final gb = bytes / 1000000000;
    if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
    return '${(bytes / 1000000).round()} MB';
  }
}

class ModelCatalog {
  const ModelCatalog({
    required this.local,
    required this.installed,
    required this.recommended,
    required this.draftRepositories,
  });

  final List<ModelInfo> local;
  final List<ModelInfo> installed;
  final List<String> recommended;
  final Map<String, String> draftRepositories;

  List<ModelInfo> get machine {
    final seen = <String>{};
    return [...local, ...installed].where((item) => seen.add(item.id)).toList()
      ..sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
  }

  List<String> get missingRecommendations =>
      recommended.where((id) => !machine.any((item) => item.id == id)).toList();

  ModelInfo? localModel(String id) {
    for (final model in local) {
      if (model.id == id) return model;
    }
    return null;
  }

  ModelInfo? machineModel(String id) {
    for (final model in machine) {
      if (model.id == id) return model;
    }
    return null;
  }

  String? draftRepository(String modelId, String? family) {
    final candidates = [
      ?family,
      ...draftRepositories.keys,
    ];
    final folded = _fold(modelId);
    candidates.sort((a, b) => _fold(b).length.compareTo(_fold(a).length));
    for (final candidate in candidates) {
      final needle = _fold(candidate);
      if (needle.isNotEmpty && folded.contains(needle)) {
        final repo = draftRepositories[candidate];
        return repo == null || repo.isEmpty ? null : repo;
      }
    }
    return null;
  }

  static String _fold(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]'), '');
}

class ModelCatalogService {
  static Directory get localDirectory {
    final override = Platform.environment['FLASHCAT_MODELS_DIR'];
    if (override != null && override.isNotEmpty) return Directory(override);
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return Directory(p.join(home, '.flashcat', 'models'));
  }

  static Directory get legacyDirectory {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return Directory(
      p.join(home, 'Library', 'Application Support', 'flashCat', 'models'),
    );
  }

  static Directory get splashDirectory {
    final override = Platform.environment['FLASHCAT_DATA_DIR'];
    if (override != null && override.isNotEmpty) {
      return Directory(p.join(override, 'models'));
    }
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return Directory(
      p.join(home, 'Library', 'Application Support', 'Splash', 'models'),
    );
  }

  Future<ModelCatalog> load(EngineRuntime? runtime) async {
    final localRoot = localDirectory.path;
    final splashRoot = splashDirectory.path;
    final result = await Isolate.run(
      () => _scanCatalog(localRoot, splashRoot),
    );
    final drafts = runtime?.draftRepositories ?? const <String, String>{};
    return ModelCatalog(
      local: result.$1,
      installed: result.$2,
      recommended: runtime?.suggestedModels ?? const [],
      draftRepositories: drafts,
    );
  }

  static (List<ModelInfo>, List<ModelInfo>) _scanCatalog(
    String localRoot,
    String splashRoot,
  ) {
    final local = _scanLocal(Directory(localRoot));
    final installed = _scanSplash(Directory(splashRoot));
    return (local, installed);
  }

  static List<ModelInfo> _scanLocal(Directory root) {
    final result = <ModelInfo>[];
    if (!root.existsSync()) return result;
    for (final owner in _directories(root)) {
      for (final repo in _directories(owner)) {
        final parsed = _parseRepository(repo);
        if (parsed != null) result.add(parsed);
      }
    }
    return result;
  }

  static List<ModelInfo> _scanSplash(Directory root) {
    final result = <ModelInfo>[];
    if (!root.existsSync()) return result;
    final seen = <String>{};

    final resolved = Directory(p.join(root.path, '.resolved'));
    if (resolved.existsSync()) {
      for (final assembly in _directories(resolved)) {
        final parsed = _parseAssembly(assembly);
        if (parsed != null && seen.add(parsed.id)) result.add(parsed);
      }
    }

    for (final owner in _directories(root)) {
      for (final repo in _directories(owner)) {
        final parsed = _parseAssembly(
          repo,
          fallbackId: '${p.basename(owner.path)}/${p.basename(repo.path)}',
        );
        if (parsed != null && seen.add(parsed.id)) result.add(parsed);
      }
    }
    return result;
  }

  static ModelInfo? _parseRepository(Directory repository) {
    final entries = _entries(repository);
    final config = entries.where((item) => p.basename(item.path) == 'config.json');
    final ggufs = entries
        .whereType<File>()
        .where((item) =>
            p.extension(item.path).toLowerCase() == '.gguf' &&
            !p.basename(item.path).toLowerCase().contains('mmproj'))
        .toList();
    final mmproj = entries
        .whereType<File>()
        .where((item) =>
            p.extension(item.path).toLowerCase() == '.gguf' &&
            p.basename(item.path).toLowerCase().contains('mmproj'))
        .firstOrNull;
    if (ggufs.isEmpty && config.isEmpty) return null;
    ggufs.sort(_compareSplitParts);
    File? target = ggufs.firstOrNull;
    Directory? draft;
    for (final directory in _directories(repository)) {
      final name = p.basename(directory.path).toLowerCase();
      if ((name == 'draft' || name == 'dflash2') &&
          File(p.join(directory.path, 'config.json')).existsSync()) {
        draft = directory;
        break;
      }
    }
    var bytes = 0;
    try {
      for (final file in repository.listSync(recursive: true)) {
        if (file is File) bytes += file.lengthSync();
      }
    } on FileSystemException {
      // A partial or disappearing model should not break the whole catalog.
    }
    return ModelInfo(
      id: '${p.basename(repository.parent.path)}/${p.basename(repository.path)}',
      path: repository.path,
      bytes: bytes,
      origin: ModelOrigin.local,
      targetName: target?.path ?? repository.path,
      draftPath: draft?.path,
      mmprojPath: mmproj?.path,
    );
  }

  static ModelInfo? _parseAssembly(
    Directory assembly, {
    String? fallbackId,
  }) {
    final modelJson = File(p.join(assembly.path, 'model.json'));
    String? id;
    String? family;
    var bytes = 0;
    if (modelJson.existsSync()) {
      try {
        final json = jsonDecode(modelJson.readAsStringSync()) as Map;
        id = json['model'] as String?;
        family = json['family'] as String?;
        final files = json['files'];
        if (files is Map) {
          for (final value in files.values) {
            if (value is Map && value['bytes'] is num) {
              bytes += (value['bytes'] as num).toInt();
            }
          }
        }
      } catch (_) {
        // Keep a partially-written record out of the model list.
      }
    }
    id ??= fallbackId;
    if (id == null || !id.contains('/')) return null;
    final targetDirectory = Directory(p.join(assembly.path, 'target'));
    if (!targetDirectory.existsSync() &&
        !Directory(assembly.path).existsSync()) {
      return null;
    }
    final draft = Directory(p.join(assembly.path, 'draft'));
    return ModelInfo(
      id: id,
      path: assembly.path,
      bytes: bytes,
      origin: ModelOrigin.splash,
      targetName: p.basename(targetDirectory.path),
      family: family,
      draftPath: draft.existsSync() ? draft.path : null,
    );
  }

  static int _compareSplitParts(File a, File b) {
    int? part(File file) {
      final match =
          RegExp(r'-(\d{5})-of-\d{5}\.gguf$').firstMatch(file.path);
      return match == null ? null : int.tryParse(match.group(1)!);
    }

    final left = part(a);
    final right = part(b);
    if (left != null && right != null) return left.compareTo(right);
    if (left != null) return -1;
    if (right != null) return 1;
    return a.path.compareTo(b.path);
  }

  static List<Directory> _directories(Directory root) {
    if (!root.existsSync()) return const [];
    try {
      return root
          .listSync(followLinks: true)
          .whereType<Directory>()
          .where((item) => !p.basename(item.path).startsWith('.'))
          .toList();
    } on FileSystemException {
      return const [];
    }
  }

  static List<FileSystemEntity> _entries(Directory root) {
    try {
      return root.listSync(followLinks: true);
    } on FileSystemException {
      return const [];
    }
  }

  Future<void> migrateLegacyDirectory() async {
    final legacy = legacyDirectory;
    final target = localDirectory;
    if (!legacy.existsSync() ||
        legacy.absolute.path == target.absolute.path) {
      return;
    }
    await target.create(recursive: true);
    for (final owner in _directories(legacy)) {
      for (final repo in _directories(owner)) {
        final destination =
            Directory(p.join(target.path, p.basename(owner.path), p.basename(repo.path)));
        if (destination.existsSync()) continue;
        await destination.parent.create(recursive: true);
        try {
          await repo.rename(destination.path);
        } on FileSystemException {
          await _copyDirectory(repo, destination);
          await repo.delete(recursive: true);
        }
      }
    }
  }

  Future<ModelImportResult> importDirectory(
    Directory source, {
    bool move = false,
    void Function(double fraction, String message)? onProgress,
  }) async {
    if (!source.existsSync()) {
      throw const ModelImportException('选择的目录不存在');
    }
    final files = source.listSync(recursive: true).whereType<File>().toList();
    final hasWeights = files.any((file) =>
        p.extension(file.path).toLowerCase() == '.gguf' &&
        !p.basename(file.path).toLowerCase().contains('mmproj'));
    if (!hasWeights) {
      throw const ModelImportException('目录里没有找到 .gguf 权重文件');
    }
    final owner = _sanitize(p.basename(source.parent.path));
    final repo = _sanitize(p.basename(source.path));
    final destination =
        Directory(p.join(localDirectory.path, owner, repo));
    if (destination.existsSync()) {
      throw ModelImportException('$owner/$repo 已经存在');
    }
    await destination.parent.create(recursive: true);
    final total = files.fold<int>(0, (sum, file) => sum + file.lengthSync());
    var completed = 0;

    if (move) {
      try {
        await source.rename(destination.path);
        onProgress?.call(1, '已移动 $owner/$repo');
        return ModelImportResult('$owner/$repo', destination);
      } on FileSystemException {
        // Cross-volume moves fall through to copy-then-delete.
      }
    }

    for (final file in files) {
      final relative = p.relative(file.path, from: source.path);
      final target = File(p.join(destination.path, relative));
      await target.parent.create(recursive: true);
      await file.openRead().pipe(target.openWrite());
      completed += await file.length();
      onProgress?.call(
        total == 0 ? 1 : completed / total,
        '正在复制 ${p.basename(file.path)}',
      );
    }
    if (move) {
      await source.delete(recursive: true);
    }
    return ModelImportResult('$owner/$repo', destination);
  }

  Future<void> deleteLocal(ModelInfo model) async {
    if (model.origin != ModelOrigin.local) {
      throw const ModelImportException('只能删除 flashCat 本地模型目录中的模型');
    }
    final directory = Directory(model.path);
    if (directory.existsSync()) await directory.delete(recursive: true);
    final parent = directory.parent;
    if (parent.existsSync() && parent.listSync().isEmpty) {
      await parent.delete();
    }
  }

  static Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final item in source.list(recursive: true, followLinks: true)) {
      if (item is! File) continue;
      final relative = p.relative(item.path, from: source.path);
      final output = File(p.join(target.path, relative));
      await output.parent.create(recursive: true);
      await item.copy(output.path);
    }
  }

  static String _sanitize(String value) {
    final result = value.replaceAll(RegExp(r'[^\w.\-]'), '-');
    return result.isEmpty ? 'model' : result;
  }
}

class ModelImportResult {
  const ModelImportResult(this.id, this.destination);

  final String id;
  final Directory destination;
}

class ModelImportException implements Exception {
  const ModelImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

extension FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
