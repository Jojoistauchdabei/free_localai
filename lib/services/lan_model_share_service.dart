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
  String _localAddress = '';

  bool get supported => !kIsWeb;

  @override
  void onInit() {
    super.onInit();
    if (supported) unawaited(start());
  }

  Future<void> start() async {
    if (_server != null || !supported) return;
    try {
      final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      final addresses = interfaces
          .expand((i) => i.addresses)
          .where((a) => !a.isLoopback)
          .toList();
      _localAddress = addresses.isEmpty ? '' : addresses.first.address;
      _server = await HttpServer.bind(InternetAddress.anyIPv4, modelPort);
      _server!.listen(_handleRequest, onError: (_) {});
      _discovery = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, discoveryPort,
          reuseAddress: true);
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
    final files = await _downloads.getDownloadedModels();
    final payload = utf8.encode(jsonEncode({
      'type': _announce,
      'port': modelPort,
      'name': Platform.localHostname,
      'models': files.where(_isShareable).toList(),
    }));
    socket.send(payload, InternetAddress('255.255.255.255'), discoveryPort);
  }

  Future<void> scan() async {
    if (isScanning.value) return;
    isScanning.value = true;
    try {
      peers.clear();
      await announce();
      await Future<void>.delayed(const Duration(seconds: 2));
    } finally {
      isScanning.value = false;
    }
  }

  Future<String?> download(LanModelPeer peer, String filename) async {
    if (!_isShareable(filename)) return 'Invalid model filename';
    final uri = Uri.http('${peer.host}:${peer.port}', '/models/$filename');
    final client = HttpClient();
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
      if (json['type'] != _announce || host == _localAddress) return;
      final models = (json['models'] as List? ?? const [])
          .whereType<String>()
          .where(_isShareable)
          .toList();
      final peer = LanModelPeer(
        host: host,
        port: (json['port'] as num?)?.toInt() ?? modelPort,
        name: json['name'] as String? ?? host,
        models: models,
      );
      peers.removeWhere((p) => p.host == host);
      peers.add(peer);
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
