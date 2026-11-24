import 'package:get/Get.dart';

import '../../core/constants.dart';
import '../../services/hive_service.dart';
import '../../services/t3_agent_service.dart';
import '../runtime_engine.dart';

/// Remote runtime: turns the user's prompts into orchestration runs on a
/// T3 Code server via [T3AgentService].
class T3CodeEngine extends RuntimeEngine {
  static const List<String> _platforms = [
    'android',
    'ios',
    'linux',
    'macos',
    'windows',
  ];

  T3AgentService get _agent => Get.find<T3AgentService>();
  HiveService get _hive => Get.find<HiveService>();

  @override
  String get id => 't3code';

  @override
  String get name => 'T3 Code';

  @override
  List<String> get platforms => _platforms;

  @override
  RuntimeType get type => RuntimeType.text;

  @override
  String get version => '2';

  @override
  Future<RuntimeAvailability> checkAvailability() async {
    if (_agent.isConnected.value) {
      return const RuntimeAvailability.available();
    }
    return RuntimeAvailability.unavailable(
        _agent.status.value == 'resuming'
            ? 'Verbindet sich...'
            : _agent.serverUrl.isEmpty
                ? 'T3 Server-URL nicht konfiguriert.'
                : 'T3 Server nicht verbunden.');
  }

  @override
  Future<BenchmarkResult> benchmark(
      {required String prompt, int maxTokens = 64}) async {
    final stopwatch = Stopwatch()..start();
    int tokens = 0;
    final text = await _agent.sendMessage(
      text: prompt,
      onToken: (_) => tokens++,
    );
    stopwatch.stop();
    final seconds = stopwatch.elapsedMilliseconds / 1000.0;
    return BenchmarkResult(
      success: !text.trimLeft().startsWith('ERROR'),
      outputTokens: tokens,
      latencyMs: stopwatch.elapsedMilliseconds.toDouble(),
      tokensPerSecond: seconds > 0 && tokens > 0 ? tokens / seconds : 0,
      at: DateTime.now(),
    );
  }

  @override
  Future<TrafficStats> getTraffic() async => _agent.traffic;

  @override
  Future<List<CrashHost>> getCrashedHosts() async {
    if (_agent.isConnected.value) return const [];
    final url = _agent.serverUrl.trim();
    if (url.isEmpty) return const [];
    return [
      CrashHost(
        host: url,
        name: name,
        lastCrashAt: DateTime.now(),
        message: 'Nicht verbunden (Status: ${_agent.status.value}).',
      ),
    ];
  }

  String? get t3ServerUrl =>
      _hive.getSetting<String>(AppConstants.keyT3ServerUrl);
}
