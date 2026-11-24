import 'package:flutter_test/flutter_test.dart';

import 'package:privatelm/services/runtimes/runtime_engine.dart';
import 'package:privatelm/services/runtimes/runtime_manager.dart';

class _FakeEngine implements RuntimeEngine {
  @override
  final String id;
  @override
  final String name;
  @override
  final List<String> platforms;
  @override
  final RuntimeType type;
  @override
  final String version;
  final bool isAvailable;
  final double speed;
  int benchmarkCount = 0;

  _FakeEngine({
    required this.id,
    this.name = 'Fake Engine',
    this.speed = 12.5,
    this.isAvailable = true,
    this.type = RuntimeType.text,
    this.platforms = const ['fake'],
    this.version = '9.9',
  });

  @override
  Future<RuntimeAvailability> checkAvailability() async => isAvailable
      ? RuntimeAvailability.available()
      : RuntimeAvailability.unavailable('Fake nicht verfügbar');

  @override
  Future<BenchmarkResult> benchmark(
      {required String prompt, int maxTokens = 64}) async {
    benchmarkCount++;
    return BenchmarkResult(
      success: true,
      inputTokens: 1,
      outputTokens: maxTokens,
      latencyMs: 100,
      tokensPerSecond: speed,
    );
  }

  @override
  Future<TrafficStats> getTraffic() async => const TrafficStats(
        bytesReceived: 1000,
        bytesSent: 2000,
        activeConnections: 3,
      );

  @override
  Future<List<CrashHost>> getCrashedHosts() async => const [
        CrashHost(
          host: '10.0.0.2:50052',
          name: 'Gone',
          lastCrashAt: DateTime(2026, 1, 1),
          message: 'nicht erreichbar',
        ),
      ];
}

void main() {
  test('default engines are registered', () {
    final ids = RuntimeManager.instance.engines.map((e) => e.id).toSet();
    expect(
        ids,
        containsAll(
            ['llama_cpp', 'bitnet_cpp', 'litert', 'sd_cpp', 'exo']));
  });

  test('find returns engine by id or null', () {
    expect(RuntimeManager.instance.find('llama_cpp'), isA<RuntimeEngine>());
    expect(RuntimeManager.instance.find('does_not_exist'), isNull);
  });

  test('registerEngine ignores duplicate ids', () {
    final manager = RuntimeManager.instance;
    final first = _FakeEngine(id: 'fake_dup');
    final second = _FakeEngine(id: 'fake_dup');
    manager.registerEngine(first);
    final count = manager.engines.length;
    manager.registerEngine(second);
    expect(manager.engines.length, count);
    expect(manager.find('fake_dup'), same(first));
  });

  test('runtimeInfos returns info for fake engines', () async {
    final fake = _FakeEngine(id: 'fake_info', isAvailable: true);
    RuntimeManager.instance.registerEngine(fake);
    final infos = await RuntimeManager.instance.runtimeInfos();
    final info = infos.firstWhere((i) => i.id == 'fake_info');
    expect(info.available, isTrue);
    expect(info.unavailableReason, isNull);
    expect(info.type, RuntimeType.text);
    expect(info.version, '9.9');
    expect(info.platforms, const ['fake']);
    expect(info.traffic.bytesReceived, 1000);
    expect(info.traffic.activeConnections, 3);
    expect(info.crashedHosts.length, 1);
    expect(info.crashedHosts.first.name, 'Gone');
  });

  test('runtimeInfos marks unavailable fake engines with reason', () async {
    final fake = _FakeEngine(id: 'fake_unavail', isAvailable: false);
    RuntimeManager.instance.registerEngine(fake);
    final infos = await RuntimeManager.instance.runtimeInfos();
    final info = infos.firstWhere((i) => i.id == 'fake_unavail');
    expect(info.available, isFalse);
    expect(info.unavailableReason, 'Fake nicht verfügbar');
  });

  test('benchmark stores speed test and updates info', () async {
    final fake = _FakeEngine(id: 'fake_bench');
    RuntimeManager.instance.registerEngine(fake);
    final result = await RuntimeManager.instance.benchmark('fake_bench');
    expect(result.success, isTrue);
    expect(result.tokensPerSecond, 12.5);
    expect(fake.benchmarkCount, 1);
    final infos = await RuntimeManager.instance.runtimeInfos();
    final info = infos.firstWhere((i) => i.id == 'fake_bench');
    expect(info.speedTests.length, 1);
    expect(info.speedTests.first.tokensPerSecond, 12.5);
    expect(info.latestSpeed, 12.5);
  });

  test('benchmark of unknown engine throws StateError', () async {
    expect(RuntimeManager.instance.benchmark('missing'), throwsStateError);
  });

  test('benchmarkAll runs benchmarks for registered engines', () async {
    final fake = _FakeEngine(id: 'fake_all');
    RuntimeManager.instance.registerEngine(fake);
    await RuntimeManager.instance.benchmarkAll();
    expect(fake.benchmarkCount, 1);
  });

  test('crashedHosts aggregates across engines', () async {
    final fake = _FakeEngine(id: 'fake_crash');
    RuntimeManager.instance.registerEngine(fake);
    final hosts = await RuntimeManager.instance.crashedHosts();
    expect(hosts.where((h) => h.name == 'Gone').length, greaterThan(0));
  });
}
