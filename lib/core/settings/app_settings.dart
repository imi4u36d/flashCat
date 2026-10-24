import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

enum ThinkingMode {
  automatic('自动', '跟随模型的聊天模板'),
  off('关闭', '直接回答，不做隐藏推理'),
  on('开启', '使用指定的推理等级');

  const ThinkingMode(this.label, this.detail);

  final String label;
  final String detail;
}

enum ReasoningEffort {
  minimal('最少'),
  low('低'),
  medium('中'),
  high('高'),
  xhigh('极高'),
  max('最大');

  const ReasoningEffort(this.label);

  final String label;
}

class AppSettings {
  AppSettings._(this._prefs);

  final SharedPreferences _prefs;

  static Future<AppSettings> load() async {
    return AppSettings._(await SharedPreferences.getInstance());
  }

  int get port => _prefs.getInt('port') ?? 8000;
  set port(int value) => _prefs.setInt('port', value);

  String get model => _prefs.getString('model') ?? '';
  set model(String value) => _prefs.setString('model', value);

  String get maxMemory => _prefs.getString('maxMemory') ?? '';
  set maxMemory(String value) => _prefs.setString('maxMemory', value);

  String get maxContext => _prefs.getString('maxContext') ?? '';
  set maxContext(String value) => _prefs.setString('maxContext', value);

  bool get idleReleaseOff => _prefs.getBool('idleReleaseOff') ?? false;
  set idleReleaseOff(bool value) =>
      _prefs.setBool('idleReleaseOff', value);

  bool get languageOnly => _prefs.getBool('languageOnly') ?? false;
  set languageOnly(bool value) => _prefs.setBool('languageOnly', value);

  ThinkingMode get thinkingMode => ThinkingMode.values[_prefs.getInt(
        'thinkingMode',
      ) ??
      0];
  set thinkingMode(ThinkingMode value) =>
      _prefs.setInt('thinkingMode', value.index);

  ReasoningEffort get reasoningEffort => ReasoningEffort.values[_prefs.getInt(
        'reasoningEffort',
      ) ??
      2];
  set reasoningEffort(ReasoningEffort value) =>
      _prefs.setInt('reasoningEffort', value.index);

  String? get effectiveReasoningEffort => switch (thinkingMode) {
        ThinkingMode.automatic => null,
        ThinkingMode.off => 'none',
        ThinkingMode.on => reasoningEffort.name,
      };

  String get extraArgs => _prefs.getString('extraArgs') ?? '';
  set extraArgs(String value) => _prefs.setString('extraArgs', value);

  bool get autoStart => _prefs.getBool('autoStart') ?? false;
  set autoStart(bool value) => _prefs.setBool('autoStart', value);

  bool get launchAtLogin => _prefs.getBool('launchAtLogin') ?? false;
  set launchAtLogin(bool value) => _prefs.setBool('launchAtLogin', value);

  String get hfCache => _prefs.getString('hfCache') ?? '';
  set hfCache(String value) => _prefs.setString('hfCache', value);

  List<String> get recentModels => _prefs.getStringList('recentModels') ?? [];

  double get temperature => _prefs.getDouble('chat.temperature') ?? 0.7;
  set temperature(double value) =>
      _prefs.setDouble('chat.temperature', value);

  double get topP => _prefs.getDouble('chat.topP') ?? 0.95;
  set topP(double value) => _prefs.setDouble('chat.topP', value);

  String get systemPrompt => _prefs.getString('chat.system') ?? '';
  set systemPrompt(String value) => _prefs.setString('chat.system', value);

  void rememberModel(String id) {
    final values = recentModels.where((item) => item != id).toList();
    values.insert(0, id);
    _prefs.setStringList('recentModels', values.take(8).toList());
  }

  List<String> serveArguments() {
    final result = <String>[];
    final memory = maxMemory.trim();
    if (memory.isNotEmpty) result.addAll(['--max-memory', memory]);
    final context = maxContext.trim();
    if (context.isNotEmpty) result.addAll(['--max-context', context]);
    if (idleReleaseOff) result.addAll(['--idle-release', 'off']);
    if (languageOnly) result.add('--language-only');
    final effort = effectiveReasoningEffort;
    if (effort != null) {
      result.addAll(['--default-reasoning-effort', effort]);
    }
    result.addAll(splitArguments(extraArgs));
    return result;
  }

  Future<String> conversationPath() async {
    return '${await _supportDirectory()}${Platform.pathSeparator}conversation.json';
  }

  /// Archived conversations shown under “最近” in the sidebar.
  Future<String> historyPath() async {
    return '${await _supportDirectory()}${Platform.pathSeparator}chat-history.json';
  }

  Future<String> _supportDirectory() async {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    final path = switch (Platform.operatingSystem) {
      'macos' => '$home/Library/Application Support/flashCat',
      'windows' => '${Platform.environment['APPDATA']}\\flashCat',
      _ => '${Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config'}/flashCat',
    };
    final directory = Directory(path);
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
    return directory.path;
  }

  static List<String> splitArguments(String text) {
    final result = <String>[];
    final current = StringBuffer();
    String? quote;
    for (final rune in text.runes) {
      final character = String.fromCharCode(rune);
      if (quote != null) {
        if (character == quote) {
          quote = null;
        } else {
          current.write(character);
        }
      } else if (character == '"' || character == "'") {
        quote = character;
      } else if (RegExp(r'\s').hasMatch(character)) {
        if (current.isNotEmpty) {
          result.add(current.toString());
          current.clear();
        }
      } else {
        current.write(character);
      }
    }
    if (current.isNotEmpty) result.add(current.toString());
    return result;
  }

  String get chatOptionsJson => jsonEncode({
        'temperature': temperature,
        'topP': topP,
        'systemPrompt': systemPrompt,
      });
}
