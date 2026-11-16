// Pure mesh decision logic — no Flutter, no GetX, no I/O. Everything here is
// driven by plain values so it can be unit-tested with fakes and reused by the
// MeshClusterService and the headless test driver.
library;

/// How a device is attached to the network.
enum LinkType { unknown, ethernet, wifi, tailscale, tailscaleMobile, cellular }

/// Health of a node as seen from this device.
enum NodeState { unknown, online, offline }

/// Why a node is or isn't allowed to contribute compute to the cluster.
enum Contribution {
  /// Lends memory/GPU like any other node.
  full,

  /// Connected over a slow/expensive link (e.g. Tailscale over mobile data):
  /// consumes model streams but lends nothing, as long as the model still
  /// fits on the remaining devices.
  none,
}

/// Everything the mesh knows about one device, including this one.
class MeshNodeInfo {
  final String id;

  /// Live-updated by probing and announcements; mutable so the heartbeat can
  /// refresh in place.
  String name;
  String? rpcEndpoint; // host:port of the llama.cpp RPC worker
  String? controlEndpoint; // host:port of the mesh control plane
  final bool isMaster;

  /// Live-updated by probing; mutable so the heartbeat can refresh in place.
  bool modelLoaded;
  String? modelName;

  /// Where this node's selected model file lives (used after a master
  /// failover so another node can reload the model).
  String? modelPath;
  NodeState state;
  LinkType linkType;
  int? latencyMs;
  final int? freeRamMb;
  final int sinceMs; // when this node first joined a mesh (deterministic election tie-break)
  final int pairedAtMs; // when this node was paired with the observer

  MeshNodeInfo({
    required this.id,
    required this.name,
    this.rpcEndpoint,
    this.controlEndpoint,
    this.isMaster = false,
    this.modelLoaded = false,
    this.modelName,
    this.modelPath,
    this.state = NodeState.unknown,
    this.linkType = LinkType.unknown,
    this.latencyMs,
    this.freeRamMb,
    required this.sinceMs,
    required this.pairedAtMs,
  });

  bool get online => state == NodeState.online;

  MeshNodeInfo copyWith({
    String? rpcEndpoint,
    String? controlEndpoint,
    bool? isMaster,
    bool? modelLoaded,
    String? modelName,
    NodeState? state,
    LinkType? linkType,
    int? latencyMs,
    int? freeRamMb,
  }) =>
      MeshNodeInfo(
        id: id,
        name: name,
        rpcEndpoint: rpcEndpoint ?? this.rpcEndpoint,
        controlEndpoint: controlEndpoint ?? this.controlEndpoint,
        isMaster: isMaster ?? this.isMaster,
        modelLoaded: modelLoaded ?? this.modelLoaded,
        modelName: modelName ?? this.modelName,
        modelPath: modelPath ?? this.modelPath,
        state: state ?? this.state,
        linkType: linkType ?? this.linkType,
        latencyMs: latencyMs ?? this.latencyMs,
        freeRamMb: freeRamMb ?? this.freeRamMb,
        sinceMs: sinceMs,
        pairedAtMs: pairedAtMs,
      );
}

/// What the local device contributes, decided from its own link.
class LocalPolicy {
  final Contribution contribution;
  final String reason;

  const LocalPolicy({required this.contribution, required this.reason});

  bool get contributes => contribution == Contribution.full;
}

class MeshLogic {
  /// Whether this device is connected over a slow/expensive transport. A
  /// Tailscale interface with no Wi-Fi/Ethernet underneath means the mesh
  /// traffic rides mobile data.
  static bool isMobileLink({
    required bool hasWifi,
    required bool hasEthernet,
    required bool hasTailscale,
    required bool hasCellular,
  }) {
    if (hasWifi || hasEthernet) return false;
    return hasTailscale || hasCellular;
  }

  /// Policy for this device's own contribution.
  static LocalPolicy localPolicy({
    required bool mobileLink,
    required bool clusterEnabled,
  }) {
    if (!clusterEnabled) {
      return const LocalPolicy(
          contribution: Contribution.none, reason: 'Cluster is off');
    }
    if (mobileLink) {
      return const LocalPolicy(
        contribution: Contribution.none,
        reason:
            'Connected over mobile data (Tailscale) — streaming only, not '
            'contributing, while the model still fits on the other devices',
      );
    }
    return const LocalPolicy(
        contribution: Contribution.full, reason: 'Local link');
  }

  /// Deterministic master election over the nodes a device knows about.
  ///
  /// 1. An explicitly user-chosen master wins (if online).
  /// 2. Otherwise the node that joined a mesh earliest wins ("the first
  ///    device you pair with is the master").
  /// 3. Ties break on the node id, so every node picks the same winner
  ///    without talking to each other.
  /// 4. Offline nodes are skipped; [preferredId] marks the user's choice;
  ///    [excludedIds] marks nodes that must not host (e.g. mobile links).
  static String? electMaster({
    required List<MeshNodeInfo> nodes,
    required String selfId,
    String? preferredId,
    Set<String> excludedIds = const {},
  }) {
    final candidates = nodes
        .where((n) =>
            n.id.isNotEmpty && n.online && !excludedIds.contains(n.id))
        .toList();
    if (candidates.isEmpty) return null;
    MeshNodeInfo? winner;
    if (preferredId != null) {
      winner =
          candidates.firstWhereOrNull((n) => n.id == preferredId);
    }
    winner ??= candidates.reduce((a, b) {
      if (a.sinceMs != b.sinceMs) return a.sinceMs < b.sinceMs ? a : b;
      return a.id.compareTo(b.id) < 0 ? a : b;
    });
    return winner.id;
  }

  /// The next node that should host the model, given the current view.
  /// Used when the master is lost. Mobile-linked nodes are excluded so the
  /// model doesn't land behind an expensive link, unless nothing else is
  /// left and [allowMobileFallback] is set.
  static String? failoverTarget({
    required List<MeshNodeInfo> nodes,
    required String selfId,
    String? preferredId,
  }) {
    final nonMobile = electMaster(
      nodes: nodes,
      selfId: selfId,
      preferredId: preferredId,
      excludedIds: {
        for (final n in nodes)
          if (n.linkType == LinkType.tailscaleMobile ||
              n.linkType == LinkType.cellular)
            n.id,
      },
    );
    return nonMobile ?? electMaster(nodes: nodes, selfId: selfId, preferredId: preferredId);
  }

  /// Nodes that should carry the model after a device disappears: every
  /// online, contributing node. The caller re-plans the split over these.
  static List<MeshNodeInfo> rebalanceCandidates(
      List<MeshNodeInfo> nodes) {
    return [
      for (final n in nodes)
        if (n.online &&
            n.linkType != LinkType.tailscaleMobile &&
            n.linkType != LinkType.cellular)
          n,
    ];
  }
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
