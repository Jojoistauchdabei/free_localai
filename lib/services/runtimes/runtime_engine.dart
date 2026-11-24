enum RuntimeType {
  text,
  image,
}

class RuntimeAvailability {
  final bool available;
  final String? reason;

  const RuntimeAvailability.available() : available = true, reason = null;

  const RuntimeAvailability.unavailable(String reason)
      : available = false,
        reason = reason;
}

class BenchmarkResult {
  final bool success;
  final String? error;
  final int inputTokens;
  final int outputTokens;
  final int images;
  final double tokensPerSecond;
  final double imagesPerSecond;
  final double latencyMs;
  final Duration? loadDuration;
  final DateTime at;

  BenchmarkResult({
    required this.success,
    this.error,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.images = 0,
    this.tokensPerSecond = 0,
    this.imagesPerSecond = 0,
    this.latencyMs = 0,
    this.loadDuration,
    DateTime? at,
  }) : at = at ?? DateTime.now();
}

class TrafficStats {
  final int bytesSent;
  final int bytesReceived;
  final double liveSendBps;
  final double liveRecvBps;
  final int activeConnections;
  final DateTime? lastActivityAt;

  const TrafficStats({
    this.bytesSent = 0,
    this.bytesReceived = 0,
    this.liveSendBps = 0,
    this.liveRecvBps = 0,
    this.activeConnections = 0,
    this.lastActivityAt,
  });
}

class CrashHost {
  final String host;
  final String name;
  final DateTime lastCrashAt;
  final String message;

  const CrashHost({
    required this.host,
    required this.name,
    required this.lastCrashAt,
    required this.message,
  });
}

abstract class RuntimeEngine {
  String get id;

  String get name;

  List<String> get platforms;

  RuntimeType get type;

  String get version;

  Future<RuntimeAvailability> checkAvailability();

  Future<BenchmarkResult> benchmark({
    required String prompt,
    int maxTokens = 64,
  });

  Future<TrafficStats> getTraffic();

  Future<List<CrashHost>> getCrashedHosts();
}
