import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import 'package:get/Get.dart';

import '../../services/download_service.dart';
import '../runtime_engine.dart';

class LiteRtmEngine extends RuntimeEngine {
  int inputTokens = 0;
  int outputTokens = 0;
  double lastSpeed = 0;
  DateTime? lastActivityAt;

  static const double _bytesPerToken = 4.5;

  DownloadService get _download => Get.find<DownloadService>();

  @override
  String get id => 'litert';

  @override
  String get name => 'LiteRT-LM';

  @override
  List<String> get platforms => const ['android'];

  @override
  RuntimeType get type => RuntimeType.text;

  @override
  String get version => 'LiteRT-LM';

  Future<String?> _firstLiteRtPath() async {
    final models = await _download.getDownloadedModels();
    final names =
        models.where((f) => f.toLowerCase().endsWith('.litertlm')).toList();
    return names.isEmpty ? null : await _download.modelPath(names.first);
  }

  @override
  Future<RuntimeAvailability> checkAvailability() async {
    if (kIsWeb || !Platform.isAndroid) {
      return RuntimeAvailability.unavailable(
          'LiteRT-LM läuft auf dieser Plattform nicht (Android-only).');
    }
    final modelPath = await _firstLiteRtPath();
    if (modelPath == null) {
      return const RuntimeAvailability.unavailable(
          'Kein .litertlm-Modell heruntergeladen.');
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
    final modelPath = (await _firstLiteRtPath())!;
    LiteLmEngine? engine;
    LiteLmConversation? conversation;
    try {
      engine = await LiteLmEngine.create(LiteLmEngineConfig(
        modelPath: modelPath,
        backend: LiteLmBackend.cpu,
        maxNumTokens: 8192,
      ));
      conversation = await engine.createConversation();
      final stopwatch = Stopwatch()..start();
      final result = await conversation.sendMessage(prompt);
      stopwatch.stop();
      final latencyMs = stopwatch.elapsedMilliseconds.toDouble();
      inputTokens = (prompt.length ~/ 4) + 1;
      outputTokens = ((result.text.length ~/ 4) + 1).clamp(1, 100000).toInt();
      lastSpeed = latencyMs > 0 ? outputTokens / (latencyMs / 1000.0) : 0;
      lastActivityAt = DateTime.now();
      return BenchmarkResult(
        success: true,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        latencyMs: latencyMs,
        tokensPerSecond: lastSpeed,
        at: lastActivityAt!,
      );
    } catch (e) {
      return BenchmarkResult(success: false, error: 'Benchmark fehlgeschlagen: $e');
    } finally {
      try {
        await conversation?.dispose();
      } catch (_) {}
      try {
        await engine?.dispose();
      } catch (_) {}
    }
  }

  @override
  Future<TrafficStats> getTraffic() async {
    return TrafficStats(
      bytesReceived: (outputTokens * _bytesPerToken).round(),
      bytesSent: (inputTokens * _bytesPerToken).round(),
      liveSendBps: lastSpeed,
      liveRecvBps: lastSpeed,
      activeConnections: 0,
      lastActivityAt: lastActivityAt,
    );
  }

  @override
  Future<List<CrashHost>> getCrashedHosts() async => const [];
}
