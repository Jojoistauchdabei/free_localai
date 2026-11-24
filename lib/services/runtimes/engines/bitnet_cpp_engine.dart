import 'dart:io';

import 'package:get/Get.dart';

import '../../services/download_service.dart';
import '../../services/gguf_metadata.dart';
import '../runtime_engine.dart';
import 'llama_cpp_engine.dart';

class BitNetCppEngine extends LlamaCppEngine {
  DownloadService get _download => Get.find<DownloadService>();

  Future<String?> _firstBitnetPath() async {
    final models = await _download.getDownloadedModels();
    for (final name in models) {
      if (!name.toLowerCase().endsWith('.gguf')) continue;
      final path = await _download.modelPath(name);
      final info = await readGgufInfo(path);
      if (info != null &&
          (info.architecture == 'bitnet' ||
              info.name?.toLowerCase().contains('bitnet') == true)) {
        return path;
      }
    }
    return null;
  }

  @override
  Future<String?> firstGgufPath() => _firstBitnetPath();

  @override
  String get id => 'bitnet_cpp';

  @override
  String get name => 'BitNet.cpp';

  @override
  String get version => 'BitNet.cpp (via llama.cpp)';

  @override
  Future<RuntimeAvailability> checkAvailability() async {
    final path = await _firstBitnetPath();
    if (path == null) {
      return RuntimeAvailability.unavailable(
          'Kein BitNet-Modell (GGUF-Architektur "bitnet") heruntergeladen.');
    }
    if (!await File(path).exists()) {
      return RuntimeAvailability.unavailable(
          'BitNet-Modelldatei nicht gefunden: $path');
    }
    return const RuntimeAvailability.available();
  }
}
