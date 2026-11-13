import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/ui.dart';
import '../services/cluster_service.dart';
import '../services/inference_service.dart';
import '../services/lan_model_share_service.dart';

/// Phone cluster: pick Master (runs the model) or Worker (lends this phone),
/// and pair them by scanning the worker's QR code.
class ClusterView extends StatefulWidget {
  const ClusterView({super.key});

  @override
  State<ClusterView> createState() => _ClusterViewState();
}

class _ClusterViewState extends State<ClusterView> {
  final ClusterService cluster = Get.find<ClusterService>();
  Timer? _wifiTimer;

  @override
  void initState() {
    super.initState();
    cluster.refreshWorkerStatus();
    cluster.refreshWifiAddress();
    if (cluster.role == ClusterRole.master) cluster.relocateWorkers();
    // Pick up Wi-Fi being turned on while this screen is open.
    _wifiTimer = Timer.periodic(
        const Duration(seconds: 3), (_) => cluster.refreshWifiAddress());
  }

  @override
  void dispose() {
    _wifiTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Phone cluster', showBack: true),
      body: Obx(() {
        final role = cluster.role;
        return ListView(
          padding: kPagePadding,
          children: [
            const SizedBox(height: 8),
            AppSegmented<ClusterRole>(
              items: [
                (ClusterRole.off, 'Off'),
                if (ClusterService.canBeMaster) (ClusterRole.master, 'Master'),
                if (ClusterService.canBeWorker) (ClusterRole.worker, 'Worker'),
              ],
              selected: role,
              onChanged: cluster.setRole,
            ),
            const SizedBox(height: 16),
            if (role != ClusterRole.off &&
                cluster.wifiAddress.value == null) ...[
              AppNotice(
                'Turn on Wi-Fi. All phones in the cluster must be on the same Wi-Fi network.',
                icon: Icons.wifi_off_rounded,
                color: t.orange,
              ),
              const SizedBox(height: 16),
            ],
            if (role != ClusterRole.off &&
                Get.isRegistered<LanModelShareService>()) ...[
              _lanModelsSection(context, Get.find<LanModelShareService>()),
              const SizedBox(height: 16),
            ],
            ...switch (role) {
              ClusterRole.off => _offSection(),
              ClusterRole.master => _masterSection(context),
              ClusterRole.worker => _workerSection(context),
            },
          ],
        );
      }),
    );
  }

  List<Widget> _offSection() => [
        AppNotice(
          ClusterService.canBeMaster
              ? 'Run models too big for one phone by sharing the work across '
                  'phones on the same Wi-Fi.\n\n'
                  'Master: the phone you chat on. It runs the model.\n'
                  'Worker: a phone that lends its memory to the master.'
              : 'Help an Android phone running PrivateLM run models too big for '
                  'it alone: choose Worker, then scan this device\'s QR code '
                  'from that phone.',
          icon: Icons.hub_outlined,
        ),
      ];

  // ── Worker ─────────────────────────────────────────────────────────────

  List<Widget> _workerSection(BuildContext context) {
    final t = AppTokens.of(context);
    final s = cluster.worker.value;
    final qr = cluster.workerQrData;

    final Widget body;
    if (s.state == 'error') {
      body = _centered(context, [
        Icon(Icons.error_outline_rounded, size: 40, color: t.red),
        const SizedBox(height: 12),
        Text('Worker stopped', style: t.bodyStrong),
        const SizedBox(height: 4),
        Text(s.error ?? 'Unknown error',
            style: t.caption, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        PillButton(
            label: 'Try again', primary: true, onPressed: cluster.startWorker),
      ]);
    } else if (s.peer != null) {
      body = _centered(context, [
        _PulsingDot(color: t.green),
        const SizedBox(height: 14),
        Text('Sharing with master', style: t.bodyStrong.copyWith(fontSize: 18)),
        const SizedBox(height: 4),
        Text(s.peer!, style: t.caption),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: _Stat(label: 'Holding', value: _gb(s.heldMb))),
          Expanded(child: _Stat(label: 'Free at start', value: _gb(s.ramMb))),
          Expanded(
              child: _Stat(
                  label: 'Memory speed',
                  value: '${s.bandwidth.toStringAsFixed(1)} GB/s')),
        ]),
      ]);
    } else if (!s.running || qr == null) {
      body = _centered(context, [
        const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5)),
        const SizedBox(height: 16),
        Text(s.running ? 'Waiting for Wi-Fi…' : 'Measuring this phone…',
            style: t.caption),
      ]);
    } else {
      body = _centered(context, [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: QrImageView(data: qr, size: 220, padding: EdgeInsets.zero),
        ),
        const SizedBox(height: 16),
        Text('Scan this from the master phone', style: t.bodyStrong),
        const SizedBox(height: 6),
        Row(mainAxisSize: MainAxisSize.min, children: [
          StatusDot(t.green, size: 8),
          const SizedBox(width: 6),
          Text('Ready · ${cluster.wifiAddress.value}', style: t.caption),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _Stat(label: 'Free memory', value: _gb(s.ramMb))),
          Expanded(
              child: _Stat(
                  label: 'Memory speed',
                  value: '${s.bandwidth.toStringAsFixed(1)} GB/s')),
        ]),
      ]);
    }

    return [
      if (s.throttled) ...[
        AppNotice(
          'Android is slowing this worker down (slow cores only), which slows '
          'the whole cluster. Set PrivateLM\'s battery use to Unrestricted, '
          'then turn Worker off and on.',
          icon: Icons.speed_rounded,
          color: t.orange,
        ),
        const SizedBox(height: 8),
        const Align(
          alignment: Alignment.centerLeft,
          child: PillButton(
            label: 'Set Unrestricted',
            primary: true,
            onPressed: LlamaCluster.requestBatteryUnrestricted,
          ),
        ),
        const SizedBox(height: 16),
      ],
      AppCard(padding: const EdgeInsets.fromLTRB(16, 24, 16, 20), child: body),
      SectionFootnote(ClusterService.workerStopsWithApp
          ? 'Keep this device plugged in, on the same Wi-Fi, with PrivateLM open: '
              'iOS pauses apps in the background. Close PrivateLM to stop sharing.'
          : 'Keep this phone plugged in and on the same Wi-Fi, with PrivateLM '
              'open: the screen stays on while sharing, because Android slows '
              'background work. Set Phone cluster to Off to stop.'),
    ];
  }

  Widget _centered(BuildContext context, List<Widget> children) =>
      Column(crossAxisAlignment: CrossAxisAlignment.center, children: children);

  // ── Master ─────────────────────────────────────────────────────────────

  List<Widget> _masterSection(BuildContext context) {
    final t = AppTokens.of(context);
    return [
      _scheduleCard(context),
      const SizedBox(height: 16),
      if (cluster.split.length > 1) ...[
        _SplitCard(shares: cluster.split),
        const SizedBox(height: 16),
      ],
      PrimaryButton(
        label: 'Scan a worker\'s QR code',
        icon: Icons.qr_code_scanner_rounded,
        onPressed: _scanQr,
      ),
      SectionHeader('Workers (${cluster.workers.length})'),
      if (cluster.workers.isEmpty)
        const AppGroup(children: [
          EmptyState(
            icon: Icons.devices_other_rounded,
            title: 'No workers yet',
            message: 'On each other phone, open Phone cluster, choose Worker, '
                'then scan the QR code it shows.',
          ),
        ])
      else
        AppGroup(dividerIndent: 60, children: [
          for (final w in cluster.workers)
            AppRow(
              icon: Icons.smartphone_rounded,
              title: w.model ?? w.name,
              subtitle: [
                w.endpoint,
                if (w.ramMb != null) '${_gb(w.ramMb!)} free',
                if (w.bandwidth != null)
                  '${w.bandwidth!.toStringAsFixed(1)} GB/s',
              ].join(' · '),
              trailing: IconButton(
                icon: Icon(Icons.close_rounded, color: t.muted),
                tooltip: 'Remove',
                onPressed: () => cluster.remove(w),
              ),
            ),
        ]),
      if (cluster.workers.isNotEmpty) ...[
        const SizedBox(height: 12),
        SectionHeader('Paired device resources'),
        AppCard(
          child: Column(
            children: [
              for (final worker in cluster.workers)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.device_hub_rounded),
                  title: Text(worker.model ?? worker.name),
                  subtitle: Text([
                    if (worker.ramMb != null)
                      '${_gb(worker.ramMb!)} free system RAM',
                    if (worker.bandwidth != null)
                      '${worker.bandwidth!.toStringAsFixed(1)} GB/s memory',
                    if (cluster.split.isNotEmpty)
                      '${_shareFor(worker)} model share',
                  ].join(' · ')),
                  trailing: Text(
                    cluster.scheduleMode.value == 'manual' &&
                            (cluster.workerWeights[worker.endpoint] ?? 0) == 0
                        ? 'OFF'
                        : 'ON',
                    style: t.caption,
                  ),
                ),
            ],
          ),
        ),
      ],
      if (cluster.localGpuDevices.isNotEmpty) ...[
        const SizedBox(height: 20),
        SectionHeader('This PC: Vulkan devices'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Each GPU is available separately. Auto mode chooses the '
                'fastest device that can hold the model; select more devices '
                'to distribute a larger model.',
                style: t.caption,
              ),
              const SizedBox(height: 8),
              Row(children: [
                PillButton(
                  label: 'Fastest only',
                  icon: Icons.speed_rounded,
                  onPressed: cluster.autoSelectLocalGpus,
                ),
                const SizedBox(width: 8),
                PillButton(
                  label: 'Use all',
                  icon: Icons.select_all_rounded,
                  onPressed: cluster.selectAllLocalGpus,
                ),
              ]),
              const SizedBox(height: 4),
              for (final gpu in cluster.localGpuDevices)
                CheckboxListTile(
                  value: gpu.selected,
                  onChanged: (value) =>
                      cluster.setLocalGpuSelected(gpu.index, value ?? false),
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.memory_rounded),
                  title: Text(gpu.name),
                  subtitle: Text(
                    '${_gb(gpu.freeMemoryBytes / (1024 * 1024))} free of '
                    '${_gb(gpu.totalMemoryBytes / (1024 * 1024))}'
                    ' · ${gpu.totalMemoryBytes > 0 ? ((1 - gpu.freeMemoryBytes / gpu.totalMemoryBytes) * 100).round() : 0}% memory used'
                    '${gpu.memorySpeedGbps > 0 ? ' · ${gpu.memorySpeedGbps.toStringAsFixed(1)} GB/s' : ''}',
                  ),
                ),
            ],
          ),
        ),
      ],
      if (cluster.localCpuDevice.value != null) ...[
        const SizedBox(height: 12),
        AppCard(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.memory_rounded),
            title: Text('CPU · ${cluster.localCpuDevice.value!.name}'),
            subtitle: Text(
              '${_gb(cluster.localCpuDevice.value!.freeMemoryBytes / (1024 * 1024))} '
              'available of ${_gb(cluster.localCpuDevice.value!.totalMemoryBytes / (1024 * 1024))}'
              ' · ${cluster.localCpuDevice.value!.logicalCores} threads'
              ' · ${cluster.localCpuDevice.value!.computeTops.toStringAsFixed(3)} TOPS'
              '\nShared RAM is counted once; the integrated GPU uses this same pool.',
            ),
          ),
        ),
      ],
      const SectionFootnote(
        'Paired devices communicate over the local network through the '
        'llama.cpp RPC link. The master keeps the chat session; workers '
        'provide their assigned model memory. Changes apply on the next load.',
      ),
      const SectionHeader('Other ways to add'),
      Row(children: [
        PillButton(
          label: cluster.isScanning.value ? 'Searching…' : 'Find nearby',
          icon: Icons.wifi_find_rounded,
          onPressed: cluster.isScanning.value ? null : cluster.scanNearby,
        ),
        const SizedBox(width: 10),
        PillButton(
          label: 'Enter IP',
          icon: Icons.keyboard_rounded,
          onPressed: () => _enterIp(context),
        ),
      ]),
      if (cluster.found.isNotEmpty) ...[
        const SizedBox(height: 12),
        AppGroup(dividerIndent: 60, children: [
          for (final w in cluster.found)
            AppRow(
              icon: Icons.smartphone_rounded,
              title: w.model ?? w.name,
              subtitle: w.endpoint,
              trailing: PillButton(
                label: 'Add',
                primary: true,
                onPressed: () => _report(cluster.addFound(w)),
              ),
            ),
        ]),
      ],
    ];
  }

  Widget _scheduleCard(BuildContext context) {
    final t = AppTokens.of(context);
    final sharing = Get.isRegistered<LanModelShareService>()
        ? Get.find<LanModelShareService>()
        : null;
    return Obx(() => AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Master scheduling', style: t.bodyStrong),
              const SizedBox(height: 4),
              Text(
                'Smart uses the fastest available devices. Manual lets you '
                'exclude devices or assign their relative share.',
                style: t.caption,
              ),
              const SizedBox(height: 10),
              AppSegmented<String>(
                items: const [('smart', 'Smart'), ('manual', 'Manual')],
                selected: cluster.scheduleMode.value,
                onChanged: cluster.setScheduleMode,
              ),
              if (cluster.scheduleMode.value == 'manual' &&
                  cluster.workers.isNotEmpty) ...[
                const SizedBox(height: 12),
                _weightRow(
                  label: 'This PC',
                  value: cluster.localWeight.value,
                  onChanged: cluster.setLocalWeight,
                ),
                for (final worker in cluster.workers)
                  _weightRow(
                    label: worker.model ?? worker.name,
                    value: cluster.workerWeights[worker.endpoint] ?? 0,
                    onChanged: (value) =>
                        cluster.setWorkerWeight(worker, value),
                  ),
              ],
              const Divider(height: 20),
              Text('Live cluster statistics', style: t.bodyStrong),
              const SizedBox(height: 8),
              _clusterStats(context, sharing),
            ],
          ),
        ));
  }

  String _shareFor(ClusterWorker worker) {
    final share = cluster.split.firstWhereOrNull((item) =>
        item.name == (worker.model ?? worker.name) ||
        item.name == worker.endpoint);
    return share == null ? 'not assigned' : _gb(share.mb);
  }

  Widget _weightRow({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
        SizedBox(
          width: 150,
          child: Slider(
            value: value.clamp(0, 100),
            min: 0,
            max: 100,
            divisions: 20,
            label: '${value.round()}%',
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 38, child: Text('${value.round()}%')),
      ],
    );
  }

  Widget _clusterStats(BuildContext context, LanModelShareService? sharing) {
    final t = AppTokens.of(context);
    final inference = Get.isRegistered<InferenceService>()
        ? Get.find<InferenceService>()
        : null;
    final cpu = cluster.localCpuDevice.value;
    final gpuMemory = cluster.localGpuDevices
        .fold<int>(0, (sum, device) => sum + device.freeMemoryBytes);
    final split = cluster.split;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          [
            if (cpu != null)
              'RAM frei ${(cpu.freeMemoryBytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB'
                  ' · ${cpu.logicalCores} CPU-Threads',
            if (gpuMemory > 0)
              'GPU frei ${(gpuMemory / 1024 / 1024 / 1024).toStringAsFixed(1)} GB',
            if (cluster.freeStorageBytes.value != null)
              'Speicher frei ${(cluster.freeStorageBytes.value! / 1024 / 1024 / 1024).toStringAsFixed(1)} GB',
            if (inference != null)
              '${inference.tokensPerSecond.value.toStringAsFixed(1)} tok/s'
                  ' · ${inference.tokenCount.value} Tokens',
            if (sharing != null)
              'LAN-Kopien ${(sharing.transferredBytes.value / 1024 / 1024).toStringAsFixed(1)} MB',
          ].join('\n'),
          style: t.caption,
        ),
        if (split.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final share in split)
            Text(
              '${share.name}: ${(share.mb / 1024).toStringAsFixed(1)} GB Modellanteil',
              style: t.caption,
            ),
        ],
      ],
    );
  }

  Widget _lanModelsSection(BuildContext context, LanModelShareService sharing) {
    final t = AppTokens.of(context);
    return Obx(() {
      final remoteModels = [
        for (final peer in sharing.peers)
          for (final model in peer.models) (peer: peer, model: model),
      ];
      return AppCard(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.lan_outlined, color: t.accent),
            const SizedBox(width: 10),
            Expanded(child: Text('Models on LAN', style: t.bodyStrong)),
            PillButton(
              label: sharing.isScanning.value ? 'Searching…' : 'Find',
              icon: Icons.search_rounded,
              onPressed: sharing.isScanning.value ? null : sharing.scan,
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            remoteModels.isEmpty
                ? 'Find model files shared by another PrivateLM device on this Wi-Fi.'
                : '${remoteModels.length} model file(s) available nearby.',
            style: t.caption,
          ),
          if (remoteModels.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final item in remoteModels)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(item.model),
                subtitle: Text(item.peer.name),
                trailing: sharing.activeTransfers[item.model] == null
                    ? PillButton(
                        label: 'Copy',
                        primary: true,
                        onPressed: () async {
                          final error =
                              await sharing.download(item.peer, item.model);
                          if (error != null) {
                            showToast('Model share failed', error,
                                tone: ToastTone.error);
                          } else {
                            showToast('Model copied', item.model,
                                tone: ToastTone.success);
                          }
                        },
                      )
                    : SizedBox(
                        width: 110,
                        child: Obx(() {
                          final transfer = sharing.activeTransfers[item.model];
                          if (transfer == null) return const SizedBox.shrink();
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              LinearProgressIndicator(
                                  value: transfer.totalBytes.value > 0
                                      ? transfer.progress
                                      : null),
                              const SizedBox(height: 2),
                              Text(
                                '${transfer.totalBytes.value > 0 ? '${(transfer.progress * 100).round()}% · ' : ''}'
                                '${transfer.status.value} · '
                                '${(transfer.bytesPerSecond.value / 1024 / 1024).toStringAsFixed(1)} MB/s',
                                style: t.caption,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          );
                        }),
                      ),
              ),
          ],
        ]),
      );
    });
  }

  Future<void> _scanQr() async {
    final code = await Get.to<String>(() => const _QrScanPage());
    if (code != null) await _report(cluster.addFromQr(code));
  }

  Future<void> _enterIp(BuildContext context) async {
    final input = await showAppSheet<String>(
      context,
      title: 'Enter worker IP',
      subtitle: 'Shown under the worker\'s QR code',
      builder: (_) => const _WorkerIpEntrySheet(),
    );
    if (input != null) await _report(cluster.addManual(input));
  }

  Future<void> _report(Future<String?> adding) async {
    final error = await adding;
    if (error != null) {
      showToast('Couldn\'t add worker', error, tone: ToastTone.error);
    } else {
      showToast('Worker added', 'Used the next time you load a GGUF model.',
          tone: ToastTone.success);
    }
  }
}

class _WorkerIpEntrySheet extends StatefulWidget {
  const _WorkerIpEntrySheet();

  @override
  State<_WorkerIpEntrySheet> createState() => _WorkerIpEntrySheetState();
}

class _WorkerIpEntrySheetState extends State<_WorkerIpEntrySheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: appInputDecoration(context,
              hint: '192.168.1.20:${LlamaCluster.defaultPort}'),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 16),
        PrimaryButton(label: 'Add', onPressed: _submit),
      ],
    );
  }
}

String _gb(num mb) => '${(mb / 1024).toStringAsFixed(1)} GB';

/// How the loaded model is spread across phones: a stacked bar and legend.
class _SplitCard extends StatelessWidget {
  final List<ClusterShare> shares;
  const _SplitCard({required this.shares});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final colors = [
      t.accent,
      t.green,
      t.orange,
      const Color(0xFFAF52DE),
      t.red
    ];
    final total = shares.fold<double>(0, (a, s) => a + s.mb);
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Loaded model', style: t.bodyStrong),
        const SizedBox(height: 2),
        Text('Running on ${shares.length} phones · ${_gb(total)}',
            style: t.caption),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 12,
            child: Row(children: [
              for (var i = 0; i < shares.length; i++)
                Expanded(
                  flex: (shares[i].mb / total * 1000).round().clamp(1, 1000),
                  child: Container(
                    margin:
                        EdgeInsets.only(right: i == shares.length - 1 ? 0 : 2),
                    color: colors[i % colors.length],
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        for (var i = 0; i < shares.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              StatusDot(colors[i % colors.length], size: 10),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  shares[i].isThisPhone
                      ? '${shares[i].name} (this phone)'
                      : shares[i].name,
                  style: t.body,
                ),
              ),
              Text('${(shares[i].mb / total * 100).round()}%',
                  style: t.bodyStrong),
              const SizedBox(width: 10),
              SizedBox(
                width: 58,
                child: Text(_gb(shares[i].mb),
                    textAlign: TextAlign.right, style: t.caption),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(children: [
      Text(value, style: t.bodyStrong),
      const SizedBox(height: 2),
      Text(label, style: t.small, textAlign: TextAlign.center),
    ]);
  }
}

/// Live indicator for an active connection.
class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 56,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Stack(alignment: Alignment.center, children: [
          Container(
            width: 24 + 32 * _c.value,
            height: 24 + 32 * _c.value,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withValues(alpha: 0.35 * (1 - _c.value)),
            ),
          ),
          Container(
            width: 24,
            height: 24,
            decoration:
                BoxDecoration(shape: BoxShape.circle, color: widget.color),
            child: const Icon(Icons.hub_rounded, size: 14, color: Colors.white),
          ),
        ]),
      ),
    );
  }
}

/// Full-screen camera that returns the first QR code it reads.
class _QrScanPage extends StatefulWidget {
  const _QrScanPage();

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  final MobileScannerController _controller =
      MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final value = capture.barcodes
        .map((b) => b.rawValue ?? '')
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (value.isEmpty) return;
    _done = true;
    Get.back(result: value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan worker QR code'),
      ),
      body: Stack(children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 2),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
        const Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: Text(
            'Point at the QR code on the worker phone',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
      ]),
    );
  }
}
