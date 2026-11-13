import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import 'download_service.dart';

class LanModelPeer {
  final String host;
  final int port;
  final String name;
  final List<String> models;

  const LanModelPeer({
    required this.host,
    required this.port,
    required this.name,
    required this.models,
  });
}

/// Shares downloaded model files with explicitly discovered devices on the
/// local network. The discovery protocol is intentionally LAN-only.
///
/// Discovery works in two layers:
/// 1. UDP broadcast announcements (fast when the Wi-Fi allows broadcasts).
/// 2. Active TCP probing of the local /24 subnet on [modelPort], used as a
///    fallback because broadcast reception is often blocked by Android
///    multicast filtering, Windows Firewall, or Wi-Fi AP isolation.
class LanModelShareService extends GetxService {
  static const modelPort = 50053;
  static const discoveryPort = 50054;
  static const _announce = 'privatelm-models-v1';

  final DownloadService _downloads = Get.find<DownloadService>();
  final peers = <LanModelPeer>[].obs;
  final isScanning = false.obs;

  HttpServer? _server;
  RawDatagramSocket? _discovery;
  Timer? _announceTimer;
  List<String> _localAddresses = const [];

  bool get supported => !kIsWeb;

  @override
  void onInit() {
    super.onInit();
    if (supported) unawaited(start());
  }

  Future<List<String>> _refreshLocalAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      _localAddresses = interfaces
          .expand((i) => i.addresses)
          .where((a) => !a.isLoopback)
          .map((a) => a.address)
          .toList();
    } catch (_) {
      _localAddresses = const [];
    }
    return _localAddresses;
  }

  bool _isSelf(String host) => _localAddresses.contains(host);

  Future<void> start() async {
    if (_server != null || !supported) return;
    try {
      await _refreshLocalAddresses();
      _server = await HttpServer.bind(InternetAddress.anyIPv4, modelPort);
      _server!.listen(_handleRequest, onError: (_) {});
      _discovery = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, discoveryPort,
          reuseAddress: true,
          // reusePort is not supported on Windows.
          reusePort: !Platform.isWindows);
      _discovery!.broadcastEnabled = true;
      _discovery!.listen((event) {
        if (event != RawSocketEvent.read) return;
        final socket = _discovery;
        if (socket == null) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        _recordAnnouncement(datagram.data, datagram.address.address);
      });
      _announceTimer =
          Timer.periodic(const Duration(seconds: 15), (_) => announce());
      await announce();
    } catch (_) {
      await stop();
    }
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _discovery?.close();
    _discovery = null;
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> announce() async {
    final socket = _discovery;
    if (socket == null) return;
    final targets = <InternetAddress>[InternetAddress('255.255.255.255')];
    for (final address in await _refreshLocalAddresses()) {
      final parts = address.split('.');
      if (parts.length != 4) continue;
      targets.add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
    }
    final files = await _downloads.getDownloadedModels();
    final payload = utf8.encode(jsonEncode({
      'type': _announce,
      'port': modelPort,
      'name': Platform.localHostname,
      'models': files.where(_isShareable).toList(),
    }));
    for (final target in targets.toSet()) {
      try {
        socket.send(payload, target, discoveryPort);
      } catch (_) {}
    }
  }

  Future<void> scan() async {
    if (isScanning.value) return;
    isScanning.value = true;
    try {
      peers.clear();
      await announce();
      // UDP broadcast is unreliable on many devices/networks; probe the
      // subnet over TCP in parallel so discovery always works on the LAN.
      await _probeSubnet();
      // Give broadcast announcements a moment to arrive as well.
      await Future<void>.delayed(const Duration(seconds: 2));
      // Merge newly discovered models into already-known peers.
      await _refreshPeerModels();
    } finally {
      isScanning.value = false;
    }
  }

  Future<void> _probeSubnet() async {
    if (_localAddresses.isEmpty) await _refreshLocalAddresses();
    final candidates = <String>{};
    for (final address in _localAddresses) {
      final parts = address.split('.');
      if (parts.length != 4) continue;
      for (var i = 1; i <= 254; i++) {
        final ip = '${parts[0]}.${parts[1]}.${parts[2]}.$i';
        if (ip == address) continue;
        candidates.add(ip);
      }
    }
    final list = candidates.toList();
    const batchSize = 64;
    for (var i = 0; i < list.length; i += batchSize) {
      final batch = list.skip(i).take(batchSize);
      await Future.wait(batch.map(_probe));
      if (list.length > batchSize && i + batchSize < list.length) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  Future<void> _probe(String ip) async {
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(milliseconds: 700);
      final request =
          await client.getUrl(Uri.http('$ip:$modelPort', '/models'));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return;
      }
      final body = await response.transform(utf8.decoder).join();
      final models = (jsonDecode(body) as List? ?? const [])
          .whereType<String>()
          .where(_isShareable)
          .toList();
      if (models.isEmpty) return;
      _upsertPeer(LanModelPeer(host: ip, port: modelPort, name: ip, models: models));
    } catch (_) {
      // Nothing reachable on this address.
    } finally {
      client?.close(force: true);
    }
  }

  Future<void> _refreshPeerModels() async {
    for (final peer in List<LanModelPeer>.from(peers)) {
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 2);
        final request =
            await client.getUrl(Uri.http('${peer.host}:${peer.port}', '/models'));
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          client.close(force: true);
          continue;
        }
        final body = await response.transform(utf8.decoder).join();
        client.close(force: true);
        final models = (jsonDecode(body) as List? ?? const [])
            .whereType<String>()
            .where(_isShareable)
            .toList();
        _upsertPeer(LanModelPeer(
          host: peer.host,
          port: peer.port,
          name: peer.name,
          models: models,
        ));
      } catch (_) {}
    }
  }

  void _upsertPeer(LanModelPeer peer) {
    final existing = peers.indexWhere((p) => p.host == peer.host);
    if (existing >= 0) {
      peers[existing] = peer;
    } else {
      peers.add(peer);
    }
  }

  Future<String?> download(LanModelPeer peer, String filename) async {
    if (!_isShareable(filename)) return 'Invalid model filename';
    final uri = Uri.http('${peer.host}:${peer.port}', '/models/$filename');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return 'Remote device returned HTTP ${response.statusCode}';
      }
      final path = await _downloads.modelPath(filename);
      final output = File(path).openWrite();
      try {
        await response.pipe(output);
      } finally {
        await output.close();
      }
    } finally {
      client.close(force: true);
    }
    try {
      Get.find<ModelController>().refreshDownloaded();
    } catch (_) {}
    return null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    if (path == '/models') {
      final files = await _downloads.getDownloadedModels();
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(files.where(_isShareable).toList()));
      await request.response.close();
      return;
    }
    if (path.startsWith('/models/')) {
      final filename = Uri.decodeComponent(path.substring('/models/'.length));
      if (!_isShareable(filename)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final file = File(await _downloads.modelPath(filename));
      if (!await file.exists()) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.headers.contentType =
          ContentType('application', 'octet-stream');
      await request.response.addStream(file.openRead());
      await request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  void _recordAnnouncement(List<int> data, String host) {
    try {
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      if (json['type'] != _announce || _isSelf(host)) return;
      final models = (json['models'] as List? ?? const [])
          .whereType<String>()
          .where(_isShareable)
          .toList();
      _upsertPeer(LanModelPeer(
        host: host,
        port: (json['port'] as num?)?.toInt() ?? modelPort,
        name: json['name'] as String? ?? host,
        models: models,
      ));
    } catch (_) {}
  }

  static bool _isShareable(String filename) {
    if (filename.isEmpty || filename.contains('/') || filename.contains('\\')) {
      return false;
    }
    final lower = filename.toLowerCase();
    return lower.endsWith('.gguf') ||
        lower.endsWith('.litertlm') ||
        lower.endsWith('.safetensors') ||
        lower.endsWith('.bin');
  }

  @override
  void onClose() {
    unawaited(stop());
    super.onClose();
  }
}
