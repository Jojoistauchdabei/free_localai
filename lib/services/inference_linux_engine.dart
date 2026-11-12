// Linux inference engine — talks to libplm_bridge.so (see linux/bridge/
// plm_bridge.cpp) via dart:ffi. Implements the same surface the app expects
// from llama_flutter_android's LlamaController on Android/iOS, so
// inference_android.dart can delegate to it on Linux desktop.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart' as ffi;
import 'package:llama_flutter_android/llama_flutter_android.dart'
    show ChatMessage, ContextInfo, GpuInfo;

const String kBridgeLibrary = 'libplm_bridge.so';

DynamicLibrary? _cachedDylib;

DynamicLibrary _openBridge() {
  return _cachedDylib ??= DynamicLibrary.open(kBridgeLibrary);
}

// ── FFI signatures ──────────────────────────────────────────────────────────

typedef _VersionC = Int32 Function();
typedef _LastErrorC = Pointer<ffi.Utf8> Function();
typedef _SetQuietC = Void Function(Int32);
typedef _SetClusterC = Void Function(
    Pointer<Pointer<ffi.Utf8>>, Pointer<Float>, Int32, Float);
typedef _WorkerStartC = Int32 Function(Pointer<ffi.Utf8>, Int32);
typedef _WorkerRunningC = Int32 Function();
typedef _WorkerStopC = Int32 Function();
typedef _GpuCountC = Int32 Function();
typedef _GpuNameC = Pointer<ffi.Utf8> Function(Int32);
typedef _GpuMemoryC = Uint64 Function(Int32);
typedef _GpuSpeedC = Double Function(Int32);
typedef _GpuSelectionC = Void Function(Pointer<Int32>, Int32);
typedef _ProgressNative = Void Function(Float);
typedef _LoadStartC = Int32 Function(Pointer<ffi.Utf8>, Pointer<ffi.Utf8>,
    Int32, Int32, Int32, Pointer<NativeFunction<_ProgressNative>>);
typedef _LoadStateC = Int32 Function();
typedef _LoadProgressC = Float Function();
typedef _LoadErrorC = Pointer<ffi.Utf8> Function();
typedef _IsLoadedC = Int32 Function();
typedef _StopC = Void Function();
typedef _GenStartC = Int32 Function(
    Pointer<Pointer<ffi.Utf8>>,
    Pointer<Pointer<ffi.Utf8>>,
    Int32,
    Double,
    Double,
    Int32,
    Double,
    Double,
    Int32,
    Int32);
typedef _GenStateC = Int32 Function();
typedef _GenTakeC = Int32 Function(Pointer<ffi.Utf8>, Int32);
typedef _GenErrorC = Pointer<ffi.Utf8> Function();
typedef _TokensUsedC = Int32 Function();
typedef _ContextSizeC = Int32 Function();
typedef _TemplateSourceC = Pointer<ffi.Utf8> Function();
typedef _FreeC = Void Function();

// Dart side
typedef _VersionD = int Function();
typedef _LastErrorD = Pointer<ffi.Utf8> Function();
typedef _SetQuietD = void Function(int);
typedef _SetClusterD = void Function(
    Pointer<Pointer<ffi.Utf8>>, Pointer<Float>, int, double);
typedef _WorkerStartD = int Function(Pointer<ffi.Utf8>, int);
typedef _WorkerRunningD = int Function();
typedef _WorkerStopD = int Function();
typedef _GpuCountD = int Function();
typedef _GpuNameD = Pointer<ffi.Utf8> Function(int);
typedef _GpuMemoryD = int Function(int);
typedef _GpuSpeedD = double Function(int);
typedef _GpuSelectionD = void Function(Pointer<Int32>, int);
typedef _LoadStartD = int Function(Pointer<ffi.Utf8>, Pointer<ffi.Utf8>, int,
    int, int, Pointer<NativeFunction<_ProgressNative>>);
typedef _LoadStateD = int Function();
typedef _LoadProgressD = double Function();
typedef _LoadErrorD = Pointer<ffi.Utf8> Function();
typedef _IsLoadedD = int Function();
typedef _StopD = void Function();
typedef _GenStartD = int Function(
    Pointer<Pointer<ffi.Utf8>>,
    Pointer<Pointer<ffi.Utf8>>,
    int,
    double,
    double,
    int,
    double,
    double,
    int,
    int);
typedef _GenStateD = int Function();
typedef _GenTakeD = int Function(Pointer<ffi.Utf8>, int);
typedef _GenErrorD = Pointer<ffi.Utf8> Function();
typedef _TokensUsedD = int Function();
typedef _ContextSizeD = int Function();
typedef _TemplateSourceD = Pointer<ffi.Utf8> Function();
typedef _FreeD = void Function();

// ── Bridge wrapper ──────────────────────────────────────────────────────────

class PlmBridge {
  static final DynamicLibrary _dylib = _openBridge();

  static _VersionD version =
      _dylib.lookupFunction<_VersionC, _VersionD>('plm_version');
  static _LastErrorD lastError =
      _dylib.lookupFunction<_LastErrorC, _LastErrorD>('plm_last_error');
  static _SetQuietD setQuiet =
      _dylib.lookupFunction<_SetQuietC, _SetQuietD>('plm_set_quiet');
  static _SetClusterD setCluster =
      _dylib.lookupFunction<_SetClusterC, _SetClusterD>('plm_set_cluster');
  static _WorkerStartD workerStart =
      _dylib.lookupFunction<_WorkerStartC, _WorkerStartD>('plm_worker_start');
  static _WorkerRunningD workerRunning = _dylib
      .lookupFunction<_WorkerRunningC, _WorkerRunningD>('plm_worker_running');
  static _WorkerStopD workerStop =
      _dylib.lookupFunction<_WorkerStopC, _WorkerStopD>('plm_worker_stop');
  static _GpuCountD gpuCount =
      _dylib.lookupFunction<_GpuCountC, _GpuCountD>('plm_gpu_count');
  static _GpuNameD gpuName =
      _dylib.lookupFunction<_GpuNameC, _GpuNameD>('plm_gpu_name');
  static _GpuMemoryD gpuFreeMemory =
      _dylib.lookupFunction<_GpuMemoryC, _GpuMemoryD>('plm_gpu_free_memory');
  static _GpuMemoryD gpuTotalMemory =
      _dylib.lookupFunction<_GpuMemoryC, _GpuMemoryD>('plm_gpu_total_memory');
  static _GpuSpeedD gpuMemorySpeed =
      _dylib.lookupFunction<_GpuSpeedC, _GpuSpeedD>('plm_gpu_memory_speed');
  static _GpuSelectionD setGpuSelection = _dylib
      .lookupFunction<_GpuSelectionC, _GpuSelectionD>('plm_set_gpu_selection');
  static _LoadStartD loadStart =
      _dylib.lookupFunction<_LoadStartC, _LoadStartD>('plm_load_start');
  static _LoadStateD loadState =
      _dylib.lookupFunction<_LoadStateC, _LoadStateD>('plm_load_state');
  static _LoadProgressD loadProgress = _dylib
      .lookupFunction<_LoadProgressC, _LoadProgressD>('plm_load_progress');
  static _LoadErrorD loadError =
      _dylib.lookupFunction<_LoadErrorC, _LoadErrorD>('plm_load_error');
  static _IsLoadedD isLoaded =
      _dylib.lookupFunction<_IsLoadedC, _IsLoadedD>('plm_is_loaded');
  static _StopD stop = _dylib.lookupFunction<_StopC, _StopD>('plm_stop');
  static _GenStartD generateChatStart =
      _dylib.lookupFunction<_GenStartC, _GenStartD>('plm_generate_chat_start');
  static _GenStateD generateState =
      _dylib.lookupFunction<_GenStateC, _GenStateD>('plm_generate_state');
  static _GenTakeD generateTake =
      _dylib.lookupFunction<_GenTakeC, _GenTakeD>('plm_generate_take');
  static _GenErrorD generateError =
      _dylib.lookupFunction<_GenErrorC, _GenErrorD>('plm_generate_error');
  static _TokensUsedD tokensUsed =
      _dylib.lookupFunction<_TokensUsedC, _TokensUsedD>('plm_tokens_used');
  static _ContextSizeD contextSize =
      _dylib.lookupFunction<_ContextSizeC, _ContextSizeD>('plm_context_size');
  static _TemplateSourceD templateSource =
      _dylib.lookupFunction<_TemplateSourceC, _TemplateSourceD>(
          'plm_chat_template_source');
  static _FreeD free = _dylib.lookupFunction<_FreeC, _FreeD>('plm_free');

  static String _read(Pointer<ffi.Utf8> ptr) {
    if (ptr == nullptr) return '';
    return ptr.toDartString();
  }

  static String lastErrorString() => _read(lastError());
  static String loadErrorString() => _read(loadError());
  static String generateErrorString() => _read(generateError());
}

// ── Engine ──────────────────────────────────────────────────────────────────

/// Result from model loading (mirrors LoadResult in inference_android.dart).
class LinuxLoadResult {
  final bool success;
  final String message;
  LinuxLoadResult({required this.success, required this.message});
}

/// Linux GGUF engine backed by libplm_bridge.so.
class LinuxLlamaEngine {
  final _progressController = StreamController<double>.broadcast();
  Timer? _loadTimer;
  Timer? _genTimer;

  double _lastEmittedProgress = 0.0;

  /// llama.cpp load progress, 0..1.
  Stream<double> get loadProgress => _progressController.stream;

  bool get isModelLoaded => PlmBridge.isLoaded() == 1;

  String get chatTemplateSource {
    try {
      return PlmBridge._read(PlmBridge.templateSource());
    } catch (_) {
      return '';
    }
  }

  static bool get bridgeAvailable {
    try {
      PlmBridge.version();
      return true;
    } catch (_) {
      return false;
    }
  }

  static void setCluster(
      List<String> endpoints, List<double> weights, double localWeight) {
    final endpointPtrs = ffi.calloc<Pointer<ffi.Utf8>>(endpoints.length);
    final native = <Pointer<ffi.Utf8>>[];
    final weightPtr = ffi.calloc<Float>(weights.length);
    try {
      for (var i = 0; i < endpoints.length; i++) {
        final ptr = endpoints[i].toNativeUtf8();
        native.add(ptr);
        endpointPtrs[i] = ptr;
        weightPtr[i] = weights[i].toDouble();
      }
      PlmBridge.setCluster(
          endpointPtrs, weightPtr, endpoints.length, localWeight);
    } finally {
      for (final ptr in native) {
        ffi.calloc.free(ptr);
      }
      ffi.calloc.free(endpointPtrs);
      ffi.calloc.free(weightPtr);
    }
  }

  static Future<void> startWorker({int port = 50052, int? threads}) async {
    final endpoint = '0.0.0.0:$port'.toNativeUtf8();
    try {
      final rc = PlmBridge.workerStart(endpoint, threads ?? 0);
      if (rc != 0) throw StateError('Linux RPC worker could not start');
    } finally {
      ffi.calloc.free(endpoint);
    }
  }

  static bool get workerRunning => PlmBridge.workerRunning() == 1;

  static String get cpuName =>
      Platform.localHostname.isEmpty ? 'PC CPU' : Platform.localHostname;

  static List<String> get gpuNames => [
        for (var i = 0; i < PlmBridge.gpuCount(); i++)
          PlmBridge._read(PlmBridge.gpuName(i)),
      ];

  static int gpuFreeMemoryBytes(int index) => PlmBridge.gpuFreeMemory(index);

  static int gpuTotalMemory(int index) => PlmBridge.gpuTotalMemory(index);

  static int get gpuTotalMemoryBytes {
    var total = 0;
    for (var i = 0; i < PlmBridge.gpuCount(); i++) {
      total += PlmBridge.gpuTotalMemory(i);
    }
    return total;
  }

  static List<double> get gpuMemorySpeeds => [
        for (var i = 0; i < PlmBridge.gpuCount(); i++)
          PlmBridge.gpuMemorySpeed(i),
      ];

  static void setGpuSelection(List<int> indices) {
    final ptr = ffi.calloc<Int32>(indices.length);
    try {
      for (var i = 0; i < indices.length; i++) {
        ptr[i] = indices[i];
      }
      PlmBridge.setGpuSelection(ptr, indices.length);
    } finally {
      ffi.calloc.free(ptr);
    }
  }

  static Future<void> stopWorker() async {
    PlmBridge.workerStop();
  }

  /// Loads a GGUF model. Returns an error message on failure, null on
  /// success — same contract as the Android LlamaController.loadModel.
  Future<String?> loadModel({
    required String modelPath,
    String? mmprojPath,
    required int threads,
    required int contextSize,
    int gpuLayers = 0,
  }) async {
    PlmBridge.setQuiet(1);

    final pathPtr = modelPath.toNativeUtf8();
    final mmprojPtr = (mmprojPath ?? '').isEmpty
        ? Pointer<ffi.Utf8>.fromAddress(0)
        : mmprojPath!.toNativeUtf8();
    final rc = PlmBridge.loadStart(
        pathPtr, mmprojPtr, contextSize, threads, gpuLayers, nullptr);
    ffi.calloc.free(pathPtr);
    if ((mmprojPath ?? '').isNotEmpty) ffi.calloc.free(mmprojPtr);
    if (rc != 0) return PlmBridge.lastErrorString();

    final completer = Completer<String?>();
    _lastEmittedProgress = 0.0;
    _loadTimer?.cancel();
    _loadTimer = Timer.periodic(const Duration(milliseconds: 120), (timer) {
      if (completer.isCompleted) {
        timer.cancel();
        return;
      }
      final state = PlmBridge.loadState();
      final progress = PlmBridge.loadProgress();
      if (progress > _lastEmittedProgress) {
        _lastEmittedProgress = progress;
        _progressController.add(progress.clamp(0.0, 1.0));
      }
      if (state == 2) {
        timer.cancel();
        completer.complete(null);
      } else if (state == 3) {
        timer.cancel();
        completer.complete(PlmBridge.loadErrorString());
      }
    });

    return completer.future;
  }

  /// Streams a chat generation. History is sent as full message list; the
  /// bridge applies the model's own chat template.
  Stream<String> generateChat({
    required List<ChatMessage> messages,
    String? template,
    required int maxTokens,
    required double temperature,
    required double topP,
    required int topK,
    required double minP,
    required double repeatPenalty,
    required int repeatLastN,
  }) {
    final controller = StreamController<String>.broadcast();

    final n = messages.length;
    final rolesPtr = ffi.calloc<Pointer<ffi.Utf8>>(n);
    final contentsPtr = ffi.calloc<Pointer<ffi.Utf8>>(n);
    final roleNative = <Pointer<ffi.Utf8>>[];
    final contentNative = <Pointer<ffi.Utf8>>[];
    for (var i = 0; i < n; i++) {
      final role = messages[i].role;
      final content = messages[i].content;
      final r = role.toNativeUtf8();
      final c = content.toNativeUtf8();
      roleNative.add(r);
      contentNative.add(c);
      rolesPtr[i] = r;
      contentsPtr[i] = c;
    }

    final rc = PlmBridge.generateChatStart(
      rolesPtr,
      contentsPtr,
      n,
      temperature,
      topP,
      topK,
      minP,
      repeatPenalty,
      repeatLastN,
      maxTokens,
    );

    for (final p in roleNative) {
      ffi.calloc.free(p);
    }
    for (final p in contentNative) {
      ffi.calloc.free(p);
    }
    ffi.calloc.free(rolesPtr);
    ffi.calloc.free(contentsPtr);

    if (rc != 0) {
      final error = PlmBridge.lastErrorString();
      scheduleMicrotask(() async {
        controller.addError(error);
        await controller.close();
      });
      return controller.stream;
    }

    _genTimer?.cancel();
    final buf = ffi.calloc<Uint8>(8192);
    final completer = Completer<void>();
    _genTimer = Timer.periodic(const Duration(milliseconds: 30), (timer) {
      if (completer.isCompleted) {
        timer.cancel();
        return;
      }
      // Drain everything currently queued.
      for (;;) {
        final len = PlmBridge.generateTake(buf.cast<ffi.Utf8>(), 8192);
        if (len > 0) {
          final piece = utf8.decode(buf.asTypedList(len), allowMalformed: true);
          controller.add(piece);
          continue;
        }
        if (len == 0) return; // queue empty, still running — wait for next tick
        // len < 0: finished and fully drained.
        timer.cancel();
        completer.complete();
        break;
      }
    });

    unawaited(completer.future.then((_) async {
      final failed = PlmBridge.generateState() == 3;
      final error = failed ? PlmBridge.generateErrorString() : '';
      ffi.calloc.free(buf);
      if (failed && error.isNotEmpty) {
        controller.addError(error);
      }
      await controller.close();
      _genTimer = null;
    }));

    return controller.stream;
  }

  Future<void> stop() async {
    PlmBridge.stop();
  }

  Future<void> resetConversation() async {
    // The bridge clears the KV cache at the start of every generation.
  }

  Future<ContextInfo?> getContextInfo() async {
    try {
      if (PlmBridge.isLoaded() != 1) return null;
      return ContextInfo(
        tokensUsed: PlmBridge.tokensUsed(),
        contextSize: PlmBridge.contextSize(),
        usagePercentage:
            PlmBridge.tokensUsed() * 100.0 / PlmBridge.contextSize(),
      );
    } catch (_) {
      return null;
    }
  }

  /// GPU probe — the CPU build has no GPU backend, so report none and let
  /// the app fall back to CPU inference.
  Future<GpuInfo> detectGpu() async {
    final names = gpuNames;
    final totalMemory = gpuTotalMemoryBytes;
    return GpuInfo(
      vulkanSupported: names.isNotEmpty,
      gpuName: names.join(' + '),
      vulkanApiVersion: names.isEmpty ? -1 : 1,
      deviceLocalMemoryBytes: totalMemory,
      freeRamBytes: _freeRamBytes(),
      recommendedGpuLayers: names.isEmpty ? 0 : 999999,
    );
  }

  static int get totalGpuMemoryBytes => gpuTotalMemoryBytes;

  static int _freeRamBytes() {
    try {
      final meminfo = File('/proc/meminfo').readAsStringSync();
      for (final line in meminfo.split('\n')) {
        if (line.startsWith('MemAvailable:')) {
          final kb = int.parse(line.replaceAll(RegExp('[^0-9]'), ''));
          return kb * 1024;
        }
      }
    } catch (_) {}
    return 0;
  }

  Future<void> dispose() async {
    _loadTimer?.cancel();
    _genTimer?.cancel();
    _loadTimer = null;
    _genTimer = null;
    try {
      PlmBridge.free();
    } catch (_) {}
  }
}
