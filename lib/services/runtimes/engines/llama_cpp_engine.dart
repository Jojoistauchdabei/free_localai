import 'dart:io';

import 'package:get/Get.dart';

import '../../services/download_service.dart';
import '../../services/inference_service.dart';
import '../runtime_engine.dart';

class LlamaCppEngine extends RuntimeEngine {
  int inputTokens = 0;
  int outputTokens = 0;
  double lastSpeed = 0;
  DateTime? lastActivityAt;

  static const double _bytesPerToken = 4.5;

  InferenceService get _inference => Get.find<InferenceService>();
  DownloadService get _download => Get.find<DownloadService>();

  @override
  String get id => 'llama_cpp';

  @override
  String get name => 'llama.cpp';

  @override
  List<String> get platforms => const ['android', 'ios', 'linux', 'windows'];

  @override
  RuntimeType get type => RuntimeType.text;

  @override
  String get version => 'llama.cpp';

  Future<String?> firstGgufPath() async {
    final models = await _download.getDownloadedModels();
    final gguf = models.where((f) => f.toLowerCase().endsWith('.gguf')).toList();
    return gguf.isEmpty ? null : await _download.modelPath(gguf.first);
  }

  @override
  Future<RuntimeAvailability> checkAvailability() async {
    if (!_inference.supportsLocalInference) {
      return RuntimeAvailability.unavailable(
          'Lokale Inferenz ist auf dieser Plattform nicht verfügbar.');
    }
    final modelPath = await firstGgufPath();
    if (modelPath == null) {
      return const RuntimeAvailability.unavailable(
          'Kein GGUF-Modell heruntergeladen.');
    }
    if (!await File(modelPath).exists()) {
      return RuntimeAvailability.unavailable('Modelldatei nicht gefunden: $modelPath');
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
    final modelPath = await firstGgufPath();
    if (modelPath == null) {
      return BenchmarkResult(success: false, error: 'Kein GGUF-Modell zum Benchmark.');
    }
    if (!_inference.isModelLoaded.value) {
      try {
        await _inference.loadModel(modelPath,
            modelName: modelPath.split('/').last);
      } catch (e) {
        return BenchmarkResult(
            success: false, error: 'Modell konnte nicht geladen werden: $e');
      }
      if (!_inference.isModelLoaded.value) {
        return BenchmarkResult(success: false, error: 'Modell ist nicht geladen.');
      }
      final result = await _benchmarkLoadedModel(prompt, maxTokens);
      await _inference.unloadModel();
      return result;
    }
    return await _benchmarkLoadedModel(prompt, maxTokens);
  }

  Future<BenchmarkResult> _benchmarkLoadedModel(
      String prompt, int maxTokens) async {
    inputTokens = (prompt.length ~/ 4) + 1;
    outputTokens = 0;
    final stopwatch = Stopwatch()..start();
    await _inference.generate(
      prompt: prompt,
      source: 'debug',
      maxTokens: maxTokens,
      onToken: (_) => outputTokens++,
    );
    stopwatch.stop();
    final seconds = stopwatch.elapsedMilliseconds / 1000.0;
    lastSpeed = seconds > 0 ? outputTokens / seconds : 0;
    lastActivityAt = DateTime.now();
    return BenchmarkResult(
      success: true,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      latencyMs: stopwatch.elapsedMilliseconds.toDouble(),
      tokensPerSecond: lastSpeed,
      at: lastActivityAt!,
    );
  }

  @override
  Future<TrafficStats> getTraffic() async {
    return TrafficStats(
      bytesReceived: (outputTokens * _bytesPerToken).round(),
      bytesSent: (inputTokens * _bytesPerToken).round(),
      liveSendBps: lastSpeed * _bytesPerToken,
      liveRecvBps: lastSpeed * _bytesPerToken,
      activeConnections: 0,
      lastActivityAt: lastActivityAt,
    );
  }

  @override
  Future<List<CrashHost>> getCrashedHosts() async => const [];
}
