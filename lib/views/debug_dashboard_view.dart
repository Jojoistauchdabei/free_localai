import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../services/runtimes/runtime_manager.dart';

class DebugDashboardView extends StatefulWidget {
  const DebugDashboardView({super.key});

  @override
  State<DebugDashboardView> createState() => _DebugDashboardViewState();
}

class _DebugDashboardViewState extends State<DebugDashboardView> {
  final RuntimeManager _manager = RuntimeManager.instance;
  bool _loading = false;
  bool _benchmarkingAll = false;
  String? _benchmarkingEngineId;
  List<RuntimeInfo> _infos = const <RuntimeInfo>[];
  List<CrashHost> _crashedHosts = const <CrashHost>[];

  Future<void> _refresh({bool refreshAvailability = true}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      _infos = await _manager.runtimeInfos(refresh: refreshAvailability);
      _crashedHosts = await _manager.crashedHosts();
    } catch (e) {
      Get.snackbar('Debug-Dashboard', 'Fehler beim Laden: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _benchmark(RuntimeEngine engine) async {
    setState(() => _benchmarkingEngineId = engine.id);
    try {
      await _manager.benchmark(engine.id);
    } catch (e) {
      Get.snackbar('Benchmark: ${engine.name}', 'Fehler: $e');
    } finally {
      if (mounted) {
        setState(() => _benchmarkingEngineId = null);
        await _refresh(refreshAvailability: false);
      }
    }
  }

  Future<void> _benchmarkAll() async {
    if (_benchmarkingAll) return;
    setState(() => _benchmarkingAll = true);
    try {
      await _manager.benchmarkAll();
    } catch (e) {
      Get.snackbar('Benchmark-Alle', 'Fehler: $e');
    } finally {
      if (mounted) {
        setState(() => _benchmarkingAll = false);
        await _refresh(refreshAvailability: false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug-Dashboard'),
        subtitle: const Text('Runtime-Manager'),
        actions: [
          IconButton(
            icon: const Icon(Icons.all_inclusive_outlined),
            tooltip: 'Alle testen',
            onPressed: _benchmarkingAll ? null : _benchmarkAll,
          ),
        ],
      ),
      body: _loading && _infos.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => _refresh(),
              child: ListView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                children: [
                  _runtimesSection(
                      _infos, _benchmarkingEngineId, _benchmark),
                  _crashedHostsSection(context, _crashedHosts),
                ],
              ),
            ),
    );
  }
}

Widget _runtimesSection(
  List<RuntimeInfo> infos,
  String? benchmarkingEngineId,
  Future<void> Function(RuntimeEngine engine) onBenchmark,
) {
  if (infos.isEmpty) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Text('Keine Runtimes registriert.'),
    );
  }
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final info in infos)
        _RuntimeCard(
          info: info,
          busy: benchmarkingEngineId == info.id,
          onBenchmark: () => onBenchmark(_engineOf(info)),
        ),
    ],
  );
}

RuntimeEngine _engineOf(RuntimeInfo info) {
  final engine = RuntimeManager.instance.find(info.id);
  if (engine == null) {
    throw StateError('Engine nicht gefunden: ${info.id}');
  }
  return engine;
}

class _RuntimeCard extends StatelessWidget {
  final RuntimeInfo info;
  final bool busy;
  final VoidCallback onBenchmark;

  const _RuntimeCard({
    required this.info,
    required this.busy,
    required this.onBenchmark,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final traffic = info.traffic;
    final speedText =
        info.latestSpeed > 0 ? _fmtSpeed(info) : '${_unit(info)} -';
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(info.name,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      Text('${info.id} · ${info.platforms.join(', ')}',
                          style: theme.textTheme.labelSmall),
                    ],
                  ),
                ),
                Icon(
                  info.available ? Icons.check_circle_outline : Icons.warning,
                  color:
                      info.available ? theme.colorScheme.primary : theme.colorScheme.error,
                  size: 20,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              info.available
                  ? 'Verfügbar'
                  : (info.unavailableReason ?? 'Nicht verfügbar'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: info.available ? null : theme.colorScheme.error,
              ),
            ),
            if (info.version != 'unknown')
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Version: ${info.version}',
                    style: theme.textTheme.labelSmall),
              ),
            const SizedBox(height: 8),
            Text('Speed: $speedText',
                style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600, color: theme.colorScheme.tertiary)),
            Text('Netzwerkverkehr: eingegangen ${_fmtBytes(traffic.bytesReceived)}, '
                'ausgegangen ${_fmtBytes(traffic.bytesSent)}, '
                'live RX ${_fmtBps(traffic.liveRecvBps)}, TX ${_fmtBps(traffic.liveSendBps)}, '
                'Verbindungen ${traffic.activeConnections}',
                style: theme.textTheme.labelSmall),
            if (info.crashedHosts.isNotEmpty)
              Text('Abgestürzte Hosts: ${info.crashedHosts.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.error)),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: busy ? null : onBenchmark,
                icon: const Icon(Icons.play_arrow_outlined, size: 18),
                label: Text(
                    busy ? 'Benchmark läuft...' : 'Benchmark starten'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _crashedHostsSection(BuildContext context, List<CrashHost> hosts) {
  final theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Abgestürzte Hosts / PCs',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (hosts.isEmpty)
          Text('Keine abgestürzten Hosts/PCs gemeldet.',
              style: theme.textTheme.bodySmall)
        else
          for (final host in hosts.take(20))
            ListTile(
              leading: Icon(Icons.error_outline,
                  color: theme.colorScheme.error, size: 18),
              title: Text(host.name),
              subtitle: Text('${host.host} · ${_fmtTime(host.lastCrashAt)}'),
              dense: true,
            ),
      ],
    ),
  );
}

String _unit(RuntimeInfo info) =>
    info.type == RuntimeType.image ? 'Img/s' : 'Tok/s';

String _fmtSpeed(RuntimeInfo info) {
  final speed = info.latestSpeed;
  return '${_unit(info)} ${speed.toStringAsFixed(1)}';
}

String _fmtBps(double bps) => '${_fmtBytes(bps.toInt())}/s';

String _fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}

String _fmtTime(DateTime time) {
  final diff = DateTime.now().difference(time).abs();
  if (diff.inMinutes < 1) return 'Jetzt';
  if (diff.inHours < 1) return 'Vor ${diff.inMinutes} Min.';
  if (diff.inDays < 1) return 'Vor ${diff.inHours} Std.';
  return 'Vor ${diff.inDays} T.';
}
