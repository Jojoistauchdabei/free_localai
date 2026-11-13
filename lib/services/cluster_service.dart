import 'dart:async';
import 'dart:io'
    show
        Directory,
        File,
        InternetAddressType,
        NetworkInterface,
        Platform,
        Process,
        Socket;
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import '../core/constants.dart';
import '../core/ui.dart';
import 'app_log_service.dart';
import 'hive_service.dart';
import 'inference_linux_engine.dart';

/// What this phone does in a phone cluster.
enum ClusterRole {
  off,

  /// Runs the model, with part of it on the workers.
  master,

  /// Lends its processor and memory to a master.
  worker,
}

/// One phone's part of the loaded model.
class ClusterShare {
  final String name;
  final double mb;
  final bool isThisPhone;
  const ClusterShare(this.name, this.mb, {this.isThisPhone = false});
}

/// One local Vulkan device. Linux exposes every physical GPU separately so
/// the master can keep a model on the best device instead of treating the PC
/// as one anonymous pool.
class LocalGpuDevice {
  final int index;
  final String name;
  final int freeMemoryBytes;
  final int totalMemoryBytes;
  final double memorySpeedGbps;
  final bool selected;

  /// Integrated GPU: it doesn't have its own VRAM — its memory is system
  /// RAM, shown and planned separately from the CPU's share.
  final bool isIntegrated;

  const LocalGpuDevice({
    required this.index,
    required this.name,
    required this.freeMemoryBytes,
    required this.totalMemoryBytes,
    required this.memorySpeedGbps,
    this.selected = true,
    this.isIntegrated = false,
  });

  LocalGpuDevice copyWith({bool? selected}) => LocalGpuDevice(
        index: index,
        name: name,
        freeMemoryBytes: freeMemoryBytes,
        totalMemoryBytes: totalMemoryBytes,
        memorySpeedGbps: memorySpeedGbps,
        selected: selected ?? this.selected,
        isIntegrated: isIntegrated,
      );
}

class LocalCpuDevice {
  final String name;

  /// Free system RAM right now (everything the OS still has available).
  final int freeMemoryBytes;

  /// The whole installed RAM, before any subtraction.
  final int totalMemoryBytes;

  /// RAM the integrated GPU draws from the same physical pool; the CPU's
  /// usable share is the rest.
  final int integratedGpuMemoryBytes;

  final int logicalCores;

  /// How many of [logicalCores] the user lets inference use.
  final int allocatedCores;

  final double computeTops;

  const LocalCpuDevice({
    required this.name,
    required this.freeMemoryBytes,
    required this.totalMemoryBytes,
    this.integratedGpuMemoryBytes = 0,
    required this.logicalCores,
    this.allocatedCores = 0,
    this.computeTops = 0,
  });

  /// RAM left for the CPU after the integrated GPU's share: the iGPU's
  /// assigned RAM is subtracted from the main system RAM.
  int get usableMemoryBytes =>
      (freeMemoryBytes - integratedGpuMemoryBytes).clamp(0, freeMemoryBytes);

  /// RAM visible to the CPU in total: full system RAM minus the iGPU's.
  int get totalUsableMemoryBytes =>
      (totalMemoryBytes - integratedGpuMemoryBytes)
          .clamp(0, totalMemoryBytes);

  int get effectiveCores =>
      allocatedCores > 0 ? allocatedCores.clamp(1, logicalCores) : logicalCores;

  LocalCpuDevice copyWith({
    double? computeTops,
    int? allocatedCores,
    int? freeMemoryBytes,
  }) =>
      LocalCpuDevice(
        name: name,
        freeMemoryBytes: freeMemoryBytes ?? this.freeMemoryBytes,
        totalMemoryBytes: totalMemoryBytes,
        integratedGpuMemoryBytes: integratedGpuMemoryBytes,
        logicalCores: logicalCores,
        allocatedCores: allocatedCores ?? this.allocatedCores,
        computeTops: computeTops ?? this.computeTops,
      );
}

/// A phone the master can put layers on, for planning a load.
class _Phone {
  final ClusterWorker? worker; // null: the master itself
  final double capacityMb;
  final double speed; // GB/s
  double assignedMb = 0;
  _Phone(this.worker, this.capacityMb, this.speed);
}

/// Phone cluster: spread a GGUF model across phones on the same Wi-Fi.
/// The master runs the model; workers hold part of its layers.
class ClusterService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  static bool get isSupported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isLinux ||
          Platform.isWindows);

  /// Running a model across workers is Android-only for now; iOS devices
  /// can be workers (their GPU serves a master's layers).
  static bool get canBeMaster =>
      !kIsWeb && (Platform.isAndroid || Platform.isLinux || Platform.isWindows);

  /// Linux & Windows use llama.cpp's native RPC server; phones use the
  /// plugin worker.
  static bool get canBeWorker =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isLinux ||
          Platform.isWindows);

  /// Linux & Windows desktop share the native plm_bridge engine.
  static bool get isDesktopBridge => Platform.isLinux || Platform.isWindows;

  /// iOS can't stop the worker without closing the app.
  static bool get workerStopsWithApp => !kIsWeb && Platform.isIOS;

  /// QR codes a worker shows: privatelm://worker?host=…&port=…
  static const _qrScheme = 'privatelm';

  /// Speed assumed for workers paired before they reported one (GB/s).
  static const _unknownSpeed = 4.0;

  /// Workers the master can use on its next GGUF load.
  final workers = <ClusterWorker>[].obs;

  /// Master mode: use [workers] when loading GGUF models.
  final enabled = false.obs;

  final found = <ClusterWorker>[].obs;
  final isScanning = false.obs;

  /// This phone's worker service.
  final worker = const ClusterWorkerStatus(state: 'stopped').obs;
  final _workerRequested = false.obs;

  /// The API server is running (other devices, e.g. a PC, use the model).
  final serving = false.obs;

  /// This phone's Wi-Fi address, or null when it isn't on Wi-Fi.
  final wifiAddress = RxnString();

  /// How the loaded model is spread across phones; empty when it isn't.
  final split = <ClusterShare>[].obs;
  final localGpuDevices = <LocalGpuDevice>[].obs;
  final localCpuDevice = Rxn<LocalCpuDevice>();
  final freeStorageBytes = RxnInt();

  /// How many CPU cores this device's inference may use (0: all).
  final cpuThreads = 0.obs;
  final scheduleMode = 'smart'.obs;
  final workerWeights = <String, double>{}.obs;
  final localWeight = 100.0.obs;

  String deviceName = '';
  double? _localSpeed;
  Timer? _statusTimer;
  Timer? _metricsTimer;

  ClusterRole get role => _workerRequested.value || worker.value.running
      ? ClusterRole.worker
      : enabled.value
          ? ClusterRole.master
          : ClusterRole.off;

  /// "Pixel 8 72% · POCO F1 28%", or null when the model isn't split.
  String? get splitSummary {
    final total = split.fold<double>(0, (a, s) => a + s.mb);
    if (split.length < 2 || total <= 0) return null;
    return split
        .map((s) => '${s.name} ${(s.mb / total * 100).round()}%')
        .join(' · ');
  }

  @override
  void onInit() {
    super.onInit();
    enabled.value =
        _hive.getSetting<bool>(AppConstants.keyClusterEnabled) ?? false;
    final saved =
        _hive.getSetting<List>(AppConstants.keyClusterWorkers) ?? const [];
    workers.assignAll(saved.whereType<Map>().map(ClusterWorker.fromMap));
    scheduleMode.value =
        _hive.getSetting<String>(AppConstants.keyClusterScheduleMode) ??
            'smart';
    localWeight.value =
        (_hive.getSetting<num>(AppConstants.keyClusterLocalWeight) ?? 100)
            .toDouble()
            .clamp(0, 100);
    cpuThreads.value =
        _hive.getSetting<num>(AppConstants.keyClusterCpuThreads)?.toInt() ?? 0;
    final savedWeights =
        _hive.getSetting<Map>(AppConstants.keyClusterWorkerWeights);
    if (savedWeights != null) {
      workerWeights.assignAll(savedWeights.map(
          (key, value) => MapEntry(key.toString(), (value as num).toDouble())));
    }
    if (isSupported) {
      if (Platform.isIOS) {
        DeviceInfoPlugin().iosInfo.then((info) => deviceName = info.modelName);
      } else if (Platform.isAndroid) {
        DeviceInfoPlugin().androidInfo.then((info) => deviceName = info.model);
      } else {
        deviceName = Platform.isWindows ? 'Windows desktop' : 'Linux desktop';
        refreshLocalGpuDevices();
        refreshLocalCpuDevice();
        refreshLocalMetrics();
        unawaited(refreshCpuBenchmark());
      }
      refreshWorkerStatus().then((_) {
        if (worker.value.running) _watchWorker();
      });
      // A worker runs at full speed only while PrivateLM is on screen (it
      // borrows the app's priority), so keep the screen on while sharing.
      ever<ClusterWorkerStatus>(worker, (_) => _updateKeepScreenOn());
      ever<bool>(serving, (_) => _updateKeepScreenOn());
      refreshWifiAddress();
    }
  }

  Future<void> refreshLocalGpuDevices() async {
    if (!isDesktopBridge || !LinuxLlamaEngine.bridgeAvailable) return;
    final names = LinuxLlamaEngine.gpuNames;
    final speeds = LinuxLlamaEngine.gpuMemorySpeeds;
    final integrated = LinuxLlamaEngine.gpuIntegrated;
    final savedSelection =
        _hive.getSetting<List>(AppConstants.keyClusterGpuSelection);
    final selectedIndices =
        savedSelection?.whereType<num>().map((i) => i.toInt()).toSet();
    final devices = <LocalGpuDevice>[];
    for (var i = 0; i < names.length; i++) {
      final old = localGpuDevices.firstWhereOrNull((d) => d.index == i);
      devices.add(LocalGpuDevice(
        index: i,
        name: names[i],
        freeMemoryBytes: LinuxLlamaEngine.gpuFreeMemoryBytes(i),
        totalMemoryBytes: LinuxLlamaEngine.gpuTotalMemory(i),
        memorySpeedGbps: speeds.length > i ? speeds[i] : 0,
        selected: old?.selected ??
            (selectedIndices == null || selectedIndices.contains(i)),
        isIntegrated: i < integrated.length && integrated[i],
      ));
    }

    localGpuDevices.assignAll(devices);
    LinuxLlamaEngine.setGpuSelection(
        devices.where((d) => d.selected).map((d) => d.index).toList());
    await _saveGpuSelection();
  }

  void refreshLocalCpuDevice() {
    if (!isDesktopBridge) return;
    final total = LinuxLlamaEngine.totalRamBytes;
    final free = LinuxLlamaEngine.freeRamBytes;
    // RAM the integrated GPUs draw from the same physical pool: their
    // reported "VRAM" is really system RAM, subtracted from the CPU's share.
    var igpuBytes = 0;
    for (final gpu in localGpuDevices.where((d) => d.isIntegrated)) {
      igpuBytes += gpu.totalMemoryBytes;
    }
    localCpuDevice.value = LocalCpuDevice(
      name: LinuxLlamaEngine.cpuName,
      freeMemoryBytes: free,
      totalMemoryBytes: total,
      integratedGpuMemoryBytes: igpuBytes,
      logicalCores: Platform.numberOfProcessors,
      allocatedCores: cpuThreads.value,
      computeTops: localCpuDevice.value?.computeTops ?? 0,
    );
  }

  /// Sets how many CPU cores inference may use (0 = all). Applies to the
  /// next model load and to this device's worker.
  Future<void> setCpuThreads(int threads) async {
    final cores = localCpuDevice.value?.logicalCores ??
        (isDesktopBridge ? Platform.numberOfProcessors : 0);
    cpuThreads.value = cores > 0 ? threads.clamp(0, cores) : 0;
    await _hive.setSetting(AppConstants.keyClusterCpuThreads, cpuThreads.value);
    final cpu = localCpuDevice.value;
    if (cpu != null) {
      localCpuDevice.value =
          cpu.copyWith(allocatedCores: cpuThreads.value);
    }
  }

  Future<void> refreshCpuBenchmark() async {
    final cached = _hive.getSetting<num>(AppConstants.keyClusterCpuTops);
    if (cached != null && cached > 0) {
      final cpu = localCpuDevice.value;
      if (cpu != null) {
        localCpuDevice.value = cpu.copyWith(computeTops: cached.toDouble());
      }
      return;
    }
    final stopwatch = Stopwatch()..start();
    var value = 1.0;
    const iterations = 3000000;
    for (var i = 0; i < iterations; i++) {
      value = value * 1.0000001 + i;
    }
    stopwatch.stop();
    if (value.isNaN) return;
    final seconds = stopwatch.elapsedMicroseconds / 1000000;
    if (seconds <= 0) return;
    final tops = iterations * 2 / seconds / 1000000000000;
    await _hive.setSetting(AppConstants.keyClusterCpuTops, tops);
    refreshLocalCpuDevice();
    final cpu = localCpuDevice.value;
    if (cpu != null) {
      localCpuDevice.value = cpu.copyWith(computeTops: tops);
    }
  }

  void setLocalGpuSelected(int index, bool selected) {
    final i = localGpuDevices.indexWhere((d) => d.index == index);
    if (i < 0) return;
    localGpuDevices[i] = localGpuDevices[i].copyWith(selected: selected);
    LinuxLlamaEngine.setGpuSelection(
        localGpuDevices.where((d) => d.selected).map((d) => d.index).toList());
    localGpuDevices.refresh();
    unawaited(_saveGpuSelection());
  }

  Future<void> setScheduleMode(String mode) async {
    if (mode != 'smart' && mode != 'manual') return;
    scheduleMode.value = mode;
    await _hive.setSetting(AppConstants.keyClusterScheduleMode, mode);
  }

  Future<void> setWorkerWeight(ClusterWorker worker, double weight) async {
    workerWeights[worker.endpoint] = weight.clamp(0, 100);
    workerWeights.refresh();
    await _hive.setSetting(AppConstants.keyClusterWorkerWeights, workerWeights);
  }

  Future<void> setLocalWeight(double weight) async {
    localWeight.value = weight.clamp(0, 100);
    await _hive.setSetting(
        AppConstants.keyClusterLocalWeight, localWeight.value);
  }

  void autoSelectLocalGpus() {
    if (localGpuDevices.isEmpty) return;
    final sorted = [...localGpuDevices]
      ..sort((a, b) => b.memorySpeedGbps.compareTo(a.memorySpeedGbps));
    final fastest = sorted.first;
    localGpuDevices.assignAll([
      for (final d in localGpuDevices)
        d.copyWith(selected: d.index == fastest.index)
    ]);
    LinuxLlamaEngine.setGpuSelection([fastest.index]);
    unawaited(_saveGpuSelection());
  }

  void selectAllLocalGpus() {
    localGpuDevices.assignAll(
        localGpuDevices.map((d) => d.copyWith(selected: true)).toList());
    LinuxLlamaEngine.setGpuSelection(
        localGpuDevices.map((d) => d.index).toList());
    unawaited(_saveGpuSelection());
  }

  Future<void> _saveGpuSelection() => _hive.setSetting(
      AppConstants.keyClusterGpuSelection,
      localGpuDevices.where((d) => d.selected).map((d) => d.index).toList());

  @override
  void onClose() {
    _statusTimer?.cancel();
    _metricsTimer?.cancel();
    super.onClose();
  }

  Future<void> refreshLocalMetrics() async {
    try {
      final result = await Process.run('df', ['-k', Directory.current.path],
          runInShell: false);
      if (result.exitCode != 0) return;
      final lines = result.stdout.toString().trim().split('\n');
      if (lines.length < 2) return;
      final fields = lines.last.trim().split(RegExp(r'\s+'));
      if (fields.length >= 4) {
        freeStorageBytes.value = int.tryParse(fields[3]) == null
            ? null
            : int.parse(fields[3]) * 1024;
      }
    } catch (_) {
      freeStorageBytes.value = null;
    }
  }

  /// Android throttles a phone whose screen is off (slow cores, low CPU
  /// share), so keep it on while this device works for others: as a worker,
  /// or serving the model over the network.
  bool? _screenKeptOn;
  void _updateKeepScreenOn() {
    final s = worker.value;
    final on = s.running || s.starting || serving.value;
    if (on == _screenKeptOn) return;
    _screenKeptOn = on;
    if (Platform.isAndroid || Platform.isIOS) {
      LlamaCluster.setKeepScreenOn(on).catchError((_) {});
    }
  }

  Future<void> setRole(ClusterRole next) async {
    if (next == role) return;
    if (next != ClusterRole.worker && role == ClusterRole.worker) {
      if (workerStopsWithApp) {
        showToast(
            'Still sharing', 'Close PrivateLM to stop sharing this device.');
        return;
      }
      await stopWorker();
    }
    await _setEnabled(next == ClusterRole.master);
    if (next == ClusterRole.worker) await startWorker();
    await refreshWifiAddress();
  }

  // ── Worker ─────────────────────────────────────────────────────────────

  /// What the master scans to add this phone, once the worker is running.
  String? get workerQrData {
    final host = wifiAddress.value;
    final status = worker.value;
    if (host == null || !status.running) return null;
    return Uri(scheme: _qrScheme, host: 'worker', queryParameters: {
      'host': host,
      'port': '${LlamaCluster.defaultPort}',
      if (deviceName.isNotEmpty) 'name': deviceName,
      if (status.ramMb > 0) 'ram': '${status.ramMb}',
      if (status.bandwidth > 0) 'bw': status.bandwidth.toStringAsFixed(1),
      if (status.id != null) 'id': status.id!,
    }).toString();
  }

  Future<void> startWorker() async {
    if (!canBeWorker) return;
    if (isDesktopBridge) {
      _workerRequested.value = true;
      worker.value = const ClusterWorkerStatus(state: 'starting');
      // Serve the RPC worker with the configured CPU core count too.
      await LinuxLlamaEngine.startWorker(
          threads: cpuThreads.value > 0 ? cpuThreads.value : null);
      await Future.delayed(const Duration(milliseconds: 300));
      if (LinuxLlamaEngine.gpuNames.isNotEmpty) {
        deviceName =
            '${Platform.isWindows ? 'Windows' : 'Linux'} desktop · ${LinuxLlamaEngine.gpuNames.join(' + ')}';
      }
      worker.value = ClusterWorkerStatus(
        state: LinuxLlamaEngine.workerRunning ? 'running' : 'error',
        error: LinuxLlamaEngine.workerRunning
            ? null
            : 'Could not start the desktop RPC worker',
        ramMb: _linuxAvailableRamMb().round(),
        bandwidth: 4.0,
        id: 'desktop-${deviceName.hashCode}',
      );
      return;
    }
    if (Platform.isAndroid) {
      // Unrestricted battery keeps Android (Samsung especially) from moving
      // the worker to slow cores once it gets busy.
      final status = await LlamaCluster.workerStatus();
      if (!status.batteryUnrestricted)
        await LlamaCluster.requestBatteryUnrestricted();
    }
    _workerRequested.value = true;
    worker.value = const ClusterWorkerStatus(state: 'starting');
    await LlamaCluster.startWorker();
    _watchWorker();
  }

  Future<void> stopWorker() async {
    _workerRequested.value = false;
    _statusTimer?.cancel();
    if (isDesktopBridge) {
      await LinuxLlamaEngine.stopWorker();
      worker.value = const ClusterWorkerStatus(state: 'stopped');
      return;
    }
    await LlamaCluster.stopWorker();
    await Future.delayed(const Duration(milliseconds: 600));
    await refreshWorkerStatus();
  }

  /// Follows the worker service (its own process) while it runs: whether a
  /// master is connected and how much it holds.
  void _watchWorker() {
    _statusTimer?.cancel();
    var checks = 0;
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await refreshWorkerStatus();
      final s = worker.value;
      // Give the service a few seconds to come up before calling it stopped.
      if (!s.running && !s.starting && ++checks > 3) {
        _workerRequested.value = false;
        _statusTimer?.cancel();
      }
    });
  }

  Future<void> refreshWorkerStatus() async {
    if (isDesktopBridge) {
      worker.value = const ClusterWorkerStatus(state: 'stopped');
      return;
    }
    try {
      worker.value = await LlamaCluster.workerStatus();
    } catch (e) {
      Get.find<AppLogService>()
          .error('Cluster worker status failed', details: e);
    }
  }

  /// Finds this device's IPv4 address on Wi-Fi (wlan* on Android, en0 on
  /// iOS), if any.
  Future<void> refreshWifiAddress() async {
    try {
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      final wifi = Platform.isLinux || Platform.isWindows
          ? interfaces.where((i) => !i.name.startsWith('lo'))
          : interfaces
              .where((i) => i.name.startsWith('wlan') || i.name == 'en0');
      wifiAddress.value = wifi.isEmpty || wifi.first.addresses.isEmpty
          ? null
          : wifi.first.addresses.first.address;
    } catch (_) {
      wifiAddress.value = null;
    }
  }

  // ── Master: workers ────────────────────────────────────────────────────

  /// Adds the worker from a scanned QR code. Returns an error message, or
  /// null on success.
  Future<String?> addFromQr(String data) async {
    final uri = Uri.tryParse(data.trim());
    final params = uri?.queryParameters ?? const {};
    final host = params['host'];
    final port = int.tryParse(params['port'] ?? '');
    if (uri == null ||
        uri.scheme != _qrScheme ||
        host == null ||
        port == null) {
      return 'That isn\'t a PrivateLM worker code';
    }
    return _add(ClusterWorker(
      name: params['name'] ?? host,
      host: host,
      port: port,
      ramMb: int.tryParse(params['ram'] ?? ''),
      bandwidth: double.tryParse(params['bw'] ?? ''),
      model: params['name'],
      id: params['id'],
    ));
  }

  /// Adds a worker by IP ("192.168.1.20" or "192.168.1.20:50052"). Returns
  /// an error message, or null on success.
  Future<String?> addManual(String input) async {
    final text = input.trim();
    if (text.isEmpty) return 'Enter the worker phone\'s IP address';
    final host =
        text.contains(':') ? text.substring(0, text.lastIndexOf(':')) : text;
    final port = text.contains(':')
        ? int.tryParse(text.substring(text.lastIndexOf(':') + 1))
        : LlamaCluster.defaultPort;
    if (host.isEmpty || port == null) return 'Use the form 192.168.1.20:50052';
    return _add(ClusterWorker(name: host, host: host, port: port));
  }

  Future<String?> addFound(ClusterWorker w) => _add(w);

  /// Finds saved workers that no longer answer at their address (they moved
  /// to another Wi-Fi, a hotspot, or got a new IP) by their device ID on
  /// the network, and updates them. Returns the ones still unreachable.
  Future<List<ClusterWorker>> relocateWorkers() async {
    final missing = <ClusterWorker>[];
    for (final w in workers) {
      if (!await _probe(w.endpoint)) missing.add(w);
    }
    if (missing.isEmpty) return const [];
    if (isDesktopBridge) return missing;
    final seen = await LlamaCluster.discover();
    var moved = 0;
    final unreachable = <ClusterWorker>[];
    for (final w in missing) {
      final match = seen.firstWhereOrNull((s) => w.id != null && s.id == w.id);
      final i = workers.indexWhere((x) => x.endpoint == w.endpoint);
      if (match == null || match.endpoint == w.endpoint || i < 0) {
        unreachable.add(w);
        continue;
      }
      workers[i] = w.movedTo(match.host, match.port);
      moved++;
    }
    if (moved > 0) {
      await _save();
      Get.find<AppLogService>()
          .info('Phone cluster: found $moved worker(s) at a new address');
    }
    return unreachable;
  }

  Future<String?> _add(ClusterWorker worker) async {
    if (!await _probe(worker.endpoint)) {
      return 'Can\'t reach ${worker.endpoint}. Check that the phone is a worker '
          'and on the same Wi-Fi.';
    }
    workers.removeWhere((w) => w.endpoint == worker.endpoint);
    workers.add(worker);
    found.removeWhere((w) => w.endpoint == worker.endpoint);
    await _save();
    return null;
  }

  Future<void> remove(ClusterWorker w) async {
    workers.removeWhere((s) => s.endpoint == w.endpoint);
    await _save();
  }

  bool isAdded(ClusterWorker w) => workers.any((s) => s.endpoint == w.endpoint);

  /// Looks for workers on the Wi-Fi (doesn't work on every router).
  Future<void> scanNearby() async {
    if (isScanning.value) return;
    isScanning.value = true;
    try {
      if (isDesktopBridge) {
        found.clear();
        return;
      }
      final list = await LlamaCluster.discover();
      found.assignAll(list.where((w) => !isAdded(w)));
    } finally {
      isScanning.value = false;
    }
  }

  Future<bool> _probe(String endpoint) async {
    if (!isDesktopBridge) return LlamaCluster.probe(endpoint);
    final separator = endpoint.lastIndexOf(':');
    final host = separator > 0 ? endpoint.substring(0, separator) : '';
    final port =
        separator > 0 ? int.tryParse(endpoint.substring(separator + 1)) : null;
    if (host.isEmpty || port == null) return false;
    try {
      final socket =
          await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _setEnabled(bool value) async {
    enabled.value = value;
    await _hive.setSetting(AppConstants.keyClusterEnabled, value);
  }

  Future<void> _save() => _hive.setSetting(
      AppConstants.keyClusterWorkers, [for (final w in workers) w.toMap()]);

  // ── Master: loading ────────────────────────────────────────────────────

  /// Plans a GGUF load right before it starts and hands the plan to the
  /// native engine (or turns cluster mode off for it). Returns the number of
  /// workers used; throws with a readable message if the model won't fit
  /// or a worker can't be reached.
  ///
  /// If the model fits on this phone, asks whether to keep it here (faster:
  /// no Wi-Fi in the loop) or share it with the workers anyway. Otherwise
  /// the fastest phones are filled first, up to their free memory: phones
  /// take turns on every token, so the most work belongs on the fastest one,
  /// and phones that aren't needed are left out (one less Wi-Fi hop each).
  Future<int> applyForNextLoad(String modelPath, {String? modelName}) async {
    split.clear();
    if (!isSupported) return 0;
    if (!enabled.value || workers.isEmpty) {
      await _clearCluster();
      return 0;
    }

    // Workers that are off or away are left out, not fatal: the model may
    // fit without them.
    final offline = await relocateWorkers();
    final available = workers
        .where((w) => !offline.any((o) => o.endpoint == w.endpoint))
        .toList();
    if (offline.isNotEmpty) {
      final names = offline.map((w) => w.model ?? w.name).join(', ');
      showToast('Phone cluster', 'Not reachable, loading without: $names');
    }

    final modelMb = await File(modelPath).length() / (1024 * 1024);
    final needMb = modelMb * 1.1; // + KV cache and working buffers
    _localSpeed ??= await _cachedBenchmark();
    // Free RAM: workers report theirs when they start. The master also runs
    // the app and the KV cache, so it offers less of its own. The integrated
    // GPU's share of the same physical RAM is subtracted first.
    final localRamMb = isDesktopBridge
        ? (localCpuDevice.value?.usableMemoryBytes.toDouble() ??
            _linuxAvailableRamMb())
        : await LlamaCluster.localFreeRamMb();
    final master = _Phone(null, localRamMb * 0.7, _localSpeed!);
    final phones = [
      master,
      for (final w in available)
        _Phone(w, (w.ramMb ?? 2000) * 0.75, w.bandwidth ?? _unknownSpeed),
    ];
    final totalMb = phones.fold<double>(0, (a, p) => a + p.capacityMb);
    if (needMb > totalMb) {
      throw Exception('This model (${_gb(modelMb)}) is too big for these '
          '${phones.length} phones: together they have about ${_gb(totalMb)} '
          'free.${offline.isEmpty ? '' : ' Not reachable: ${offline.map((w) => w.model ?? w.name).join(', ')}.'} '
          'Add another worker, close apps on the phones, or pick a '
          'smaller model.');
    }

    if (available.isEmpty) {
      await _clearCluster();
      return 0;
    }
    if (needMb <= master.capacityMb && scheduleMode.value == 'smart') {
      final share = await _askFitsHere(
          modelName ?? modelPath.split('/').last, modelMb, available.length);
      if (!share) {
        await _clearCluster();
        return 0;
      }
      _splitBySpeed(phones, needMb);
    } else if (scheduleMode.value == 'manual') {
      _splitByManualWeights(phones, needMb);
    } else {
      _fillFastestFirst(phones, needMb);
    }

    final used =
        phones.where((p) => p.worker != null && p.assignedMb > 0).toList();
    if (used.isEmpty) {
      await _clearCluster();
      return 0;
    }
    try {
      if (isDesktopBridge) {
        LinuxLlamaEngine.setCluster(
          [for (final p in used) p.worker!.endpoint],
          [for (final p in used) p.assignedMb],
          master.assignedMb,
        );
      } else {
        await LlamaCluster.setCluster(
          [for (final p in used) p.worker!],
          weights: [for (final p in used) p.assignedMb],
          localWeight: master.assignedMb,
        );
      }
    } on PlatformException catch (e) {
      throw Exception(
          '${e.message ?? 'A worker is unreachable'}. Turn on Worker on that '
          'phone, or set this phone\'s Phone cluster to Off.');
    }
    return used.length;
  }

  Future<void> _clearCluster() async {
    if (isDesktopBridge) {
      LinuxLlamaEngine.setCluster(const [], const [], 1.0);
    } else {
      await LlamaCluster.clear();
    }
  }

  double _linuxAvailableRamMb() {
    try {
      return LinuxLlamaEngine.freeRamBytes / (1024 * 1024);
    } catch (_) {
      return 4096;
    }
  }

  Future<double> _cachedBenchmark() async {
    if (isDesktopBridge) return 4.0;
    final cached = _hive.getSetting<num>(AppConstants.keyClusterBenchmark);
    if (cached != null && cached > 0) return cached.toDouble();
    final measured = await LlamaCluster.benchmark();
    if (measured > 0) {
      await _hive.setSetting(AppConstants.keyClusterBenchmark, measured);
    }
    return measured > 0 ? measured : _unknownSpeed;
  }

  void _splitByManualWeights(List<_Phone> phones, double needMb) {
    final selected = phones.where((p) {
      final weight = p.worker == null
          ? localWeight.value
          : workerWeights[p.worker!.endpoint] ?? 0;
      return weight > 0;
    }).toList();
    if (selected.isEmpty) {
      _fillFastestFirst(phones, needMb);
      return;
    }
    final totalWeight = selected.fold<double>(
        0,
        (sum, p) =>
            sum +
            (p.worker == null
                ? localWeight.value
                : workerWeights[p.worker!.endpoint] ?? 0));
    var left = needMb;
    for (final p in selected) {
      final weight = p.worker == null
          ? localWeight.value
          : workerWeights[p.worker!.endpoint] ?? 0;
      p.assignedMb = math.min(p.capacityMb, needMb * weight / totalWeight);
      left -= p.assignedMb;
    }
    if (left > 0.5) {
      final bySpeed = [...selected]..sort((a, b) => b.speed.compareTo(a.speed));
      for (final p in bySpeed) {
        final extra = math.min(p.capacityMb - p.assignedMb, left);
        p.assignedMb += extra;
        left -= extra;
        if (left <= 0.5) break;
      }
    }
  }

  /// Fastest first, each up to its free memory, until the model is placed.
  static void _fillFastestFirst(List<_Phone> phones, double needMb) {
    final bySpeed = [...phones]..sort((a, b) => b.speed.compareTo(a.speed));
    var left = needMb;
    for (final p in bySpeed) {
      p.assignedMb = math.min(p.capacityMb, left);
      left -= p.assignedMb;
    }
  }

  /// Shares in proportion to speed, capped at each phone's free memory
  /// (what a capped phone can't take goes to the others).
  static void _splitBySpeed(List<_Phone> phones, double needMb) {
    var open = [...phones];
    var left = needMb;
    while (open.isNotEmpty && left > 0.5) {
      final speedSum = open.fold<double>(0, (a, p) => a + p.speed);
      final capped = [
        for (final p in open)
          if (p.assignedMb + left * p.speed / speedSum >= p.capacityMb) p,
      ];
      if (capped.isEmpty) {
        for (final p in open) {
          p.assignedMb += left * p.speed / speedSum;
        }
        left = 0;
      } else {
        for (final p in capped) {
          left -= p.capacityMb - p.assignedMb;
          p.assignedMb = p.capacityMb;
        }
        open = open.where((p) => !capped.contains(p)).toList();
      }
    }
  }

  /// LiteRT models can't be split across phones (the cluster is llama.cpp).
  /// When this phone is a master with workers, asks before loading one here
  /// alone. True to go ahead.
  Future<bool> confirmLiteRtRunsHere(String model) async {
    final context = Get.context;
    if (role != ClusterRole.master || workers.isEmpty || context == null)
      return true;
    final go = await showAppSheet<bool>(
      context,
      title: 'This model can\'t use your workers',
      subtitle:
          '${model.replaceAll(RegExp(r'\.(litertlm|task)$'), '')} is a LiteRT '
          'model, and only GGUF models can be shared across phones. It will run '
          'on this phone only. To use your workers, load a GGUF model instead.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Load on this phone only',
            icon: Icons.smartphone_rounded,
            onPressed: () => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(ctx,
              label: 'Cancel', onTap: () => Navigator.pop(ctx, false)),
        ],
      ),
    );
    return go == true;
  }

  /// "Fits on this phone" sheet. True to share with workers anyway.
  Future<bool> _askFitsHere(
      String model, double modelMb, int workerCount) async {
    final context = Get.context;
    if (context == null) return false;
    final share = await showAppSheet<bool>(
      context,
      title: 'This model fits on this phone',
      subtitle: '${model.replaceAll(RegExp(r'\.gguf$'), '')} needs about '
          '${_gb(modelMb)}, and this phone has room for it. Running it here '
          'is faster, because sharing sends every word over Wi-Fi. Share it '
          'to free up memory on this phone.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Load on this phone only',
            icon: Icons.smartphone_rounded,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(
            ctx,
            label:
                'Share with $workerCount worker${workerCount == 1 ? '' : 's'}',
            onTap: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    return share == true;
  }

  /// Reads where the model actually went after a cluster load. Workers'
  /// shares come from llama.cpp's per-device weight buffers; this phone's
  /// share is the rest of the file, because its own buffers overlap (the
  /// mapped file and the CPU's repacked copy of the same weights).
  Future<void> refreshSplit(String modelPath) async {
    final buffers = await LlamaCluster.lastLoadBuffers();
    final remote = <String, double>{};
    for (final b in buffers) {
      final open = b.name.indexOf('[');
      if (open < 0) continue;
      final endpoint = b.name.substring(open + 1, b.name.lastIndexOf(']'));
      final name =
          workers.firstWhereOrNull((w) => w.endpoint == endpoint)?.model ??
              endpoint;
      remote[name] = (remote[name] ?? 0) + b.mb;
    }
    final fileMb = await File(modelPath).length() / (1024 * 1024);
    final remoteMb = remote.values.fold<double>(0, (a, b) => a + b);
    split.assignAll([
      ClusterShare(deviceName.isEmpty ? 'This phone' : deviceName,
          math.max(0, fileMb - remoteMb),
          isThisPhone: true),
      for (final e in remote.entries) ClusterShare(e.key, e.value),
    ]);
  }

  void clearSplit() => split.clear();

  static String _gb(double mb) => '${(mb / 1024).toStringAsFixed(1)} GB';
}
