import 'dart:convert';

import 'package:http/http.dart' as http;

class ServerStats {
  const ServerStats({
    this.decodeTokensPerSecond,
    this.prefillTokensPerSecond,
    this.draftAcceptance,
    this.ttftMilliseconds,
    this.activeRequests = 0,
    this.queuedRequests = 0,
    this.thermal,
    this.memoryPressure,
    this.memoryBytes,
    this.peakMemoryBytes,
    this.maximumContextTokens,
    this.model,
    this.requestsCompleted = 0,
    this.requestsFailed = 0,
    this.deviceName,
    this.physicalMemoryBytes,
    this.gpuCores,
    this.startedAt,
    this.vision,
    this.kvFormat,
    this.weightsReleased,
    this.instancePid,
    this.instanceId,
    this.buildId,
  });

  factory ServerStats.fromJson(Map<String, dynamic> json) {
    final metrics = _map(json['metrics']);
    final admission = _map(json['admission']);
    final instance = _map(json['instance']);
    final memory = _map(json['memory_actual']);
    final requests = _map(json['requests']);
    final plan = _map(json['memory_plan']);
    final device = _map(plan['device']);
    final kv = _map(json['kv']);
    final weights = _map(json['weights']);
    final active = json['active_requests'];
    return ServerStats(
      decodeTokensPerSecond: _double(metrics['decode_tokens_per_second']),
      prefillTokensPerSecond: _double(metrics['prefill_tokens_per_second']),
      draftAcceptance: _double(metrics['draft_acceptance_rate']),
      ttftMilliseconds: _double(_map(metrics['ttft_ms'])['p50']),
      activeRequests:
          active is List ? active.length : (_int(admission['restoring']) ?? 0),
      queuedRequests: _int(admission['waiting']) ?? 0,
      thermal: json['thermal_state'] as String?,
      memoryPressure: json['memory_pressure'] as String?,
      memoryBytes: _int(memory['current_bytes']),
      peakMemoryBytes: _int(memory['peak_bytes']),
      maximumContextTokens: _int(json['maximum_context_tokens']),
      model: instance['model'] as String?,
      requestsCompleted: _int(requests['completed']) ?? 0,
      requestsFailed: _int(requests['failed']) ?? 0,
      deviceName: device['device_name'] as String?,
      physicalMemoryBytes: _int(device['physical_memory_bytes']),
      gpuCores: _int(device['gpu_core_count']),
      startedAt: _double(instance['started_at']),
      vision: json['vision'] as bool?,
      kvFormat: kv['format'] as String?,
      weightsReleased: weights['released'] as bool?,
      instancePid: _int(instance['pid']),
      instanceId: instance['id'] as String?,
      buildId: _map(_map(json['identity'])['cache'])['build_id'] as String?,
    );
  }

  final double? decodeTokensPerSecond;
  final double? prefillTokensPerSecond;
  final double? draftAcceptance;
  final double? ttftMilliseconds;
  final int activeRequests;
  final int queuedRequests;
  final String? thermal;
  final String? memoryPressure;
  final int? memoryBytes;
  final int? peakMemoryBytes;
  final int? maximumContextTokens;
  final String? model;
  final int requestsCompleted;
  final int requestsFailed;
  final String? deviceName;
  final int? physicalMemoryBytes;
  final int? gpuCores;
  final double? startedAt;
  final bool? vision;
  final String? kvFormat;
  final bool? weightsReleased;
  final int? instancePid;
  final String? instanceId;
  final String? buildId;

  String get thermalText => switch (thermal) {
        'nominal' => '正常',
        'fair' => '偏热',
        'serious' => '过热',
        'critical' => '临界',
        _ => thermal ?? '—',
      };

  String get memoryPressureText => switch (memoryPressure) {
        'normal' => '正常',
        'warning' => '偏高',
        'critical' => '紧张',
        _ => memoryPressure ?? '—',
      };

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : const {};

  static double? _double(Object? value) =>
      value is num ? value.toDouble() : null;

  static int? _int(Object? value) => value is num ? value.toInt() : null;
}

class LocalApi {
  LocalApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Uri baseUri(int port) => Uri.parse('http://127.0.0.1:$port');

  Future<bool> ready(int port) async {
    try {
      final response = await _client
          .get(baseUri(port).resolve('/ready'))
          .timeout(const Duration(milliseconds: 1500));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<ServerStats?> status(int port) async {
    try {
      final response = await _client
          .get(baseUri(port).resolve('/status'))
          .timeout(const Duration(milliseconds: 1800));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded is Map
          ? ServerStats.fromJson(Map<String, dynamic>.from(decoded))
          : null;
    } catch (_) {
      return null;
    }
  }

  void close() => _client.close();
}
