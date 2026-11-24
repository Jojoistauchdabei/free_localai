import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/Get.dart';

import '../../services/local_image_service.dart';
import '../runtime_engine.dart';

class SdCppEngine extends RuntimeEngine {
  int bytesProduced = 0;
  double lastGenerationMs = 0;
  DateTime? lastActivityAt;

  static const String _benchmarkPrompt = 'A cute cartoon bear holding a flower';

  LocalImageService? get _image =>
      Get.isRegistered<LocalImageService>() ? Get.find<LocalImageService>() : null;

  @override
  String get id => 'sd_cpp';

  @override
  String get name => 'Stable Diffusion.cpp';

  @override
  List<String> get platforms => const ['android', 'ios'];

  @override
  RuntimeType get type => RuntimeType.image;

  @override
  String get version => 'stable-diffusion.cpp';

  Future<RuntimeAvailability> _safeCheckAvailability() async {
    try {
      return await checkAvailability();
    } catch (e) {
      return RuntimeAvailability.unavailable('Check fehlgeschlagen: $e');
    }
  }

  @override
  Future<RuntimeAvailability> checkAvailability() async {
    if (kIsWeb) {
      return RuntimeAvailability.unavailable(
          'Lokale Image-Generierung ist in der Web-Version nicht verfügbar.');
    }
    final image = _image;
    if (image == null) {
      return const RuntimeAvailability.unavailable(
          'LocalImageService ist nicht geladen.');
    }
    if (!image.isModelLoaded.value && image.lastModelPath == null) {
      return const RuntimeAvailability.unavailable(
          'Kein Stable-Diffusion-Modell geladen oder heruntergeladen.');
    }
    return const RuntimeAvailability.available();
  }

  @override
  Future<BenchmarkResult> benchmark(
      {required String prompt, int maxTokens = 64}) async {
    final availability = await _safeCheckAvailability();
    if (!availability.available) {
      return BenchmarkResult(
          success: false, error: availability.reason ?? 'nicht verfügbar');
    }
    final image = _image!;
    if (!image.isModelLoaded.value) {
      try {
        await image.loadModel(image.lastModelPath!);
      } catch (e) {
        return BenchmarkResult(
            success: false, error: 'SD-Modell konnte nicht geladen werden: $e');
      }
    }
    if (!image.isModelLoaded.value) {
      return BenchmarkResult(success: false, error: 'SD-Modell ist nicht geladen.');
    }
    final stopwatch = Stopwatch()..start();
    final bytes = await image.generateImage(prompt: _benchmarkPrompt);
    stopwatch.stop();
    final latencyMs = stopwatch.elapsedMilliseconds.toDouble();
    if (bytes == null || bytes.isEmpty) {
      return BenchmarkResult(success: false, error: 'Kein Bild generiert.');
    }
    bytesProduced = bytes.length;
    lastGenerationMs = latencyMs;
    lastActivityAt = DateTime.now();
    return BenchmarkResult(
      success: true,
      images: 1,
      latencyMs: latencyMs,
      imagesPerSecond: 1000.0 / latencyMs.clamp(1, 100000),
      at: lastActivityAt!,
    );
  }

  @override
  Future<TrafficStats> getTraffic() async {
    final seconds = lastGenerationMs > 0 ? lastGenerationMs / 1000.0 : 0;
    return TrafficStats(
      bytesReceived: bytesProduced,
      bytesSent: bytesProduced,
      liveSendBps: seconds > 0 ? bytesProduced / seconds : 0,
      liveRecvBps: seconds > 0 ? bytesProduced / seconds : 0,
      activeConnections: 0,
      lastActivityAt: lastActivityAt,
    );
  }

  @override
  Future<List<CrashHost>> getCrashedHosts() async => const [];
}
