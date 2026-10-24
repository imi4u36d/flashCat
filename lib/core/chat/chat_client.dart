import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class ChatTurn {
  const ChatTurn({required this.role, required this.content});

  final String role;
  final String content;

  Map<String, String> toJson() => {'role': role, 'content': content};
}

class ChatUsage {
  const ChatUsage({this.promptTokens, this.completionTokens});

  final int? promptTokens;
  final int? completionTokens;
}

class ChatOptions {
  ChatOptions({
    this.temperature = 0.7,
    this.topP = 0.95,
    this.maxTokens,
    this.systemPrompt = '',
    this.reasoningEffort,
  });

  double temperature;
  double topP;
  int? maxTokens;
  String systemPrompt;
  String? reasoningEffort;
}

class ChatClient {
  http.Client? _client;
  StreamSubscription<List<int>>? _subscription;

  bool get isStreaming => _client != null;

  Future<void> send({
    required int port,
    required String model,
    required List<ChatTurn> turns,
    required ChatOptions options,
    required void Function(String delta) onDelta,
    required void Function(ChatUsage usage, Duration elapsed) onFinish,
    required void Function(String message) onFailure,
  }) async {
    await cancel();
    final started = DateTime.now();
    final client = http.Client();
    _client = client;
    final body = <String, Object?>{
      'model': model,
      'stream': true,
      'temperature': options.temperature,
      'top_p': options.topP,
      if (options.maxTokens != null) 'max_tokens': options.maxTokens,
      if (options.reasoningEffort != null)
        'reasoning_effort': options.reasoningEffort,
      'messages': [
        if (options.systemPrompt.trim().isNotEmpty)
          {'role': 'system', 'content': options.systemPrompt},
        ...turns.map((turn) => turn.toJson()),
      ],
    };
    final request = http.Request(
      'POST',
      Uri.parse('http://127.0.0.1:$port/v1/chat/completions'),
    )
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode(body);

    try {
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final text = await response.stream.bytesToString();
        throw Exception('HTTP ${response.statusCode}: ${text.trim()}');
      }
      final isJson =
          response.headers['content-type']?.contains('json') == true;
      if (isJson) {
        final text = await response.stream.bytesToString();
        final handled = _handleJson(
          text,
          onDelta: onDelta,
          elapsed: DateTime.now().difference(started),
          onFinish: onFinish,
        );
        if (!handled) throw Exception('引擎返回了无法识别的响应');
        return;
      }

      final completer = Completer<void>();
      var buffer = '';
      ChatUsage usage = const ChatUsage();
      var done = false;

      void finish() {
        if (done) return;
        done = true;
        if (!completer.isCompleted) completer.complete();
      }

      _subscription = response.stream.listen(
        (bytes) {
          buffer += utf8.decode(bytes, allowMalformed: true);
          while (true) {
            final newline = buffer.indexOf('\n');
            if (newline < 0) break;
            final line = buffer.substring(0, newline).trim();
            buffer = buffer.substring(newline + 1);
            if (line.isEmpty) continue;
            final payload =
                line.startsWith('data:') ? line.substring(5).trim() : line;
            if (payload == '[DONE]') {
              finish();
              break;
            }
            if (!payload.startsWith('{')) continue;
            try {
              final json = jsonDecode(payload);
              if (json is! Map) continue;
              final error = json['error'];
              if (error is Map) {
                if (!completer.isCompleted) {
                  completer.completeError(
                    Exception(error['message'] ?? '引擎返回了错误'),
                  );
                }
                done = true;
                break;
              }
              final usageJson = json['usage'];
              if (usageJson is Map) {
                usage = ChatUsage(
                  promptTokens: _int(usageJson['prompt_tokens']),
                  completionTokens: _int(usageJson['completion_tokens']),
                );
              }
              final choices = json['choices'];
              if (choices is! List || choices.isEmpty) continue;
              final first = choices.first;
              if (first is! Map) continue;
              final delta = first['delta'];
              final message = first['message'];
              final text = delta is Map
                  ? (delta['content'] ?? delta['reasoning_content']) as String?
                  : message is Map
                      ? message['content'] as String?
                      : first['text'] as String?;
              if (text != null && text.isNotEmpty) onDelta(text);
            } on FormatException {
              // Ignore a non-JSON event line.
            }
          }
        },
        onError: (Object error) {
          if (!completer.isCompleted) completer.completeError(error);
        },
        onDone: finish,
        cancelOnError: true,
      );
      await completer.future;
      await cancel(notify: false);
      onFinish(usage, DateTime.now().difference(started));
    } catch (error) {
      await cancel(notify: false);
      onFailure(error.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> cancel({bool notify = true}) async {
    await _subscription?.cancel();
    _subscription = null;
    _client?.close();
    _client = null;
  }

  bool _handleJson(
    String body, {
    required void Function(String delta) onDelta,
    required Duration elapsed,
    required void Function(ChatUsage usage, Duration elapsed) onFinish,
  }) {
    try {
      final json = jsonDecode(body);
      if (json is! Map) return false;
      final choices = json['choices'];
      if (choices is! List || choices.isEmpty) return false;
      final first = choices.first;
      final message = first is Map ? first['message'] : null;
      final content = message is Map ? message['content'] as String? : null;
      if (content != null) onDelta(content);
      final usageJson = json['usage'];
      final usage = usageJson is Map
          ? ChatUsage(
              promptTokens: _int(usageJson['prompt_tokens']),
              completionTokens: _int(usageJson['completion_tokens']),
            )
          : const ChatUsage();
      onFinish(usage, elapsed);
      return true;
    } catch (_) {
      return false;
    }
  }

  static int? _int(Object? value) => value is num ? value.toInt() : null;
}
