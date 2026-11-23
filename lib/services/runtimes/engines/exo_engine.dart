import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/Get.dart';

import 'package:llama_flutter_android/llama_flutter_android.dart'
    if (dart.library.html) 'exo_web_stub.dart';

import '../../services/cluster_service.dart';
import '../../services/inference_service.dart';
import '../runtime_engine.dart';

class ExoEngine extends RuntimeEngine {
  static const List<String> _platforms = ['android', 'ios', 'linux', 'windows'];
  static const double _bytesPerToken = 4.5;

  @override
  String get id => 'exo';

  @override
  String get name => 'Exo';

  @override
  List<String> get platforms => _platforms;

  @override
  RuntimeType get type => RuntimeType.text;

  @override
  String get version => 'Cluster';

  ClusterService get _cluster => Get.find<ClusterService>();
  InferenceService get _inference => Get.find<InferenceService>();

  @override
  Future<RuntimeAvailability> checkAvailability() async {
    if (kIsWeb || !ClusterService.isSupported) {
      return RuntimeAvailability.unavailable(
          'Cluster wird auf dieser Plattform nicht unterstützt.');
    }
    final cluster = _cluster;
    if (cluster.workers.isEmpty) {
      return RuntimeAvailability.unavailable(
          'Keine Cluster-Worker registriert (Role: ${cluster.role.name}).');
    }
    return const RuntimeAvailability.available();
  }

  Future<RuntimeAvailability> _safeCheckAvailability() async {
    try {
      return await checkAvailability();
    } catch (e) {
      return RuntimeAvailability.unavailable('Check fehlgeschlagen: $e');
    }
  }

  @override
  Future<BenchmarkResult> benchmark(
      {required String prompt, int maxTokens = 64}) async {
    final availability = await _safeCheckAvailability();
    if (!availability.available) {
      return BenchmarkResult(
          success: false, error: availability.reason ?? 'nicht verfügbar');
    }
    final workers = _cluster.workers.toList();
    if (workers.isEmpty) {
      return BenchmarkResult(
          success: false, error: 'Keine Cluster-Worker registriert.');
    }
    if (_inference.isModelLoaded.value) {
      final stopwatch = Stopwatch()..start();
      int outputTokens = 0;
      await _inference.generate(
        prompt: prompt,
        source: 'debug',
        maxTokens: maxTokens,
        onToken: (_) => outputTokens++,
      );
      stopwatch.stop();
      final latencyMs = stopwatch.elapsedMilliseconds.toDouble();
      final seconds = latencyMs / 1000.0;
      return BenchmarkResult(
        success: true,
        outputTokens: outputTokens,
        latencyMs: latencyMs,
        tokensPerSecond: seconds > 0 ? outputTokens / seconds : 0,
        at: DateTime.now(),
      );
    }
    double totalBps = 0;
    for (final worker in workers) {
      totalBps += (worker.bandwidth ?? 0) * 1e9;
    }
    return BenchmarkResult(
      success: true,
      latencyMs: 0,
      tokensPerSecond: totalBps > 0 ? totalBps / _bytesPerToken : 0,
      at: DateTime.now(),
    );
  }

  @override
  Future<TrafficStats> getTraffic() async {
    final cluster = _cluster;
    double bps = 0;
    for (final worker in cluster.workers) {
      bps += (worker.bandwidth ?? 0) * 1e9;
    }
    return TrafficStats(
      liveSendBps: bps,
      liveRecvBps: bps,
      activeConnections: cluster.workers.length,
      lastActivityAt: cluster.workers.isNotEmpty ? DateTime.now() : null,
    );
  }

  @override
  Future<List<CrashHost>> getCrashedHosts() async {
    final cluster = _cluster;
    final crashed = <CrashHost>[];
    for (final worker in cluster.workers) {
      final reachable = await LlamaCluster.probe(worker.endpoint);
      if (reachable) continue;
      crashed.add(CrashHost(
        host: worker.endpoint,
        name: worker.name,
        lastCrashAt: DateTime.now(),
        message: 'Host antwortet nicht: ${worker.endpoint}',
      ));
    }
    return crashed;
  }
}
