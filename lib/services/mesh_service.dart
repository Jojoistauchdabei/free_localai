// MeshClusterService — the self-healing device mesh that replaces the old
// split master/worker modes.
//
// Every paired device is a node. One node is the master: it hosts the model
// and stitches the model connections (llama.cpp RPC endpoints) together.
// That is all the master is — every node can send prompts, and prompts from
// any node are routed to whichever device currently hosts the model.
//
// Self-healing:
//  • Pairing is persistent — a device that was paired once stays paired.
//  • The first device a user pairs from becomes master automatically.
//  • The master is user-overridable; otherwise it is elected deterministically
//    (earliest-joined node wins), so every node agrees without a vote.
//  • If the master is lost, the next best node claims mastership and reloads
//    the model. If a worker is lost while a model is split, the master
//    re-plans the split over the remaining nodes and reloads the model.
//  • A device connected over mobile data (e.g. Tailscale over WAN) only
//    streams from the models and contributes nothing while the model still
//    fits on the other devices.
//
// All network events are logged and shown in the UI (network analysis).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;
import 'dart:io'
    show
        ContentType,
        File,
        HttpHeaders,
        HttpClient,
        HttpRequest,
        HttpServer,
        HttpClientRequest,
        HttpClientResponse,
        HttpStatus,
        InternetAddress,
        InternetAddressType,
        NetworkInterface,
        Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import 'app_log_service.dart';
import 'cluster_service.dart';
import 'hive_service.dart';
import 'inference_service.dart';
import 'mesh/mesh_logic.dart';
/// One logged network event between mesh devices.
class MeshNetEvent {
  final int tsMs;
  final String kind;
  final String? deviceId;
  final String? deviceName;
  final String message;

  const MeshNetEvent({
    required this.tsMs,
    required this.kind,
    this.deviceId,
    this.deviceName,
    required this.message,
  });

  Map<String, dynamic> toMap() => {
        'ts': tsMs,
        'kind': kind,
        if (deviceId != null) 'id': deviceId,
        if (deviceName != null) 'name': deviceName,
        'msg': message,
      };

  static MeshNetEvent fromMap(Map<dynamic, dynamic> m) => MeshNetEvent(
        tsMs: (m['ts'] as num?)?.toInt() ?? 0,
        kind: (m['kind'] as String?) ?? 'info',
        deviceId: m['id'] as String?,
        deviceName: m['name'] as String?,
        message: (m['msg'] as String?) ?? '',
      );
}

/// Extra mesh state for one paired peer, kept beside ClusterService's
/// ClusterWorker (which holds only RPC fields).
class MeshPeerMeta {
  final String id;
  final String name;
  final String controlEndpoint; // host:port of the peer's control plane
  final int sinceMs;
  final int pairedAtMs;

  const MeshPeerMeta({
    required this.id,
    required this.name,
    required this.controlEndpoint,
    required this.sinceMs,
    required this.pairedAtMs,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'cport': controlEndpoint,
        'since': sinceMs,
        'pairedAt': pairedAtMs,
      };

  static MeshPeerMeta? fromMap(Map<dynamic, dynamic> m) {
    final id = m['id'] as String?;
    final cport = m['cport'] as String?;
    if (id == null || cport == null) return null;
    return MeshPeerMeta(
      id: id,
      name: (m['name'] as String?) ?? id,
      controlEndpoint: cport,
      sinceMs: (m['since'] as num?)?.toInt() ?? 0,
      pairedAtMs: (m['pairedAt'] as num?)?.toInt() ?? 0,
    );
  }

  MeshPeerMeta withControl(String endpoint) => MeshPeerMeta(
      id: id,
      name: name,
      controlEndpoint: endpoint,
      sinceMs: sinceMs,
      pairedAtMs: pairedAtMs);
}

class MeshClusterService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  static bool get isSupported => !kIsWeb && ClusterService.isSupported;

  /// This device's stable mesh id.
  late final String nodeId;
  late final String nodeName;

  /// Cluster on/off. Replaces the old Master/Worker role pick: when on, this
  /// device contributes what it can and takes part in master election.
  final clusterEnabled = false.obs;

  /// Every node this device knows about, including itself.
  final nodes = <MeshNodeInfo>[].obs;

  /// The currently elected/known master. Auto-chosen; user preference wins.
  final masterId = RxnString();

  /// What this device contributes right now, and why.
  final localPolicy = const LocalPolicy(
          contribution: Contribution.none, reason: 'Cluster is off')
      .obs;

  /// This device's own link type (Wi-Fi, Ethernet, Tailscale, mobile…).
  final localLink = LinkType.unknown.obs;

  /// Recent network events between devices (newest first).
  final netEvents = <MeshNetEvent>[].obs;

  /// The node that currently hosts the model, if any (null: nobody known).
  final modelHost = Rxn<MeshNodeInfo>();

  /// True while this device is hosting (being master and holding the model).
  bool get selfHostsModel {
    if (!Get.isRegistered<InferenceService>()) return false;
    final inference = Get.find<InferenceService>();
    return clusterEnabled.value && inference.isModelLoaded.value;
  }

  bool get selfIsMaster => masterId.value == nodeId;

  MeshNodeInfo? get selfNode =>
      nodes.firstWhereOrNull((n) => n.id == nodeId);

  static const defaultControlPort = 50061;
  static const _probeTimeout = Duration(seconds: 2);
  static const _heartbeat = Duration(seconds: 4);
  static const _failoverAfterMisses = 3;
  static const _rebalanceCooldown = Duration(seconds: 30);
  static const _maxNetEvents = 300;

  int get controlPort =>
      int.tryParse(Platform.environment['PRIVATELM_CONTROL_PORT'] ?? '') ??
      defaultControlPort;

  // ── Internals ──────────────────────────────────────────────────────────
  HttpServer? _controlServer;
  Timer? _heartbeatTimer;
  Timer? _rebalanceTimer;
  final _offlineMisses = <String, int>{};
  final _busyServing = false.obs;
  DateTime? _lastRebalanceAt;
  DateTime? _lastFailoverAt;
  DateTime? _lastHandoverAt;
  Map<String, MeshPeerMeta> _peerMeta = {};
  bool _reloading = false;

  /// Nodes learned through announcements or heartbeats (they may not be RPC
  /// workers of ours — e.g. our master). Persisted so elections and
  /// heartbeats survive an app restart.
  Map<String, MeshPeerMeta> _announced = {};

  /// Set when this device should (re)load the model as master: after a
  /// failover claim or a user master pick, so an idle master doesn't
  /// auto-load a model the user never asked for.
  bool _pendingMasterReload = false;

  /// Set when a device was paired during a rebalance cooldown: retry the
  /// rebalance on the next heartbeat so the new device is pulled in.
  bool _rebalancePending = false;

  @override
  void onInit() {
    super.onInit();
    if (!isSupported) return;
    nodeId = Platform.environment['PRIVATELM_NODE_ID'] ??
        _hive.getSetting<String>('mesh_node_id') ??
        const Uuid().v4();
    _hive.setSetting('mesh_node_id', nodeId);
    final cluster = Get.find<ClusterService>();
    final envName = Platform.environment['PRIVATELM_NODE_NAME'];
    nodeName = envName ??
        (cluster.deviceName.isNotEmpty ? cluster.deviceName : 'This device');
    cluster.deviceName = nodeName;

    final log = _hive.getSetting<List>('mesh_netlog') ?? const [];
    netEvents.assignAll(log.whereType<Map>().map(MeshNetEvent.fromMap));

    final savedMeta =
        _hive.getSetting<Map>('mesh_peer_meta') ?? const {};
    _peerMeta = savedMeta.map(
        (k, v) => MapEntry(k.toString(),
            MeshPeerMeta.fromMap((v as Map).cast<String, dynamic>())
                as MeshPeerMeta));
    final savedAnnounced =
        _hive.getSetting<Map>('mesh_announced') ?? const {};
    _announced = {};
    for (final e in savedAnnounced.entries) {
      final meta =
          MeshPeerMeta.fromMap((e.value as Map).cast<String, dynamic>());
      if (meta != null) _announced[e.key.toString()] = meta;
    }
    // Migration from the old Master/Worker switch.
    final wasEnabled =
        _hive.getSetting<bool>('mesh_cluster_enabled') ??
            _hive.getSetting<bool>(AppConstants.keyClusterEnabled) ??
            false;
    if (wasEnabled) {
      unawaited(enableCluster());
    } else {
      _rebuildNodes();
    }
    _refreshLinks();
  }

  @override
  void onClose() {
    _heartbeatTimer?.cancel();
    _rebalanceTimer?.cancel();
    _controlServer?.close(force: true);
    super.onClose();
  }

  // ── Enable / disable ───────────────────────────────────────────────────

  /// Turns the mesh on: starts this device's contribution (RPC worker), the
  /// control plane, and the heartbeat. Pairing data is never touched.
  Future<void> enableCluster() async {
    if (clusterEnabled.value) return;
    clusterEnabled.value = true;
    await _hive.setSetting('mesh_cluster_enabled', true);
    final cluster = Get.find<ClusterService>();
    await _hive.setSetting(AppConstants.keyClusterEnabled, true);
    cluster.enabled.value = true;

    try {
      await _startControlServer();
    } catch (e) {
      _log('error',
          message:
              'Control plane could not start on port $controlPort: $e');
    }
    _refreshLinks();
    _startHeartbeat();

    // Let other devices find this node in pairing codes.
    cluster.meshQrExtras = {
      'nid': nodeId,
      'cport': '$controlPort',
      'mname': nodeName,
    };

    // First node that turns the mesh on is the master until election moves
    // it. This is "the device you pair from is the master".
    if (masterId.value == null) {
      masterId.value = nodeId;
      _log('master', message:
          '${_name(nodeId)} became master (first device in the mesh)');
    }
    _rebuildNodes();

    // Contribute unless we're on a slow link.
    await _applyLocalPolicy();

    // Let the master know we exist (worker side after re-enabling).
    unawaited(_announceToMaster());
    _log('cluster', message: 'Cluster enabled on ${_name(nodeId)}');
  }

  /// Turns the mesh off. Keeps all pairings so devices reconnect by
  /// themselves next time.
  Future<void> disableCluster() async {
    if (!clusterEnabled.value) return;
    clusterEnabled.value = false;
    await _hive.setSetting('mesh_cluster_enabled', false);
    await _hive.setSetting(AppConstants.keyClusterEnabled, false);
    final cluster = Get.find<ClusterService>();
    cluster.enabled.value = false;
    _heartbeatTimer?.cancel();
    _rebalanceTimer?.cancel();
    _controlServer?.close(force: true);
    _controlServer = null;
    masterId.value = null;
    modelHost.value = null;
    nodes.removeWhere((n) => n.id != nodeId);
    await cluster.stopWorker();
    _log('cluster', message: 'Cluster disabled on ${_name(nodeId)}');
    _applyLocalPolicy();
  }

  // ── Master selection ───────────────────────────────────────────────────

  /// User picks a master. Persisted and honoured by election on all nodes
  /// that hear about it (pushed to peers right away).
  Future<void> setPreferredMaster(String id) async {
    await _hive.setSetting('mesh_master_pref', id);
    _log('master', message: '${_name(id)} was chosen as master');
    await _pushMasterChoice(id);
    if (id == nodeId && !selfHostsModel) _pendingMasterReload = true;
    _runElection(reason: 'master chosen by user');
  }

  String? get preferredMaster =>
      _hive.getSetting<String>('mesh_master_pref');

  /// Called by ClusterService after a load planned without this device's
  /// memory (mobile-data policy applied).
  void logContributionDeferred() {
    _log('contribution',
        message:
            'This device only streams from the model — the other devices '
            'carry it');
  }

  // ── Node view ──────────────────────────────────────────────────────────

  void _rebuildNodes() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cluster = Get.find<ClusterService>();
    final hasInference = Get.isRegistered<InferenceService>();
    final inference = hasInference ? Get.find<InferenceService>() : null;
    final self = MeshNodeInfo(
      id: nodeId,
      name: nodeName,
      rpcEndpoint: cluster.worker.value.running
          ? '${_selfLanAddress() ?? ''}:${_workerPort()}'
          : null,
      controlEndpoint: '127.0.0.1:$controlPort',
      isMaster: masterId.value == nodeId,
      modelLoaded: inference?.isModelLoaded.value ?? false,
      modelName: inference == null ||
              inference.loadedModelName.value.isEmpty
          ? null
          : inference.loadedModelName.value,
      state: NodeState.online,
      linkType: localLink.value,
      sinceMs: _sinceMs(),
      pairedAtMs: 0,
      freeRamMb: _freeRamMb(),
    );
    final others = <MeshNodeInfo>[];
    for (final w in cluster.workers) {
      final meta = _metaFor(w);
      final rpc = '${w.host}:${w.port}';
      final known = nodes.firstWhereOrNull((n) => n.rpcEndpoint == rpc);
      others.add(MeshNodeInfo(
        id: meta?.id ?? 'peer-$rpc',
        name: meta?.name ?? w.model ?? w.name,
        rpcEndpoint: rpc,
        controlEndpoint: meta?.controlEndpoint,
        isMaster: false,
        modelLoaded: known?.modelLoaded ?? false,
        modelName: known?.modelName,
        state: known?.state ?? NodeState.unknown,
        linkType: _classifyPeerLink(w.host),
        latencyMs: known?.latencyMs,
        freeRamMb: w.ramMb,
        sinceMs: meta?.sinceMs ?? 0,
        pairedAtMs: meta?.pairedAtMs ?? now,
      ));
    }
    // Keep nodes we know only through announcements or heartbeats (e.g. our
    // master) so heartbeats and elections survive restarts.
    final covered = {nodeId, ...others.map((n) => n.id)};
    for (final meta in _announced.values) {
      if (covered.contains(meta.id)) continue;
      final known = nodes.firstWhereOrNull((n) => n.id == meta.id);
      others.add(MeshNodeInfo(
        id: meta.id,
        name: meta.name,
        controlEndpoint:
            meta.controlEndpoint.isEmpty ? null : meta.controlEndpoint,
        isMaster: meta.id == masterId.value,
        modelLoaded: known?.modelLoaded ?? false,
        modelName: known?.modelName,
        modelPath: known?.modelPath,
        state: known?.state ?? NodeState.unknown,
        linkType: known?.linkType ?? LinkType.unknown,
        latencyMs: known?.latencyMs,
        sinceMs: meta.sinceMs,
        pairedAtMs: meta.pairedAtMs,
      ));
    }
    nodes.assignAll([self, ...others]);
    _updateModelHost();
  }

  /// The node currently hosting the model (master first, any node second).
  void _updateModelHost() {
    MeshNodeInfo? host;
    for (final n in nodes) {
      if (n.online && n.modelLoaded && n.isMaster) host = n;
    }
    host ??= nodes
        .firstWhereOrNull((n) => n.online && n.modelLoaded && n.id != nodeId);
    if (selfHostsModel) {
      final self = nodes.firstWhereOrNull((n) => n.id == nodeId);
      if (self != null && (self.modelLoaded)) host = self;
    }
    modelHost.value = host;
  }

  MeshPeerMeta? _metaFor(dynamic worker) {
    final rpc = '${worker.host}:${worker.port}';
    return _peerMeta[rpc] ??
        (worker.id != null
            ? _peerMeta.values
                .cast<MeshPeerMeta?>()
                .firstWhere((m) => m!.id == worker.id,
                    orElse: () => null)
            : null);
  }

  /// Remembers a node learned outside pairing (announcement, heartbeat) so
  /// restarts and elections still know it.
  void _rememberAnnounced(String id, String name, String? controlEndpoint,
      {int? sinceMs}) {
    if (id.isEmpty || id == nodeId) return;
    final existing = _announced[id];
    _announced[id] = MeshPeerMeta(
      id: id,
      name: name,
      controlEndpoint:
          controlEndpoint ?? existing?.controlEndpoint ?? '',
      sinceMs: (sinceMs != null && sinceMs > 0)
          ? sinceMs
          : existing?.sinceMs ??
              DateTime.now().millisecondsSinceEpoch,
      pairedAtMs: existing?.pairedAtMs ??
          DateTime.now().millisecondsSinceEpoch,
    );
    _hive.setSetting('mesh_announced', {
      for (final e in _announced.entries) e.key: e.value.toMap(),
    });
  }

  String _name(String? id) =>
      id == null
          ? '?'
          : id == nodeId
              ? nodeName
              : nodes.firstWhereOrNull((n) => n.id == id)?.name ?? id;

  int _sinceMs() {
    var since = _hive.getSetting<num>('mesh_since_ms');
    if (since == null || since <= 0) {
      since = DateTime.now().millisecondsSinceEpoch;
      _hive.setSetting('mesh_since_ms', since);
    }
    return since.toInt();
  }

  // ── Pairing hooks (called from ClusterService) ─────────────────────────

  /// The master just paired a new device. Register it, tell it about the
  /// mesh, and log the event. [extras] carries the mesh fields from the
  /// device's QR code (node id + control port).
  Future<void> onPeerPaired({
    required String host,
    required int port,
    String? peerNodeId,
    int? peerControlPort,
    String? peerName,
  }) async {
    final rpc = '$host:$port';
    final cport = peerControlPort ?? defaultControlPort;
    final existing = _peerMeta[rpc];
    final now = DateTime.now().millisecondsSinceEpoch;
    final meta = MeshPeerMeta(
      id: peerNodeId ?? existing?.id ?? 'peer-$rpc',
      name: peerName ?? existing?.name ?? rpc,
      controlEndpoint: '$host:$cport',
      sinceMs: existing?.sinceMs ?? now,
      pairedAtMs: existing?.pairedAtMs ?? now,
    );
    _peerMeta[rpc] = meta;
    await _savePeerMeta();
    _log('paired',
        deviceId: meta.id,
        deviceName: meta.name,
        message: 'Paired with ${meta.name} ($rpc)');
    _rebuildNodes();
    await _announceTo(host, cport);
    _runElection(reason: 'new device paired');
    if (selfIsMaster) {
      await _pushMasterChoice(nodeId);
    }
    // A model is already split? Pull the new device in by re-planning.
    final inference = Get.find<InferenceService>();
    if (selfIsMaster && inference.isModelLoaded.value) {
      if (_cooldownOk(_lastRebalanceAt, _rebalanceCooldown)) {
        _lastRebalanceAt = DateTime.now();
        _log('rebalance',
            message: 'New device ${meta.name} paired — reloading the model to '
                'share the load with it');
        await _reloadModel(reason: 'new device ${meta.name} joined');
      } else {
        // Another rebalance just ran; don't skip the new device — retry on
        // the next heartbeat.
        _rebalancePending = true;
      }
    }
  }

  Future<void> onPeerRemoved(String rpcEndpoint) async {
    final meta = _peerMeta.remove(rpcEndpoint);
    if (meta != null) await _savePeerMeta();
    _log('unpaired',
        deviceId: meta?.id,
        deviceName: meta?.name,
        message: 'Removed ${meta?.name ?? rpcEndpoint} from the mesh');
    _rebuildNodes();
  }

  Future<void> _savePeerMeta() => _hive.setSetting('mesh_peer_meta', {
        for (final e in _peerMeta.entries) e.key: e.value.toMap(),
      });

  // ── Heartbeat ──────────────────────────────────────────────────────────

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeat, (_) => unawaited(_tick()));
  }

  Future<void> _tick() async {
    if (!clusterEnabled.value) return;
    _refreshLinks();
    await _probePeers();
    if (selfIsMaster) {
      await _announceToPeers();
    }
    _runElection(reason: 'heartbeat');
    await _maintainModel();
    _rebuildNodes();
  }

  /// Probes every paired device's RPC and control plane, tracks online /
  /// offline and logs state changes.
  Future<void> _probePeers() async {
    final cluster = Get.find<ClusterService>();
    for (final node in nodes.where((n) => n.id != nodeId).toList()) {
      final rpc = node.rpcEndpoint;
      final info = await _fetchInfo(node.controlEndpoint);
      final online = info != null ||
          (rpc != null && await cluster.probeEndpoint(rpc));
      final previous = node.state;
      final next = online ? NodeState.online : NodeState.offline;
      if (previous != next) {
        node.state = next; // direct write; list refreshed in _rebuildNodes
        nodes.refresh();
        if (next == NodeState.online) {
          _log('online',
              deviceId: node.id,
              deviceName: node.name,
              message:
                  '${node.name} is back online${info != null ? ' (${info['link'] ?? 'unknown link'})' : ''}');
        } else {
          _log('offline',
              deviceId: node.id,
              deviceName: node.name,
              message: '${node.name} went offline');
        }
      }
      if (info != null) {
        final latency = info['latencyMs'];
        if (latency is num && latency > 0) {
          node.latencyMs = latency.toInt();
        }
        if (info['modelLoaded'] == true) node.modelLoaded = true;
        if (info['modelName'] is String) node.modelName = info['modelName'];
        if (info['modelPath'] is String) node.modelPath = info['modelPath'];
        _rememberAnnounced(
            (info['id'] as String?) ?? node.id,
            (info['name'] as String?) ?? node.name,
            node.controlEndpoint,
            sinceMs: (info['sinceMs'] as num?)?.toInt());
        if (info['isMaster'] == true &&
            masterId.value == null) {
          masterId.value = node.id;
        }
      } else {
        node.latencyMs = null;
      }
      _offlineMisses[node.id] = online ? 0 : (_offlineMisses[node.id] ?? 0) + 1;
    }
    // Measuring our own latency to the master for the UI.
    final master = nodes.firstWhereOrNull((n) => n.id == masterId.value);
    if (master != null && master.id != nodeId && master.controlEndpoint != null) {
      final sw = Stopwatch()..start();
      final ok = await _ping(master.controlEndpoint!);
      sw.stop();
      if (ok) master.latencyMs = sw.elapsedMilliseconds;
      nodes.refresh();
    }
  }

  Future<Map<String, dynamic>?> _fetchInfo(String? endpoint) async {
    if (endpoint == null) return null;
    try {
      final client = HttpClient()..connectionTimeout = _probeTimeout;
      final req = await client
          .getUrl(Uri.parse('http://$endpoint/mesh/info'))
          .timeout(_probeTimeout);
      final res = await req.close().timeout(_probeTimeout);
      final body = await res.transform(utf8.decoder).join();
      client.close(force: true);
      if (res.statusCode != 200) return null;
      final map = jsonDecode(body);
      return map is Map<String, dynamic>
          ? map
          : Map<String, dynamic>.from(map as Map);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _ping(String endpoint) async {
    try {
      final client = HttpClient()..connectionTimeout = _probeTimeout;
      final req = await client
          .getUrl(Uri.parse('http://$endpoint/mesh/ping'))
          .timeout(_probeTimeout);
      final res = await req.close().timeout(_probeTimeout);
      await res.drain();
      client.close(force: true);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── Election & self-healing ────────────────────────────────────────────

  /// Deterministic re-election plus failover/rebalance decisions.
  void _runElection({required String reason}) {
    if (!clusterEnabled.value) return;
    final current = masterId.value;
    if (current != null &&
        current != nodeId &&
        preferredMaster == null &&
        _nodeById(current).online) {
      return;
    }
    final previous = masterId.value;
    final elected = MeshLogic.electMaster(
      nodes: nodes,
      selfId: nodeId,
      preferredId: preferredMaster,
      excludedIds: {
        for (final n in nodes)
          if (!_mayHost(n)) n.id,
      },
    );
    if (elected != null && elected != masterId.value) {
      masterId.value = elected;
      if (elected == nodeId &&
          previous != null &&
          previous != nodeId &&
          !selfHostsModel) {
        _pendingMasterReload = false;
        unawaited(_reloadModel(reason: 'failover (master was lost)'));
      }
      _log(elected == nodeId ? 'master' : 'master',
          deviceId: elected,
          deviceName: _name(elected),
          message: elected == nodeId
              ? 'This device took over as master ($reason)'
              : '${_name(elected)} is the master now ($reason)');
    } else if (elected == null && masterId.value != null) {
      _log('offline',
          deviceId: masterId.value,
          deviceName: _name(masterId.value),
          message: 'No online master candidate right now');
    }
  }

  bool _mayHost(MeshNodeInfo node) {
    if (node.id == nodeId) return localPolicy.value.contributes;
    return node.linkType != LinkType.tailscaleMobile &&
        node.linkType != LinkType.cellular;
  }

  /// Master-side maintenance: keep the model healthy across device changes.
  Future<void> _maintainModel() async {
    if (!clusterEnabled.value || _reloading) return;
    final inference = Get.find<InferenceService>();
    final cluster = Get.find<ClusterService>();
    final masterOffline =
        masterId.value != null && !_nodeById(masterId.value).online;

    // ── I am the master ────────────────────────────────────────────────
    if (selfIsMaster) {
      // A worker disappeared while the model is split? Reload the model
      // over the remaining devices (self-healing rebalance).
      final lostWorkers = nodes
          .where((n) =>
              n.id != nodeId &&
              n.rpcEndpoint != null &&
              n.state == NodeState.offline &&
              cluster.workers.any((w) => '${w.host}:${w.port}' == n.rpcEndpoint))
          .toList();
      final holdingModel = inference.isModelLoaded.value;
      final needsRebalance = (holdingModel && lostWorkers.isNotEmpty &&
              cluster.split.isNotEmpty) ||
          (_rebalancePending && holdingModel);
      if (needsRebalance && _cooldownOk(_lastRebalanceAt, _rebalanceCooldown)) {
        _lastRebalanceAt = DateTime.now();
        _rebalancePending = false;
        if (lostWorkers.isNotEmpty) {
          _log('rebalance',
              message:
                  'Reloading the model without ${lostWorkers.map((n) => n.name).join(', ')}');
        }
        await _reloadModel(
            reason: lostWorkers.isNotEmpty
                ? 'rebalance after ${lostWorkers.map((n) => n.name).join(', ')} went offline'
                : 'rebalance to include the newly paired device');
      }
      // The model isn't loaded but this master should host one (it claimed
      // after a failover, or the user picked this device as master): load it.
      if (!holdingModel && !inference.isLoadingModel.value) {
        if (_pendingMasterReload) {
          _pendingMasterReload = false;
          await _reloadModel(reason: 'master reload after takeover');
        }
      }
      return;
    }

    // ── Someone else is master ─────────────────────────────────────────
    // Handover: a new master has the model running — free our copy so the
    // previous host's memory isn't wasted. Chats route to the master.
    if (!selfIsMaster && inference.isModelLoaded.value) {
      final master = _nodeById(masterId.value);
      if (master.online &&
          master.id != nodeId &&
          master.modelLoaded &&
          !inference.isGenerating.value &&
          _cooldownOk(_lastHandoverAt, _rebalanceCooldown)) {
        _lastHandoverAt = DateTime.now();
        _log('rebalance',
            message:
                'Handing the model over to ${master.name} — unloading here');
        await inference.unloadModel();
        _rebuildNodes();
        return;
      }
    }

    if (masterOffline && _cooldownOk(_lastFailoverAt, _rebalanceCooldown)) {
      _lastFailoverAt = DateTime.now();
      final misses = _offlineMisses[masterId.value] ?? 0;
      if (misses >= _failoverAfterMisses) {
        final target = MeshLogic.failoverTarget(
            nodes: nodes, selfId: nodeId, preferredId: preferredMaster);
        if (target == nodeId && _mayHost(selfNode ?? _selfPlaceholder())) {
          _log('failover',
              deviceId: nodeId,
              deviceName: nodeName,
              message: 'Master was lost — this device takes over and '
                  'reloads the model');
          masterId.value = nodeId;
          _pendingMasterReload = true;
          await _reloadModel(reason: 'failover (master was lost)');
        } else if (target != null) {
          _log('failover',
              deviceId: target,
              deviceName: _name(target),
              message:
                  'Master was lost — ${_name(target)} should take over');
        }
      }
    }
  }

  MeshNodeInfo _selfPlaceholder() => MeshNodeInfo(
      id: nodeId,
      name: nodeName,
      state: NodeState.online,
      linkType: localLink.value,
      sinceMs: _sinceMs(),
      pairedAtMs: 0);

  /// A model file this device could load: its own last-used path, or any
  /// online peer's path that also exists on this device (shared disk).
  String? _findReloadableModel() {
    final own = _hive.getSetting<String>(AppConstants.keyLocalModelPath);
    if (own != null && File(own).existsSync()) return own;
    for (final n in nodes.where((n) => n.id != nodeId)) {
      final p = n.modelPath;
      if (p != null && File(p).existsSync()) return p;
    }
    return null;
  }

  bool _cooldownOk(DateTime? last, Duration cooldown) =>
      last == null || DateTime.now().difference(last) > cooldown;

  /// Makes sure the mesh view contains the master as a followable node, even
  /// though it isn't one of this device's RPC workers.
  void _adoptMasterNode(String id, String name, String endpoint) {
    _rememberAnnounced(
        id, name, endpoint == 'unknown' ? null : endpoint);
    final existing = nodes.firstWhereOrNull((n) => n.id == id);
    if (existing != null) {
      existing.name = name;
      if (endpoint != 'unknown') existing.controlEndpoint = endpoint;
      nodes.refresh();
      return;
    }
    nodes.add(MeshNodeInfo(
      id: id,
      name: name,
      controlEndpoint: endpoint == 'unknown' ? null : endpoint,
      state: NodeState.unknown,
      sinceMs: 0,
      pairedAtMs: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  MeshNodeInfo _nodeById(String? id) =>
      nodes.firstWhereOrNull((n) => n.id == id) ??
      MeshNodeInfo(id: '?', name: '?', state: NodeState.offline, sinceMs: 0, pairedAtMs: 0);

  /// Reloads the currently selected model so the new split applies.
  Future<void> _reloadModel({required String reason}) async {
    final inference = Get.find<InferenceService>();
    if (_reloading || inference.isLoadingModel.value) return;
    final path = _findReloadableModel();
    if (path == null) {
      _log('error',
          message:
              'Cannot reload the model ($reason): the model file is not on '
              'this device. Copy it with "Models on LAN" and try again.');
      return;
    }
    _reloading = true;
    try {
      _log('rebalance', message: 'Reloading model ($reason)…');
      final result = await inference.loadModel(path,
          modelName: _hive.getSetting<String>(AppConstants.keyLocalModelName));
      // Judge by the actual state: a failed engine load returns its message,
      // which doesn't necessarily start with "ERROR".
      final ok = inference.isModelLoaded.value;
      _log(ok ? 'rebalance' : 'error',
          message: ok
              ? 'Model reloaded ($reason): ${inference.loadedModelName.value}'
              : 'Model reload failed ($reason): $result');
      if (ok) {
        await _announceToPeers(modelPathOverride: path);
      }
    } catch (e) {
      _log('error', message: 'Model reload failed: $e');
    } finally {
      _reloading = false;
      _rebuildNodes();
    }
  }

  // ── Links (network analysis) ───────────────────────────────────────────

  /// Classifies this device's own network attachment.
  Future<void> _refreshLinks() async {
    var hasWifi = false, hasEthernet = false, hasTailscale = false,
        hasCellular = false;
    String? lanAddress;
    try {
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final i in interfaces) {
        final name = i.name.toLowerCase();
        final addr = i.addresses.isEmpty ? null : i.addresses.first.address;
        if (name.startsWith('lo')) continue;
        if (name.startsWith('tailscale') ||
            name.startsWith('ts') ||
            (addr?.startsWith('100.') ?? false)) {
          hasTailscale = true;
          continue;
        }
        if (name.startsWith('wlan') ||
            name.startsWith('wl') ||
            name.startsWith('en0') && Platform.isIOS) {
          hasWifi = true;
          lanAddress ??= addr;
        } else if (name.startsWith('eth') ||
            name.startsWith('en') ||
            name.startsWith('enp') ||
            name.startsWith('usb')) {
          hasEthernet = true;
          lanAddress ??= addr;
        } else if (name.startsWith('rmnet') ||
            name.startsWith('ccmni') ||
            name.startsWith('pdp') ||
            name.startsWith('wwan')) {
          hasCellular = true;
        } else {
          // Unknown interface (e.g. VPN bridges) — treat as LAN.
          lanAddress ??= addr;
        }
      }
    } catch (_) {}
    _ifaceHasWifi = hasWifi;
    _ifaceHasEthernet = hasEthernet;
    _ifaceHasTailscale = hasTailscale;
    _ifaceHasCellular = hasCellular;
    final mobile = MeshLogic.isMobileLink(
        hasWifi: hasWifi,
        hasEthernet: hasEthernet,
        hasTailscale: hasTailscale,
        hasCellular: hasCellular);
    final next = mobile
        ? (hasTailscale ? LinkType.tailscaleMobile : LinkType.cellular)
        : hasEthernet
            ? LinkType.ethernet
            : hasWifi
                ? LinkType.wifi
                : hasTailscale
                    ? LinkType.tailscale
                    : LinkType.unknown;
    if (localLink.value != next) {
      final label = _linkLabel(next);
      _log('link',
          message: 'This device is connected via $label');
      localLink.value = next;
    } else {
      localLink.value = next;
    }
    final cluster = Get.find<ClusterService>();
    if (lanAddress != null && cluster.wifiAddress.value != lanAddress) {
      cluster.wifiAddress.value = lanAddress;
    }
    unawaited(_applyLocalPolicy());
  }

  LinkType _classifyPeerLink(String host) {
    // CGNAT range: Tailscale node addresses.
    if (host.startsWith('100.')) {
      return MeshLogic.isMobileLink(
              hasWifi: _ifaceHasWifi,
              hasEthernet: _ifaceHasEthernet,
              hasTailscale: _ifaceHasTailscale,
              hasCellular: _ifaceHasCellular)
          ? LinkType.tailscaleMobile
          : LinkType.tailscale;
    }
    return localLink.value == LinkType.tailscaleMobile
        ? LinkType.tailscaleMobile
        : localLink.value;
  }

  bool _ifaceHasWifi = false,
      _ifaceHasEthernet = false,
      _ifaceHasTailscale = false,
      _ifaceHasCellular = false;

  String _linkLabel(LinkType t) => switch (t) {
        LinkType.ethernet => 'Ethernet',
        LinkType.wifi => 'Wi-Fi',
        LinkType.tailscale => 'Tailscale',
        LinkType.tailscaleMobile => 'Tailscale over mobile data',
        LinkType.cellular => 'Mobile data',
        LinkType.unknown => 'an unknown network',
      };

  /// Applies the contribution policy: on a mobile/Tailscale link this device
  /// stops lending compute while the model can still run on the others.
  Future<void> _applyLocalPolicy() async {
    final next = MeshLogic.localPolicy(
        mobileLink: localLink.value == LinkType.tailscaleMobile ||
            localLink.value == LinkType.cellular,
        clusterEnabled: clusterEnabled.value);
    final previous = localPolicy.value;
    localPolicy.value = next;
    if (previous.contribution != next.contribution && clusterEnabled.value) {
      _log('contribution',
          message: next.contributes
              ? 'This device contributes compute again'
              : next.reason);
      await _updateContribution(next.contributes);
    }
  }

  Future<void> _updateContribution(bool contribute) async {
    final cluster = Get.find<ClusterService>();
    if (contribute) {
      if (!cluster.worker.value.running &&
          ClusterService.canBeWorker) {
        await cluster.startWorker();
      }
      if (cluster.localWeight.value == 0) {
        cluster.localWeight.value = 100;
        await _hive.setSetting(
            AppConstants.keyClusterLocalWeight, 100.0);
      }
    } else {
      // Contribute nothing: stop the worker and take no local share, as
      // long as the model still fits without this device (the planner
      // falls back to this device's memory if it wouldn't).
      await cluster.stopWorker();
      cluster.localWeight.value = 0;
      await _hive.setSetting(AppConstants.keyClusterLocalWeight, 0.0);
    }
  }

  String? _selfLanAddress() {
    final cluster = Get.find<ClusterService>();
    return cluster.wifiAddress.value;
  }

  int _workerPort() {
    final envPort =
        int.tryParse(Platform.environment['PRIVATELM_WORKER_PORT'] ?? '');
    return envPort ?? 50052;
  }

  int _freeRamMb() {
    try {
      final cluster = Get.find<ClusterService>();
      final cpu = cluster.localCpuDevice.value;
      return (cpu?.freeMemoryBytes ?? 0) ~/ (1024 * 1024);
    } catch (_) {
      return 0;
    }
  }

  // ── Control plane ──────────────────────────────────────────────────────

  Future<void> _startControlServer() async {
    if (_controlServer != null) return;
    final server = await HttpServer.bind(
        InternetAddress.anyIPv4, controlPort);
    _controlServer = server;
    server.listen(_handleControlRequest, onError: (_) {});
    _log('cluster', message: 'Control plane listening on port $controlPort');
  }

  Future<void> _handleControlRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      switch (path) {
        case '/mesh/info':
        case '/mesh/ping':
          await _json(request, _infoJson());
        case '/mesh/log':
          await _json(request, {
            'events': [
              for (final e in recentEvents(limit: 100)) e.toMap(),
            ],
          });
        case '/mesh/announce':
          await _handleAnnounce(request);
        case '/mesh/set-master':
          await _handleSetMaster(request);
        case '/mesh/pair':
          await _handlePair(request);
        case '/mesh/load':
          await _handleLoad(request);
        case '/mesh/chat':
          await _handleChat(request);
        default:
          await _json(request, {'error': 'not found'},
              status: HttpStatus.notFound);
      }
    } catch (e) {
      try {
        await _json(request, {'error': '$e'},
            status: HttpStatus.internalServerError);
      } catch (_) {}
    }
  }

  Map<String, dynamic> _infoJson() {
    final hasInference = Get.isRegistered<InferenceService>();
    final inference = hasInference ? Get.find<InferenceService>() : null;
    final cluster = Get.find<ClusterService>();
    return {
      'id': nodeId,
      'name': nodeName,
      'master': masterId.value,
      'clusterEnabled': clusterEnabled.value,
      'isMaster': selfIsMaster,
      'modelLoaded': inference?.isModelLoaded.value ?? false,
      'modelName': inference?.loadedModelName.value ?? '',
      'rpcEndpoint': cluster.worker.value.running
          ? '${_selfLanAddress() ?? ''}:${_workerPort()}'
          : null,
      'controlEndpoint': '${_selfLanAddress() ?? '127.0.0.1'}:$controlPort',
      'link': _linkLabel(localLink.value),
      'latencyMs': null,
      'freeRamMb': _freeRamMb(),
      'sinceMs': _sinceMs(),
      'generating': inference?.isGenerating.value ?? false,
      'split': cluster.splitSummary,
      'modelHost': modelHost.value?.controlEndpoint,
      // Where this device's currently selected model file lives. Peers use
      // it after a master failover to reload the model on their side (works
      // on a shared disk, or as a hint for "Models on LAN").
      'modelPath': _modelPath(),
    };
  }

  String? _modelPath() {
    try {
      final inference = Get.find<InferenceService>();
      if (!inference.isModelLoaded.value) return null;
      return _hive.getSetting<String>(AppConstants.keyLocalModelPath);
    } catch (_) {
      return null;
    }
  }

  Future<void> _handleAnnounce(HttpRequest request) async {
    final body = await _readJson(request);
    final senderId = body['id'] as String?;
    final senderName = (body['name'] as String?) ?? senderId ?? 'unknown';
    final senderMaster = body['master'] as String?;
    if (senderId == null) {
      await _json(request, {'error': 'id required'},
          status: HttpStatus.badRequest);
      return;
    }
    final announcedModelPath = body['modelPath'] as String?;
    if (announcedModelPath != null && announcedModelPath.isNotEmpty) {
      await _hive.setSetting(
          AppConstants.keyLocalModelPath, announcedModelPath);
      final announcedModelName = body['modelName'] as String?;
      if (announcedModelName != null && announcedModelName.isNotEmpty) {
        await _hive.setSetting(
            AppConstants.keyLocalModelName, announcedModelName);
      }
    }
    // Learn/refresh the sender.
    _rememberAnnounced(senderId, senderName,
        body['controlEndpoint'] as String?,
        sinceMs: (body['sinceMs'] as num?)?.toInt());
    final known = nodes.firstWhereOrNull((n) => n.id == senderId);
    if (known != null) {
      known.state = NodeState.online;
      known.name = senderName;
      known.modelLoaded = body['modelLoaded'] == true;
      known.modelName = body['modelName'] as String?;
      known.modelPath = body['modelPath'] as String?;
      nodes.refresh();
    } else {
      nodes.add(MeshNodeInfo(
        id: senderId,
        name: senderName,
        state: NodeState.online,
        modelLoaded: body['modelLoaded'] == true,
        modelName: body['modelName'] as String?,
        modelPath: body['modelPath'] as String?,
        sinceMs: (body['sinceMs'] as num?)?.toInt() ?? 0,
        pairedAtMs: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    _log('online',
        deviceId: senderId,
        deviceName: senderName,
        message: '$senderName announced itself');
    // Adopt the sender's master if we don't have one (worker joining a mesh).
    if (senderMaster != null &&
        senderMaster != senderId &&
        senderMaster != nodeId &&
        (masterId.value == null ||
            (masterId.value == nodeId && preferredMaster == null))) {
      masterId.value = senderMaster;
      _log('master',
          deviceId: senderMaster,
          deviceName: _name(senderMaster),
          message: '${_name(senderMaster)} is the master of this mesh');
      _adoptMasterNode(
          senderMaster,
          senderName,
          (body['controlEndpoint'] as String?) ?? 'unknown');
    }
    // Remember where our master's control plane lives so we can announce to
    // it again after a restart.
    final senderEndpoint = body['controlEndpoint'] as String?;
    if (senderMaster == senderId && senderEndpoint != null) {
      await _setMasterEndpoint(senderEndpoint);
    }
    await _json(request, _infoJson());
  }

  Future<void> _handleSetMaster(HttpRequest request) async {
    final body = await _readJson(request);
    final id = body['id'] as String?;
    final by = body['by'] as String?;
    if (id == null) {
      await _json(request, {'error': 'id required'},
          status: HttpStatus.badRequest);
      return;
    }
    await _hive.setSetting('mesh_master_pref', id);
    masterId.value = id;
    if (by != null) {
      final source = nodes.firstWhereOrNull((n) => n.id == by);
      if (source != null) {
        source.modelLoaded = body['modelLoaded'] == true;
        source.modelName = body['modelName'] as String?;
        source.modelPath = body['modelPath'] as String?;
        nodes.refresh();
      }
    }
    _log('master',
        deviceId: id,
        deviceName: _name(id),
        message: '${_name(by)} set ${_name(id)} as master');
    await _pushMasterChoice(id);
    await _json(request, {'ok': true});
  }

  /// Headless helper for tests/automation: pair an RPC endpoint into the mesh.
  Future<void> _handlePair(HttpRequest request) async {
    final body = await _readJson(request);
    final host = body['host'] as String?;
    final port = (body['port'] as num?)?.toInt();
    final id = body['id'] as String?;
    final name = body['name'] as String?;
    final cport = (body['cport'] as num?)?.toInt();
    if (host == null || port == null) {
      await _json(request, {'error': 'host and port required'},
          status: HttpStatus.badRequest);
      return;
    }
    final cluster = Get.find<ClusterService>();
    final error = await cluster.addManual('$host:$port',
        peerNodeId: id, peerControlPort: cport, peerName: name);
    if (error != null) {
      await _json(request, {'error': error},
          status: HttpStatus.badRequest);
      return;
    }
    await _json(request, {'ok': true});
  }

  /// Headless helper for tests/automation: load a GGUF on this device.
  Future<void> _handleLoad(HttpRequest request) async {
    final body = await _readJson(request);
    final path = body['path'] as String?;
    if (path == null || !await File(path).exists()) {
      await _json(request, {'error': 'path required'},
          status: HttpStatus.badRequest);
      return;
    }
    final inference = Get.find<InferenceService>();
    final result = await inference.loadModel(path);
    await _announceToPeers(modelPathOverride: path);
    await _json(request, {
      'ok': !result.startsWith('ERROR'),
      'result': result,
      'loaded': inference.isModelLoaded.value,
      'split': Get.find<ClusterService>().splitSummary,
    });
  }

  /// Streaming chat for other mesh nodes: ndjson token chunks.
  Future<void> _handleChat(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    if (!inference.isModelLoaded.value) {
      await _json(request, {'error': 'no model loaded'},
          status: HttpStatus.serviceUnavailable);
      return;
    }
    if (inference.isGenerating.value || _busyServing.value) {
      await _json(request, {'error': 'model busy'}, status: 429);
      return;
    }
    final body = await _readJson(request);
    final history = [
      for (final m in (body['history'] as List?) ?? const [])
        if (m is Map)
          {
            'role': (m['role'] ?? 'user').toString(),
            'content': (m['content'] ?? '').toString(),
          },
    ];
    final prompt = (body['prompt'] ?? '').toString();
    final systemPrompt = body['systemPrompt']?.toString();
    final maxTokens = (body['maxTokens'] as num?)?.toInt();

    request.response.headers.contentType =
        ContentType('application', 'json');
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    _busyServing.value = true;
    try {
      final text = await inference.generate(
        prompt: prompt,
        systemPrompt: systemPrompt,
        conversationHistory: history,
        source: 'mesh',
        maxTokens: maxTokens,
        onToken: (token) {
          try {
            request.response.add(utf8.encode(
                '${jsonEncode({'t': token})}\n'));
          } catch (_) {}
        },
      );
      try {
        request.response.add(utf8
            .encode('${jsonEncode({'done': true, 'text': text})}\n'));
        await request.response.close();
      } catch (_) {}
      _log('chat',
          message: 'Served a mesh prompt from ${_name(nodeId)}');
    } catch (e) {
      try {
        request.response.add(utf8.encode(
            '${jsonEncode({'error': '$e'})}\n'));
        await request.response.close();
      } catch (_) {}
    } finally {
      _busyServing.value = false;
    }
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    try {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in request.timeout(const Duration(seconds: 5))) {
        builder.add(chunk);
      }
      final body = utf8.decode(builder.takeBytes());
      if (body.isEmpty) return {};
      final decoded = jsonDecode(body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _json(HttpRequest request, Map<String, dynamic> data,
      {int status = HttpStatus.ok}) async {
    request.response.statusCode = status;
    request.response.headers.contentType =
        ContentType('application', 'json');
    request.response.add(utf8.encode(jsonEncode(data)));
    await request.response.close();
  }

  // ── Announcements ──────────────────────────────────────────────────────

  /// Control endpoint of the node we believe is master (persisted, so a
  /// worker can find the master again after an app restart).
  String? get _masterEndpoint =>
      _hive.getSetting<String>('mesh_master_endpoint');

  Future<void> _setMasterEndpoint(String? endpoint) async {
    if (endpoint == null) return;
    await _hive.setSetting('mesh_master_endpoint', endpoint);
  }

  Future<void> _announceToMaster() async {
    final master = _nodeById(masterId.value);
    if (master.id != nodeId) {
      final endpoint = master.controlEndpoint ?? _masterEndpoint;
      if (endpoint != null) await _announceToEndpoint(endpoint);
    }
  }

  Future<void> _announceTo(String host, int port) async {
    await _announceToEndpoint('$host:$port');
  }

  Future<void> _announceToPeers({String? modelPathOverride}) async {
    for (final node in nodes.where((n) => n.id != nodeId)) {
      final endpoint = node.controlEndpoint;
      if (endpoint != null) {
        await _announceToEndpoint(endpoint,
            modelPathOverride: modelPathOverride);
      }
    }
  }

  Future<bool> _announceToEndpoint(String endpoint,
      {String? modelPathOverride}) async {
    try {
      final client = HttpClient()..connectionTimeout = _probeTimeout;
      final req = await client
          .postUrl(Uri.parse('http://$endpoint/mesh/announce'))
          .timeout(_probeTimeout);
      req.add(utf8.encode(jsonEncode({
        'id': nodeId,
        'name': nodeName,
        'master': masterId.value,
        'modelLoaded': Get.find<InferenceService>().isModelLoaded.value,
        'modelPath': modelPathOverride ?? _modelPath(),
        'sinceMs': _sinceMs(),
        'controlEndpoint': '${_selfLanAddress() ?? '127.0.0.1'}:$controlPort',
      })));
      final res = await req.close().timeout(_probeTimeout);
      final body = await res.transform(utf8.decoder).join();
      client.close(force: true);
      if (res.statusCode != 200) return false;
      final info = jsonDecode(body);
      if (info is Map) {
        // Adopt the peer's master when we have none of our own.
        final theirMaster = info['master'] as String?;
        final theirId = info['id'] as String?;
        if (masterId.value == null && theirMaster != null) {
          masterId.value = theirMaster;
          _log('master',
              deviceId: theirMaster,
              deviceName: _name(theirMaster),
              message: 'Joined ${theirId ?? 'the mesh'} — its master '
                  'is ${_name(theirMaster)}');
          _adoptMasterNode(
              theirMaster,
              (info['name'] as String?) ?? theirMaster,
              endpoint);
        }
        // Remember where the master's control plane lives.
        if (theirMaster != null && theirId == theirMaster) {
          await _setMasterEndpoint(endpoint);
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _pushMasterChoice(String id) async {
    for (final node in nodes.where((n) => n.id != nodeId)) {
      final endpoint = node.controlEndpoint;
      if (endpoint == null) continue;
      try {
        final client = HttpClient()..connectionTimeout = _probeTimeout;
        final req = await client
            .postUrl(Uri.parse('http://$endpoint/mesh/set-master'))
            .timeout(_probeTimeout);
        final inference = Get.find<InferenceService>();
        req.add(utf8.encode(jsonEncode({
          'id': id,
          'by': nodeId,
          'modelLoaded': inference.isModelLoaded.value,
          'modelName': inference.loadedModelName.value,
          'modelPath': _modelPath(),
        })));
        final res = await req.close().timeout(_probeTimeout);
        await res.drain();
        client.close(force: true);
      } catch (_) {}
    }
  }

  // ── Chat from any node ─────────────────────────────────────────────────

  /// The control endpoint of the node currently hosting the model, or null.
  String? get chatTargetEndpoint {
    if (selfHostsModel) return null; // local generation is faster
    final host = modelHost.value;
    if (host != null && host.id != nodeId && host.online) {
      return host.controlEndpoint;
    }
    return null;
  }

  /// Streams a prompt to the node hosting the model. Follows a master
  /// failover once: if the host is lost mid-generation the mesh has usually
  /// already elected a new one, and this retries there.
  Future<String> generateRemote({
    required String prompt,
    String? systemPrompt,
    List<Map<String, String>>? conversationHistory,
    int? maxTokens,
    void Function(String token)? onToken,
  }) async {
    final buffer = StringBuffer();
    for (var attempt = 0; attempt < 2; attempt++) {
      final target = chatTargetEndpoint;
      if (target == null) {
        throw Exception('No mesh device currently hosts a model');
      }
      try {
        await for (final chunk
            in _streamChat(target, prompt, systemPrompt, conversationHistory, maxTokens)) {
          final decoded = _decodeChunk(chunk);
          if (decoded == null) continue;
          final token = decoded.token;
          if (token != null) {
            buffer.write(token);
            onToken?.call(token);
          } else if (decoded.error != null) {
            throw Exception(decoded.error);
          } else if (decoded.doneText != null) {
            if (buffer.isEmpty) {
              buffer.write(decoded.doneText!);
              onToken?.call(decoded.doneText!);
            }
          }
        }
        return buffer.toString();
      } catch (e) {
        _log('chat',
            message: 'Mesh chat failed (${e.toString().split('\n').first}); '
                'looking for the next host…');
        await _probePeers();
        if (attempt == 1) rethrow;
      }
    }
    return buffer.toString();
  }

  Stream<String> _streamChat(
      String endpoint,
      String prompt,
      String? systemPrompt,
      List<Map<String, String>>? history,
      int? maxTokens) async* {
    final client = HttpClient();
    try {
      final req = await client
          .postUrl(Uri.parse('http://$endpoint/mesh/chat'))
          .timeout(_probeTimeout);
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({
        'prompt': prompt,
        if (systemPrompt != null) 'systemPrompt': systemPrompt,
        if (history != null)
          'history': [for (final m in history) {'role': m['role'], 'content': m['content']}],
        if (maxTokens != null) 'maxTokens': maxTokens,
      })));
      final res = await req.close().timeout(const Duration(minutes: 10));
      if (res.statusCode != 200) {
        final body = await res.transform(utf8.decoder).join();
        throw Exception('Host refused the prompt ($body)');
      }
      final lineBuffer = StringBuffer();
      await for (final chunk
          in res.transform(utf8.decoder).transform(const LineSplitter())) {
        yield chunk;
        lineBuffer.clear();
      }
    } finally {
      client.close(force: true);
    }
  }

  _ChatChunk? _decodeChunk(String line) {
    if (line.trim().isEmpty) return null;
    try {
      final map = jsonDecode(line);
      if (map is! Map) return null;
      final t = map['t'] as String?;
      final err = map['error'] as String?;
      final text = map['text'] as String?;
      final done = map['done'] == true;
      if (t != null) return _ChatChunk(token: t);
      if (err != null) return _ChatChunk(error: err);
      if (done) return _ChatChunk(doneText: text);
    } catch (_) {}
    return null;
  }

  // ── Logging ────────────────────────────────────────────────────────────

  void _log(String kind,
      {String? deviceId, String? deviceName, required String message}) {
    final event = MeshNetEvent(
      tsMs: DateTime.now().millisecondsSinceEpoch,
      kind: kind,
      deviceId: deviceId,
      deviceName: deviceName,
      message: message,
    );
    netEvents.insert(0, event);
    if (netEvents.length > _maxNetEvents) {
      netEvents.removeRange(_maxNetEvents, netEvents.length);
    }
    _hive.setSetting(
        'mesh_netlog', [for (final e in netEvents) e.toMap()]);
    Get.find<AppLogService>().info('[Mesh] $message');
  }

  /// Network analysis for the UI: recent events, grouped.
  List<MeshNetEvent> recentEvents({int limit = 30}) =>
      netEvents.take(limit).toList();
}

class _ChatChunk {
  final String? token;
  final String? error;
  final String? doneText;
  const _ChatChunk({this.token, this.error, this.doneText});
}
