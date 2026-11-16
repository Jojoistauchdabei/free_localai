import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/cluster_service.dart';

void main() {
  group('LocalCpuDevice', () {
    const cpu = LocalCpuDevice(
      name: 'AMD Ryzen 9 9900X',
      freeMemoryBytes: 53 * 1024 * 1024 * 1024,
      totalMemoryBytes: 60.4 ~/ 1 * 1024 * 1024 * 1024,
      integratedGpuMemoryBytes: 32 * 1024 * 1024 * 1024,
      logicalCores: 24,
      allocatedCores: 0,
      computeTops: 0.5,
    );

    test('subtracts the iGPU pool from free RAM', () {
      expect(cpu.usableMemoryBytes,
          (53 - 32) * 1024 * 1024 * 1024);
    });

    test('subtracts the iGPU pool from total RAM', () {
      expect(cpu.totalUsableMemoryBytes,
          cpu.totalMemoryBytes - 32 * 1024 * 1024 * 1024);
    });

    test('never goes below zero when the iGPU pool exceeds free RAM', () {
      const tiny = LocalCpuDevice(
        name: 'tiny',
        freeMemoryBytes: 2 * 1024 * 1024 * 1024,
        totalMemoryBytes: 8 * 1024 * 1024 * 1024,
        integratedGpuMemoryBytes: 4 * 1024 * 1024 * 1024,
        logicalCores: 8,
      );
      expect(tiny.usableMemoryBytes, 0);
      expect(tiny.totalUsableMemoryBytes, 4 * 1024 * 1024 * 1024);
    });

    test('without an iGPU the full RAM is usable', () {
      const plain = LocalCpuDevice(
        name: 'plain',
        freeMemoryBytes: 10 * 1024 * 1024 * 1024,
        totalMemoryBytes: 16 * 1024 * 1024 * 1024,
        logicalCores: 8,
      );
      expect(plain.integratedGpuMemoryBytes, 0);
      expect(plain.usableMemoryBytes, plain.freeMemoryBytes);
      expect(plain.totalUsableMemoryBytes, plain.totalMemoryBytes);
    });

    test('allocated cores: 0 means all cores', () {
      expect(cpu.effectiveCores, 24);
      expect(cpu.copyWith(allocatedCores: 12).effectiveCores, 12);
      // Clamp against the real core count.
      expect(cpu.copyWith(allocatedCores: 999).effectiveCores, 24);
    });

    test('copyWith keeps the iGPU pool and total RAM', () {
      final updated = cpu.copyWith(computeTops: 0.9, allocatedCores: 12);
      expect(updated.integratedGpuMemoryBytes, cpu.integratedGpuMemoryBytes);
      expect(updated.totalMemoryBytes, cpu.totalMemoryBytes);
      expect(updated.computeTops, 0.9);
      expect(updated.allocatedCores, 12);
    });
  });

  group('LocalGpuDevice', () {
    test('integrated flag survives copyWith', () {
      const igpu = LocalGpuDevice(
        index: 2,
        name: 'AMD Radeon 610M',
        freeMemoryBytes: 32 << 30,
        totalMemoryBytes: 32 << 30,
        memorySpeedGbps: 80,
        isIntegrated: true,
      );
      expect(igpu.isIntegrated, isTrue);
      expect(igpu.copyWith(selected: false).isIntegrated, isTrue);

      const dgpu = LocalGpuDevice(
        index: 0,
        name: 'AMD Radeon RX 5700 XT',
        freeMemoryBytes: 6 << 30,
        totalMemoryBytes: 8 << 30,
        memorySpeedGbps: 400,
      );
      expect(dgpu.isIntegrated, isFalse);
    });
  });
}
