import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A conversation archived from the chat page and surfaced under “最近”.
@immutable
class ChatThread {
  const ChatThread({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.messages,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final List<Map<String, dynamic>> messages;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updatedAt': updatedAt.toIso8601String(),
        'messages': messages,
      };

  static ChatThread? fromJson(Map<String, dynamic> json) {
    final raw = json['messages'];
    if (raw is! List) return null;
    final messages = raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    if (messages.isEmpty) return null;
    return ChatThread(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '对话',
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
              DateTime.now(),
      messages: messages,
    );
  }
}

/// Tiny local store for the sidebar's recent conversations.
///
/// The active conversation still lives in `conversation.json`; this only keeps
/// the few most recent snapshots so “最近” can reopen them.
class ChatHistory extends ChangeNotifier {
  ChatHistory._();

  static final ChatHistory instance = ChatHistory._();
  static const _maxThreads = 6;

  final List<ChatThread> _threads = [];

  /// The sidebar writes here; the chat page consumes and clears it.
  final ValueNotifier<ChatThread?> openRequest = ValueNotifier(null);

  File? _file;
  bool _loaded = false;

  List<ChatThread> get threads => List.unmodifiable(_threads);

  Future<void> ensureLoaded(File file) async {
    if (_loaded) return;
    _loaded = true;
    _file = file;
    try {
      if (!file.existsSync()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return;
      _threads
        ..clear()
        ..addAll(
          decoded
              .whereType<Map>()
              .map((item) => ChatThread.fromJson(Map<String, dynamic>.from(item)))
              .whereType<ChatThread>(),
        );
      _threads.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      notifyListeners();
    } catch (_) {
      // A damaged history file must not block chatting.
    }
  }

  Future<void> archive({
    required String title,
    required List<Map<String, dynamic>> messages,
  }) async {
    if (messages.isEmpty) return;
    final now = DateTime.now();
    final cleanTitle = title.trim();
    _threads.insert(
      0,
      ChatThread(
        id: '${now.microsecondsSinceEpoch}',
        title: cleanTitle.isEmpty ? '未命名对话' : cleanTitle,
        updatedAt: now,
        messages: messages,
      ),
    );
    if (_threads.length > _maxThreads) {
      _threads.removeRange(_maxThreads, _threads.length);
    }
    await _write();
    notifyListeners();
  }

  Future<void> forget(String id) async {
    final before = _threads.length;
    _threads.removeWhere((thread) => thread.id == id);
    if (_threads.length == before) return;
    await _write();
    notifyListeners();
  }

  Future<void> _write() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.writeAsString(
        jsonEncode(_threads.map((thread) => thread.toJson()).toList()),
        flush: true,
      );
    } catch (_) {}
  }
}
