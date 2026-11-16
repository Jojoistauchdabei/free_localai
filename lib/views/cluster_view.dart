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
import '../services/mesh/mesh_logic.dart';
import '../services/mesh_service.dart';

/// Device mesh: all paired devices are equal nodes. One node is the master
/// (it hosts the model and stitches the model connections together) — chosen
/// automatically, changeable, and handed over on its own when it is lost.
/// Every node can send prompts; chats always reach whichever device hosts
/// the model.
class ClusterView extends StatefulWidget {
  const ClusterView({super.key});

  @override
  State<ClusterView> createState() => _ClusterViewState();
}

class _ClusterViewState extends State<ClusterView> {
  final ClusterService cluster = Get.find<ClusterService>();
  late final MeshClusterService mesh;
  Timer? _wifiTimer;

  @override
  void initState() {
    super.initState();
    mesh = Get.find<MeshClusterService>();
    cluster.refreshWorkerStatus();
    cluster.refreshWifiAddress();
    cluster.refreshLocalCpuDevice();
    cluster.refreshLocalMetrics();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(cluster.refreshLocalGpuDevices());
    });
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
      appBar: appScreenBar(context, title: 'Device mesh', showBack: true),
      body: Obx(() {
        final on = mesh.clusterEnabled.value;
        return ListView(
          padding: kPagePadding,
          children: [
            const SizedBox(height: 8),
            AppSegmented<bool>(
              items: const [(false, 'Off'), (true, 'Connected')],
              selected: on,
              onChanged: (value) => value
                  ? mesh.enableCluster()
                  : mesh.disableCluster(),
            ),
            const SizedBox(height: 16),
            if (on && cluster.wifiAddress.value == null) ...[
              AppNotice(
                'Turn on Wi-Fi. All devices in the mesh must be reachable over '
                'the network (same Wi-Fi, or Tailscale).',
                icon: Icons.wifi_off_rounded,
                color: t.orange,
              ),
              const SizedBox(height: 16),
            ],
            const SizedBox(height: 16),
            // This PC's own hardware: always visible, independent of the
            // mesh being on or off.
            if (cluster.localGpuDevices.isNotEmpty ||
                cluster.localCpuDevice.value != null) ...[
              SectionHeader('Dieser PC · Geräte (eigene Worker)'),
              _thisPcDevicesCard(context),
              const SizedBox(height: 16),
            ],
            if (on) ...[
              _selfCard(context),
              const SizedBox(height: 16),
              if (cluster.split.length > 1) ...[
                _SplitCard(shares: cluster.split),
                const SizedBox(height: 16),
              ],
              _nodesSection(context),
              const SizedBox(height: 16),
              _networkCard(context),
              const SizedBox(height: 16),
              _pairingSection(context),
            ] else ...[
              AppNotice(
                'Pair devices once and they stay paired. The first device you '
                'pair from becomes the master and hosts the model; every '
                'device can send prompts, and if a device — even the master — '
                'is lost, the mesh reloads the model on the rest by itself.',
                icon: Icons.hub_outlined,
              ),
            ],
            if (on && Get.isRegistered<LanModelShareService>()) ...[
              const SizedBox(height: 16),
              _lanModelsSection(context, Get.find<LanModelShareService>()),
            ],
            const SizedBox(height: 24),
            SectionFootnote(
              'Devices communicate over the llama.cpp RPC link plus a small '
              'mesh control channel. Changes apply on the next model load; '
              'the mesh reloads models on its own when devices come or go.',
            ),
          ],
        );
      }),
    );
  }

  // ── This device ──────────────────────────────────────────────────────

  Widget _selfCard(BuildContext context) {
    final t = AppTokens.of(context);
    final policy = mesh.localPolicy.value;
    final role = mesh.selfIsMaster ? 'Master' : 'Node';
    final inference = Get.find<InferenceService>();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(
              mesh.selfIsMaster
                  ? Icons.dns_rounded
                  : Icons.smartphone_rounded,
              color: t.accent,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${mesh.nodeName} (this device)',
                        style: t.bodyStrong),
                    Text(
                      '$role · ${_linkLabel(mesh.localLink.value)}'
                      '${cluster.worker.value.running ? ' · contributing' : ''}'
                      '${inference.isModelLoaded.value ? ' · hosting the model' : ''}',
                      style: t.caption,
                    ),
                  ]),
            ),
            StatusDot(t.green, size: 10),
          ]),
          if (policy.contribution == Contribution.none &&
              mesh.clusterEnabled.value) ...[
            const SizedBox(height: 10),
            Text(policy.reason, style: t.caption.copyWith(color: t.orange)),
          ],
          const SizedBox(height: 10),
          Text(
            'Auto mode: the mesh picks the master, moves it when a device is '
            'lost, and reloads the model over the remaining devices. You can '
            'pin a master below.',
            style: t.small,
          ),
        ],
      ),
    );
  }

  // ── Nodes ────────────────────────────────────────────────────────────

  Widget _nodesSection(BuildContext context) {
    final t = AppTokens.of(context);
    final nodes = mesh.nodes.toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader('Devices (${nodes.length})'),
      AppGroup(dividerIndent: 56, children: [
        for (final node in nodes)
          AppRow(
            icon: node.id == mesh.nodeId
                ? Icons.computer_rounded
                : Icons.smartphone_rounded,
            title: node.isMaster ? '${node.name} · Master' : node.name,
            subtitle: [
              if (node.id != mesh.nodeId) _stateLabel(node.state),
              if (node.latencyMs != null) '${node.latencyMs} ms',
              _linkLabel(node.linkType),
              if (node.modelLoaded) 'hosts model',
              if (node.id != mesh.nodeId && node.rpcEndpoint != null)
                node.rpcEndpoint!,
            ].join(' · '),
            trailing: node.id == mesh.nodeId
                ? null
                : Icon(Icons.more_vert_rounded, color: t.muted),
            onTap: node.id == mesh.nodeId ? null : () => _nodeSheet(node),
          ),
      ]),
    ]);
  }

  Future<void> _nodeSheet(MeshNodeInfo node) async {
    final action = await showAppSheet<String>(
      context,
      title: node.name,
      subtitle: [
        _stateLabel(node.state),
        if (node.latencyMs != null) '${node.latencyMs} ms',
        _linkLabel(node.linkType),
      ].join(' · '),
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!node.isMaster)
            PrimaryButton(
              label: 'Make master',
              icon: Icons.dns_rounded,
              onPressed: () => Navigator.pop(ctx, 'master'),
            ),
          if (!node.isMaster) const SizedBox(height: 10),
          TonalButton.neutral(
            ctx,
            label: 'Remove device',
            onTap: () => Navigator.pop(ctx, 'remove'),
          ),
        ],
      ),
    );
    if (action == 'master') {
      await mesh.setPreferredMaster(node.id);
      if (mounted) {
        showToast('Master set',
            '${node.name} hosts the model for the whole mesh.',
            tone: ToastTone.success);
      }
    } else if (action == 'remove') {
      final w = Get.find<ClusterService>().workers.firstWhereOrNull(
          (w) => '${w.host}:${w.port}' == node.rpcEndpoint);
      if (w != null) await cluster.remove(w);
    }
  }

  // ── Network analysis ─────────────────────────────────────────────────

  Widget _networkCard(BuildContext context) {
    final t = AppTokens.of(context);
    final events = mesh.recentEvents(limit: 12);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.monitor_heart_outlined, color: t.accent),
            const SizedBox(width: 10),
            Expanded(
                child: Text('Network analysis', style: t.bodyStrong)),
            Text(_linkLabel(mesh.localLink.value), style: t.caption),
          ]),
          const SizedBox(height: 10),
          if (events.isEmpty)
            Text('No network events yet.', style: t.caption)
          else
            for (final e in events)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  StatusDot(_eventColor(t, e.kind), size: 8),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(e.message, style: t.caption, maxLines: 2),
                  ),
                  Text(_timeOf(e.tsMs), style: t.small),
                ]),
              ),
        ],
      ),
    );
  }

  Color _eventColor(AppTokens t, String kind) => switch (kind) {
        'online' || 'paired' || 'master' || 'rebalance' => t.green,
        'offline' || 'error' => t.red,
        _ => t.muted,
      };

  String _timeOf(int tsMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(tsMs);
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  // ── Pairing ──────────────────────────────────────────────────────────

  Widget _pairingSection(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader('Pair a device'),
      PrimaryButton(
        label: 'Scan a device\'s QR code',
        icon: Icons.qr_code_scanner_rounded,
        onPressed: _scanQr,
      ),
      const SizedBox(height: 10),
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
      const SizedBox(height: 12),
      // The old worker view: this device's own QR code, so another device
      // (usually the first-paired master) can pair it.
      _ownQrCard(context),
    ]);
  }

  /// This PC's hardware, shown as separate worker devices: every GPU, the
  /// integrated GPU (its memory is system RAM) and the CPU with a
  /// configurable core count.
  Widget _thisPcDevicesCard(BuildContext context) {
    final t = AppTokens.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Jedes Gerät zählt als eigener Worker: dedizierte GPU, zweite '
            'GPU, integrierte Grafik und CPU werden getrennt geführt. '
            'Aktiviere mehrere Geräte, um ein Modell auf alle zu verteilen.',
            style: t.caption,
          ),
          const SizedBox(height: 8),
          Row(children: [
            PillButton(
              label: 'Nur schnellste',
              icon: Icons.speed_rounded,
              onPressed: cluster.autoSelectLocalGpus,
            ),
            const SizedBox(width: 8),
            PillButton(
              label: 'Alle',
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
              secondary: Icon(gpu.isIntegrated
                  ? Icons.developer_board_rounded
                  : Icons.videogame_asset_rounded),
              title: Text(gpu.isIntegrated
                  ? '${gpu.name} · integrierte Grafik'
                  : gpu.name),
              subtitle: Text(
                [
                  '${_gb(gpu.freeMemoryBytes / (1024 * 1024))} frei von '
                  '${_gb(gpu.totalMemoryBytes / (1024 * 1024))}'
                  ' · ${gpu.totalMemoryBytes > 0 ? ((1 - gpu.freeMemoryBytes / gpu.totalMemoryBytes) * 100).round() : 0}% belegt',
                  if (gpu.memorySpeedGbps > 0)
                    '${gpu.memorySpeedGbps.toStringAsFixed(1)} GB/s',
                  if (gpu.isIntegrated) 'nutzt System-RAM',
                ].join(' · '),
              ),
            ),
          if (cluster.localCpuDevice.value != null) ...[
            const Divider(height: 24),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.memory_rounded),
              title: Text('CPU · ${cluster.localCpuDevice.value!.name}'),
              subtitle: Text(
                [
                  'System-RAM gesamt: '
                      '${_gb(cluster.localCpuDevice.value!.totalMemoryBytes / (1024 * 1024))}',
                  if (cluster.localCpuDevice.value!.integratedGpuMemoryBytes >
                      0)
                    'davon integrierte Grafik: '
                        '${_gb(cluster.localCpuDevice.value!.integratedGpuMemoryBytes / (1024 * 1024))} (abgezogen)',
                  '${_gb(cluster.localCpuDevice.value!.usableMemoryBytes / (1024 * 1024))} für die CPU frei'
                      ' · '
                      '${cluster.localCpuDevice.value!.effectiveCores} von '
                      '${cluster.localCpuDevice.value!.logicalCores} Kernen'
                      ' · '
                      '${cluster.localCpuDevice.value!.computeTops.toStringAsFixed(3)} TOPS',
                ].join('\n'),
              ),
            ),
            Row(children: [
              SizedBox(
                width: 110,
                child: Text(
                  'CPU-Kerne: '
                      '${cluster.localCpuDevice.value!.effectiveCores} / '
                      '${cluster.localCpuDevice.value!.logicalCores}',
                  style: t.caption,
                ),
              ),
              Expanded(
                child: Slider(
                  value: cluster.localCpuDevice.value!.effectiveCores
                      .clamp(1, cluster.localCpuDevice.value!.logicalCores)
                      .toDouble(),
                  min: 1,
                  max: cluster.localCpuDevice.value!.logicalCores.toDouble(),
                  divisions: cluster.localCpuDevice.value!.logicalCores > 1
                      ? cluster.localCpuDevice.value!.logicalCores - 1
                      : null,
                  label:
                      '${cluster.localCpuDevice.value!.effectiveCores} Kerne',
                  onChanged: (value) => cluster.setCpuThreads(value.round()),
                ),
              ),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _ownQrCard(BuildContext context) {
    final t = AppTokens.of(context);
    final qr = cluster.workerQrData;
    final running = cluster.worker.value.running;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('This device\'s code', style: t.bodyStrong),
          const SizedBox(height: 4),
          Text(
            running && qr != null
                ? 'Scan this from another device to pair it here.'
                : 'Start contributing (pair with any mesh) to show a code. '
                    'Open the mesh on this device, then pair from the other '
                    'device.',
            style: t.caption,
          ),
          if (running && qr != null) ...[
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: QrImageView(
                    data: qr, size: 180, padding: EdgeInsets.zero),
              ),
            ),
            const SizedBox(height: 8),
            Center(
                child: Text('Ready · ${cluster.wifiAddress.value}',
                    style: t.caption)),
          ],
        ],
      ),
    );
  }

  Future<void> _scanQr() async {
    final code = await Get.to<String>(() => const _QrScanPage());
    if (code != null) await _report(cluster.addFromQr(code));
  }

  Future<void> _enterIp(BuildContext context) async {
    final input = await showAppSheet<String>(
      context,
      title: 'Enter device IP',
      subtitle: 'Shown under the other device\'s QR code',
      builder: (_) => const _WorkerIpEntrySheet(),
    );
    if (input != null) await _report(cluster.addManual(input));
  }

  Future<void> _report(Future<String?> adding) async {
    final error = await adding;
    if (error != null) {
      showToast('Couldn\'t add device', error, tone: ToastTone.error);
    } else {
      showToast('Device paired',
          'It stays paired and joins the model on the next load.',
          tone: ToastTone.success);
    }
  }

  String _stateLabel(NodeState state) => switch (state) {
        NodeState.online => 'online',
        NodeState.offline => 'offline',
        NodeState.unknown => 'looking…',
      };

  String _linkLabel(LinkType t) => switch (t) {
        LinkType.ethernet => 'Ethernet',
        LinkType.wifi => 'Wi-Fi',
        LinkType.tailscale => 'Tailscale',
        LinkType.tailscaleMobile => 'Tailscale · mobile data',
        LinkType.cellular => 'Mobile data',
        LinkType.unknown => 'unknown link',
      };

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

/// How the loaded model is spread across devices: a stacked bar and legend.
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
        Text('Running on ${shares.length} devices · ${_gb(total)}',
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
                      ? '${shares[i].name} (this device)'
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
        title: const Text('Scan device QR code'),
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
            'Point at the QR code on the other device',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
      ]),
    );
  }
}
