import 'dart:io';

class EngineDef {
  final String id;
  final String name;
  final String org;
  final String repo;
  final String defaultBranch;

  const EngineDef({
    required this.id,
    required this.name,
    required this.org,
    required this.repo,
    required this.defaultBranch,
  });

  String get repoUrl => 'https://github.com/$org/$repo';

  String zipballUrl([String? branch]) =>
      'https://github.com/$org/$repo/archive/refs/heads/${branch ?? defaultBranch}.zip';
}

const List<EngineDef> engines = <EngineDef>[
  EngineDef(
      id: 'llama_cpp',
      name: 'llama.cpp',
      org: 'ggml-org',
      repo: 'llama.cpp',
      defaultBranch: 'master'),
  EngineDef(
      id: 'bitnet_cpp',
      name: 'BitNet.cpp',
      org: 'microsoft',
      repo: 'BitNet',
      defaultBranch: 'main'),
  EngineDef(
      id: 'stable_diffusion_cpp',
      name: 'stable-diffusion.cpp',
      org: 'leejet',
      repo: 'stable-diffusion.cpp',
      defaultBranch: 'master'),
  EngineDef(
      id: 'exo',
      name: 'Exo',
      org: 'exo-explore',
      repo: 'exo',
      defaultBranch: 'main'),
  EngineDef(
      id: 'litert',
      name: 'LiteRT',
      org: 'google-ai-edge',
      repo: 'LiteRT',
      defaultBranch: 'main'),
];

const String defaultDest = 'native/engines';

Future<void> main(List<String> args) async {
  final argSet = args.toSet();
  final dryRun = argSet.contains('--dry-run');
  final listOnly = argSet.contains('--list');
  final destIndex = args.indexOf('--dest');
  final dest = destIndex >= 0 && destIndex + 1 < args.length
      ? args[destIndex + 1]
      : defaultDest;
  final onlyIndex = args.indexOf('--only');
  final only = onlyIndex >= 0 && onlyIndex + 1 < args.length
      ? args[onlyIndex + 1].split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet()
      : const <String>{};

  if (listOnly) {
    for (final engine in engines) {
      print('${engine.id}\t${engine.name}\t${engine.zipballUrl()}');
    }
    return;
  }

  final client = HttpClient();
  try {
    for (final engine in engines) {
      if (only.isNotEmpty &&
          !only.contains(engine.id) &&
          !only.contains(engine.name)) {
        continue;
      }
      final url = engine.zipballUrl();
      final targetDir = '$dest/${engine.id}';
      final zipName = '${engine.repo}-${engine.defaultBranch}.zip';
      final target = '$targetDir/$zipName';
      print('== ${engine.name} (${engine.repoUrl}) — $url');
      if (dryRun) continue;
      try {
        final dir = Directory(targetDir);
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          print('   ERROR: HTTP ${response.statusCode} — skipping ${engine.id}');
          continue;
        }
        final file = File(target);
        final sink = file.openWrite();
        await for (final chunk in response) {
          sink.add(chunk);
        }
        await sink.close();
        final size = await file.length();
        print('   downloaded: $target (${_formatBytes(size)})');
        final extracted = await _extractWithTar(file, targetDir);
        if (extracted) {
          print('   extracted to: $targetDir');
        } else {
          print('   note: tar extraction unavailable — extracted zipball kept at $target');
        }
      } catch (e) {
        print('   ERROR: $e');
      }
    }
  } finally {
    client.close();
  }
}

Future<bool> _extractWithTar(File zip, String destDir) async {
  try {
    final result = await Process.run('tar', ['-xf', zip.path, '-C', destDir]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}
