import '../lib/services/runtimes/runtime_engine.dart';

int check(bool cond, String msg) {
  if (!cond) throw StateError('FAIL: $msg');
  return 1;
}

void main() {
  var n = 0;
  n += check(
      RuntimeAvailability.available().available, 'RuntimeAvailability.available()');
  n += check(
      !RuntimeAvailability.unavailable('x').available, 'RuntimeAvailability.unavailable()');
  n += check(
      !RuntimeAvailability.unavailable('x').available && RuntimeAvailability.unavailable('x').reason == 'x',
      'RuntimeAvailability.unavailable reason');
  final b = BenchmarkResult(
      success: true, outputTokens: 5, latencyMs: 12.5, tokensPerSecond: 100.0);
  n += check(b.success && b.outputTokens == 5, 'BenchmarkResult fields');
  final t = TrafficStats(bytesReceived: 10);
  n += check(t.bytesReceived == 10 && t.activeConnections == 0, 'TrafficStats defaults');
  final c = CrashHost(
      host: 'h', name: 'n', lastCrashAt: DateTime(2026), message: 'm');
  n += check(c.host == 'h', 'CrashHost fields');
  n += check(RuntimeType.text != RuntimeType.image, 'RuntimeType values');
  n += check(BenchmarkResult(success: false, error: 'e').error == 'e',
      'BenchmarkResult.error');

  final swList = Stopwatch()..start();
  var sink = 0;
  for (var i = 0; i < 200000; i++) {
    final list = List<int>.generate(50, (j) => i + j);
    sink += list.reduce((a, b) => a + b);
  }
  swList.stop();

  final map = <String, int>{};
  final swMap = Stopwatch()..start();
  for (var i = 0; i < 20000; i++) {
    map['k$i'] = i;
  }
  swMap.stop();

  if (sink == -1) throw StateError('unreachable');
  print('SMOKE_OK checks=$n');
  print('VM_BENCH list_reduce_loop_200k_ms=${swList.elapsedMilliseconds}');
  print('VM_BENCH map_fill_20000_ms=${swMap.elapsedMilliseconds}');
}
