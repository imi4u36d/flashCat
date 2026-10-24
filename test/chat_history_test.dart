import 'dart:io';

import 'package:flash_cat/core/chat/chat_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recent conversations round-trip through disk', () async {
    final dir = await Directory.systemTemp.createTemp('flashcat-history-');
    final file = File('${dir.path}/chat-history.json');
    final history = ChatHistory.instance;

    await history.ensureLoaded(file);
    expect(history.threads, isEmpty);

    await history.archive(
      title: '并发下载器实现',
      messages: [
        {'role': 'user', 'text': '用 Flutter 写一个并发下载器'},
      ],
    );
    expect(history.threads, hasLength(1));
    expect(history.threads.first.title, '并发下载器实现');
    expect(file.existsSync(), isTrue);

    await history.archive(
      title: '首字延迟排查',
      messages: [
        {'role': 'user', 'text': '首字延迟为什么偏高'},
      ],
    );
    expect(history.threads.first.title, '首字延迟排查');

    await history.forget(history.threads.first.id);
    expect(history.threads, hasLength(1));
    expect(history.threads.first.title, '并发下载器实现');
  });
}
