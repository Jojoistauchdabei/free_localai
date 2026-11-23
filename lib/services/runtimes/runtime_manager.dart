import 'runtime_engine.dart';
import 'engines/llama_cpp_engine.dart';
import 'engines/bitnet_cpp_engine.dart';
import 'engines/litert_engine.dart';
import 'engines/sd_cpp_engine.dart';
import 'engines/exo_engine.dart';

class RuntimeInfo {
  final String id;
  final String name;
  final List<String> platforms;
  final RuntimeType type;
  final String version;
  final bool available;
  final String? unavailableReason;
  final List<BenchmarkResult> speedTests;
  final TrafficStats traffic;
  final List<CrashHost> crashedHosts;
  final DateTime lastCheckedAt;

  RuntimeInfo({
    required this.id,
    required this.name,
    required this.platforms,
    required this.type,
    required this.version,
    required this.available,
    required this.unavailableReason,
    required this.speedTests,
    required this.traffic,
    required this.crashedHosts,
    required this.lastCheckedAt,
  });

  double get latestSpeed =>
      speedTests.isEmpty ? 0 : speedTests.last.tokensPerSecond + speedTests.last.imagesPerSecond;
}

class RuntimeManager {
  static final RuntimeManager _instance = RuntimeManager._internal();

  static RuntimeManager get instance => _instance;

  RuntimeManager._internal() {
    _registerDefaults();
  }

  final List<RuntimeEngine> _engines = <RuntimeEngine>[];
  final Map<String, RuntimeEngine> _engineById = <String, RuntimeEngine>{};
  final Map<String, List<BenchmarkResult>> _speedTests =
      <String, List<BenchmarkResult>>{};
  final Map<String, RuntimeAvailability> _availabilityCache =
      <String, RuntimeAvailability>{};
  final Map<String, DateTime> _lastAvailabilityAt = <String, DateTime>{};
  static const Duration _availabilityTtl = Duration(minutes: 3);
  static const String _defaultBenchmarkPrompt =
      'Liste die fünf wichtigsten KI-Technologien 2026 auf.';
  static const int _maxSpeedTests = 10;

  static final List<RuntimeEngine Function()> _defaultFactories =
      <RuntimeEngine Function()>[
    LlamaCppEngine.new,
    BitNetCppEngine.new,
    LiteRtmEngine.new,
    SdCppEngine.new,
    ExoEngine.new,
  ];

  void _registerDefaults() {
    for (final factory in _defaultFactories) {
      registerEngine(factory());
    }
  }

  void registerEngine(RuntimeEngine engine) {
    if (!_engineById.containsKey(engine.id)) {
      _engines.add(engine);
      _engineById[engine.id] = engine;
    }
  }

  RuntimeEngine? find(String id) => _engineById[id];

  List<RuntimeEngine> get engines =>
      List<RuntimeEngine>.unmodifiable(_engines);

  Future<List<RuntimeInfo>> runtimeInfos({bool refresh = false}) async {
    final now = DateTime.now();
    final infos = <RuntimeInfo>[];
    for (final engine in engines) {
      infos.add(await _infoFor(engine, now, refresh));
    }
    return infos;
  }

  Future<RuntimeInfo> _infoFor(
      RuntimeEngine engine, DateTime now, bool refresh) async {
    final availability = await _availability(engine, now, refresh);
    TrafficStats traffic = const TrafficStats();
    try {
      traffic = await engine.getTraffic();
    } catch (_) {}
    List<CrashHost> crashedHosts = const [];
    try {
      crashedHosts =
          List<CrashHost>.unmodifiable(await engine.getCrashedHosts());
    } catch (_) {}
    return RuntimeInfo(
      id: engine.id,
      name: engine.name,
      platforms: engine.platforms,
      type: engine.type,
      version: engine.version,
      available: availability.available,
      unavailableReason: availability.reason,
      speedTests: List<BenchmarkResult>.unmodifiable(
          _speedTests[engine.id] ?? const <BenchmarkResult>[]),
      traffic: traffic,
      crashedHosts: crashedHosts,
      lastCheckedAt: now,
    );
  }

  Future<RuntimeAvailability> _availability(
      RuntimeEngine engine, DateTime now, bool refresh) async {
    final cached = _availabilityCache[engine.id];
    final last = _lastAvailabilityAt[engine.id];
    if (!refresh &&
        cached != null &&
        last != null &&
        last.isAfter(now.subtract(_availabilityTtl))) {
      return cached;
    }
    RuntimeAvailability availability;
    try {
      availability = await engine.checkAvailability();
    } catch (e) {
      availability = RuntimeAvailability.unavailable('Check fehlgeschlagen: $e');
    }
    _availabilityCache[engine.id] = availability;
    _lastAvailabilityAt[engine.id] = now;
    return availability;
  }

  Future<BenchmarkResult> benchmark(String engineId,
      {String prompt = 'Liste die fünf wichtigsten KI-Technologien 2026 auf.',
      int maxTokens = 64}) async {
    final engine = find(engineId);
    if (engine == null) {
      throw StateError('Unbekannter Runtime-Engine: $engineId');
    }
    BenchmarkResult result;
    try {
      result = await engine.benchmark(prompt: prompt, maxTokens: maxTokens);
    } catch (e) {
      result =
          BenchmarkResult(success: false, error: 'Benchmark fehlgeschlagen: $e');
    }
    final history = List<BenchmarkResult>.from(
        _speedTests[engineId] ?? const <BenchmarkResult>[]);
    history.add(result);
    if (history.length > _maxSpeedTests) {
      history.removeRange(0, history.length - _maxSpeedTests);
    }
    _speedTests[engineId] = history;
    return result;
  }

  Future<void> benchmarkAll({int maxTokens = 64}) async {
    for (final engine in List<RuntimeEngine>.of(engines)) {
      await benchmark(engine.id,
          prompt: _defaultBenchmarkPrompt, maxTokens: maxTokens);
    }
  }

  Future<List<CrashHost>> crashedHosts() async {
    final hosts = <CrashHost>[];
    for (final engine in engines) {
      try {
        hosts.addAll(await engine.getCrashedHosts());
      } catch (_) {}
    }
    return hosts;
  }
}
