import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/mesh/mesh_logic.dart';

MeshNodeInfo node(
  String id, {
  bool online = true,
  int sinceMs = 0,
  LinkType link = LinkType.wifi,
  bool modelLoaded = false,
  bool isMaster = false,
}) =>
    MeshNodeInfo(
      id: id,
      name: id,
      state: online ? NodeState.online : NodeState.offline,
      linkType: link,
      modelLoaded: modelLoaded,
      isMaster: isMaster,
      sinceMs: sinceMs,
      pairedAtMs: 0,
    );

void main() {
  group('master election', () {
    test('earliest-joined node wins (first paired device is master)', () {
      final masterId = MeshLogic.electMaster(
        nodes: [
          node('b', sinceMs: 200),
          node('a', sinceMs: 100),
          node('c', sinceMs: 300),
        ],
        selfId: 'c',
      );
      expect(masterId, 'a');
    });

    test('offline nodes are skipped', () {
      final masterId = MeshLogic.electMaster(
        nodes: [
          node('a', sinceMs: 100, online: false),
          node('b', sinceMs: 500),
        ],
        selfId: 'b',
      );
      expect(masterId, 'b');
    });

    test('user preference wins over join order', () {
      final masterId = MeshLogic.electMaster(
        nodes: [
          node('a', sinceMs: 100),
          node('b', sinceMs: 500),
        ],
        selfId: 'a',
        preferredId: 'b',
      );
      expect(masterId, 'b');
    });

    test('ties break deterministically on id', () {
      final a = MeshLogic.electMaster(
          nodes: [node('b', sinceMs: 100), node('a', sinceMs: 100)],
          selfId: 'a');
      final b = MeshLogic.electMaster(
          nodes: [node('a', sinceMs: 100), node('b', sinceMs: 100)],
          selfId: 'b');
      expect(a, 'a');
      expect(b, 'a');
    });

    test('excluded (mobile) nodes never host while others are online', () {
      final masterId = MeshLogic.electMaster(
        nodes: [
          node('phone', sinceMs: 100, link: LinkType.tailscaleMobile),
          node('pc', sinceMs: 500),
        ],
        selfId: 'phone',
        excludedIds: {'phone'},
      );
      expect(masterId, 'pc');
    });

    test('all nodes agree without talking to each other', () {
      final view = [
        node('n1', sinceMs: 1000),
        node('n2', sinceMs: 2000),
        node('n3', sinceMs: 3000),
      ];
      expect(
        MeshLogic.electMaster(nodes: view, selfId: 'n1'),
        MeshLogic.electMaster(nodes: view, selfId: 'n2'),
      );
    });
  });

  group('failover', () {
    test('mobile-linked nodes are excluded first, used as last resort', () {
      final nodes = [
        node('lost-master', sinceMs: 100, online: false),
        node('mobile', sinceMs: 200, link: LinkType.tailscaleMobile),
        node('desktop', sinceMs: 300),
      ];
      expect(
        MeshLogic.failoverTarget(nodes: nodes, selfId: 'mobile'),
        'desktop',
      );
      // Nothing but the mobile node left → it still takes over so chats keep
      // working.
      final onlyMobile = [
        node('mobile', sinceMs: 200, link: LinkType.tailscaleMobile),
      ];
      expect(
        MeshLogic.failoverTarget(nodes: onlyMobile, selfId: 'mobile'),
        'mobile',
      );
    });
  });

  group('rebalance', () {
    test('only online, non-mobile nodes carry the model', () {
      final candidates = MeshLogic.rebalanceCandidates([
        node('a'),
        node('b', online: false),
        node('c', link: LinkType.tailscaleMobile),
      ]);
      expect(candidates.map((n) => n.id), ['a']);
    });
  });

  group('mobile-data policy (Tailscale over WAN)', () {
    test('tailscale without wifi/ethernet is mobile data', () {
      expect(
        MeshLogic.isMobileLink(
            hasWifi: false,
            hasEthernet: false,
            hasTailscale: true,
            hasCellular: false),
        isTrue,
      );
      expect(
        MeshLogic.isMobileLink(
            hasWifi: true,
            hasEthernet: false,
            hasTailscale: true,
            hasCellular: false),
        isFalse,
      );
      expect(
        MeshLogic.isMobileLink(
            hasWifi: false,
            hasEthernet: true,
            hasTailscale: true,
            hasCellular: false),
        isFalse,
      );
      expect(
        MeshLogic.isMobileLink(
            hasWifi: false,
            hasEthernet: false,
            hasTailscale: false,
            hasCellular: true),
        isTrue,
      );
    });

    test('cluster on a wifi link contributes fully', () {
      final policy = MeshLogic.localPolicy(
          mobileLink: false, clusterEnabled: true);
      expect(policy.contributes, isTrue);
    });

    test('cluster over mobile data streams only, as long as possible', () {
      final policy = MeshLogic.localPolicy(
          mobileLink: true, clusterEnabled: true);
      expect(policy.contributes, isFalse);
      expect(policy.reason, contains('mobile data'));
    });
  });
}
