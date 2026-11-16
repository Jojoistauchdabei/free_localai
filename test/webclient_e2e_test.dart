import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart' show ChatMessage;
import 'package:privatelm/services/inference_linux_engine.dart';
import 'package:privatelm/services/inference_service.dart';
import 'package:privatelm/services/openai_server_service_io.dart';

/// Headless end-to-end driver for the chat web client:
///
/// Runs the real OpenAiServerService backed by the real Linux bridge engine
/// (libplm_bridge.so + llama.cpp) and a real GGUF model, and keeps the server
/// up until the file `/tmp/opencode/e2e_done` appears. While it runs, a
/// browser can chat at http://127.0.0.1:18123.
///
/// Run with:
///   LD_LIBRARY_PATH=build/linux/x64/debug:build/linux/x64/debug/bin \
///     flutter test test/webclient_e2e_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    // flutter_test mocks every HttpClient into an empty-400 stub; undo it.
    HttpOverrides.global = null;
  });

  test(
    'serves the chat web client with the real model',
    timeout: const Timeout(Duration(minutes: 30)),
    () async {
      const modelPath =
          '/home/jonas/Dokumente/models/lfm2.5-1.2b-instruct-q4_k_m.gguf';
      final inference = BridgeInference();
      Get.put<InferenceService>(inference);

      final engine = LinuxLlamaEngine();
      expect(LinuxLlamaEngine.bridgeAvailable, isTrue,
          reason: 'libplm_bridge.so must be on LD_LIBRARY_PATH');

      print('Loading model from $modelPath …');
      final error = await engine.loadModel(
        modelPath: modelPath,
        threads: Platform.numberOfProcessors - 2,
        contextSize: 4096,
      );
      expect(error, isNull, reason: 'model load failed');
      print('Model loaded.');

      final server = OpenAiServerService();
      await server.start(
        port: 18123,
        onLog: (m) => print('server: $m'),
      );
      await File('/tmp/opencode/e2e_start').writeAsString(
          'ready http://${server.localUrl!.replaceAll('http://', '')}\n');

      // Hold the server open for the browser test session.
      final done = File('/tmp/opencode/e2e_done');
      while (!await done.exists()) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      await done.delete();
      await server.stop();
      print('E2E session finished.');
    },
  );
}

/// A minimal InferenceService that computes on the real bridge engine.
class BridgeInference extends GetxService implements InferenceService {
  final engine = LinuxLlamaEngine();

  @override
  final isModelLoaded = true.obs;
  @override
  final isGenerating = false.obs;
  @override
  final loadedModelName = 'lfm2.5-1.2b-instruct-q4_k_m'.obs;
  @override
  final generationSource = ''.obs;
  @override
  final isVisionLoaded = false.obs;
  @override
  final loadedModelRuntime = 'gguf'.obs;

  int _stops = 0;
  Completer<void>? _stop;

  @override
  int get stopCount => _stops;

  @override
  Future<String> generate({
    required String prompt,
    String? systemPrompt,
    List<Map<String, String>>? conversationHistory,
    String source = 'chat',
    String? imagePath,
    String? audioPath,
    int? maxTokens,
    List<String> stopSequences = const [],
    void Function(String token)? onToken,
  }) async {
    isGenerating.value = true;
    generationSource.value = source;
    _stop = Completer<void>();

    final messages = <ChatMessage>[
      if (systemPrompt != null && systemPrompt.isNotEmpty)
        ChatMessage(role: 'system', content: systemPrompt),
      ...?conversationHistory?.map(
          (m) => ChatMessage(role: m['role'] ?? 'user', content: m['content'] ?? '')),
      ChatMessage(role: 'user', content: prompt),
    ];

    final out = StringBuffer();
    try {
      await for (final token in engine.generateChat(
        messages: messages,
        maxTokens: maxTokens ?? 512,
        temperature: 0.7,
        topP: 0.9,
        topK: 40,
        minP: 0.05,
        repeatPenalty: 1.1,
        repeatLastN: 64,
      )) {
        out.write(token);
        onToken?.call(token);
      }
    } finally {
      isGenerating.value = false;
      generationSource.value = '';
    }
    return out.toString();
  }

  @override
  Future<void> stopGeneration() async {
    _stops++;
    await engine.stop();
    isGenerating.value = false;
    if (_stop != null && !_stop!.isCompleted) _stop!.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
