import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:get/Get.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import 'app_log_service.dart';
import 'hive_service.dart';
import 'runtimes/runtime_engine.dart' show TrafficStats;
import 't3_code_ws_io.dart'
    if (dart.library.html) 't3_code_ws_web.dart' as t3ws;

/// Channel to the T3 Code server.
///
/// Inject one via [T3AgentService(connectSocket: ...)] in tests to fake the
/// WebSocket.
abstract class T3WsChannel {
  Future<void> get ready;
  Stream<String> get messages;
  void send(String message);
  Future<void> close();
}

typedef T3WsConnector = Future<T3WsChannel> Function(Uri url);

/// T3 Code agent — runs the user's messages on a T3 Code server through its
/// orchestration RPC.
class T3AgentService extends GetxService {
  T3AgentService({T3WsConnector? connectSocket})
      : _connectSocket = connectSocket ??
            ((url) async => t3ws.RealT3WsChannel(url));

  final T3WsConnector _connectSocket;
  final HiveService _hive = Get.find<HiveService>();
  final AppLogService _log = Get.find<AppLogService>();
  final _uuid = const Uuid();

  final status = 'disconnected'.obs; // 'connected', 'disconnected', 'resuming'
  final currentSessionTitle = ''.obs;
  final currentSessionState = ''.obs;
  final isConnected = false.obs;

  static const Set<String> _terminalRunStatuses = {
    'completed',
    'failed',
    'cancelled',
    'interrupted',
    'rolled_back',
  };
  static const Duration _ticketTimeout = Duration(seconds: 10);
  static const Duration _minReconnectDelay = Duration(seconds: 2);
  static const Duration _maxReconnectDelay = Duration(seconds: 30);

  _T3WsRpc? _rpc;
  final List<_StreamSession> _sessions = [];
  final Map<String, String> _textByItemId = {};
  int _sequence = 0;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _stopping = false;

  int bytesSent = 0;
  int bytesReceived = 0;

  String get serverUrl =>
      _hive.getSetting<String>(AppConstants.keyT3ServerUrl) ?? '';
  String get token => _hive.getSetting<String>(AppConstants.keyT3Token) ?? '';
  String? get cachedThreadId {
    final id = _hive.getSetting<String>(AppConstants.keyT3ThreadId);
    return id == null || id.isEmpty ? null : id;
  }

  int get cachedSequence => _hive.getSetting<int>(AppConstants.keyT3Sequence) ?? 0;

  TrafficStats get traffic => TrafficStats(
        bytesSent: _rpc?.bytesSent ?? 0,
        bytesReceived: _rpc?.bytesReceived ?? 0,
        activeConnections: isConnected.value ? 1 : 0,
        lastActivityAt: isConnected.value ? DateTime.now() : null,
      );

  // ─── Connection ─────────────────────────────────

  Future<void> connect() async {
    if (isConnected.value) return;
    _cancelReconnect();
    _stopping = false;
    status.value = 'resuming';
    try {
      final ticket = await _issueTicket();
      if (_disposed) return;
      final rpc = await _T3WsRpc.connect(
        _connectSocket,
        _wsUrl(ticket),
        onClosed: _onSocketClosed,
        onFrame: _handleStreamFrame,
      );
      if (_disposed) {
        await rpc.close();
        return;
      }
      _rpc = rpc;
      isConnected.value = true;
      status.value = 'connected';
    } catch (e) {
      _log.error('T3 Code connect failed', details: e);
      status.value = 'disconnected';
      rethrow;
    }
  }

  Future<void> disconnect() async {
    _cancelReconnect();
    _stopping = true;
    status.value = 'disconnected';
    isConnected.value = false;
    final sessions = List<_StreamSession>.of(_sessions);
    _sessions.clear();
    for (final session in sessions) session.complete();
    final rpc = _rpc;
    _rpc = null;
    if (rpc != null) await rpc.close();
    // Cache the session so reconnect() can resume it.
    await _hive.setSetting(AppConstants.keyT3ThreadId, cachedThreadId ?? '');
    await _hive.setSetting(AppConstants.keyT3Sequence, _sequence);
  }

  /// Reconnects to the server and resumes the cached thread at its cached
  /// sequence.
  Future<void> reconnect() async {
    _cancelReconnect();
    status.value = 'resuming';
    await disconnect();
    await connect();
    final rpc = _rpc;
    final threadId = cachedThreadId;
    if (rpc != null && threadId != null) {
      try {
        final projection = await rpc
            .request('orchestration.getThreadProjection', {'threadId': threadId});
        _applyProjection(projection);
        subscribe(threadId: threadId, afterSequence: cachedSequence);
      } catch (e) {
        _log.error('T3 Code resume failed', details: e);
      }
    }
    status.value = 'connected';
  }

  void _onSocketClosed() {
    if (_stopping) return;
    isConnected.value = false;
    status.value = 'disconnected';
    final sessions = List<_StreamSession>.of(_sessions);
    _sessions.clear();
    for (final session in sessions) session.complete();
    _scheduleReconnect();
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
  }

  void _scheduleReconnect() {
    final delay = math.min(
      _maxReconnectDelay,
      _minReconnectDelay * (_reconnectAttempts + 1),
    );
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (!isConnected.value) unawaited(reconnect());
    });
  }

  Future<String> _issueTicket() async {
    final base = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      throw Exception('T3 Server-URL nicht konfiguriert.');
    }
    final headers = {'Authorization': 'Bearer ${token.trim()}'};
    try {
      final response = await http
          .post(Uri.parse('$base/api/auth/websocket-ticket/rpc'), headers: headers)
          .timeout(_ticketTimeout);
      if (response.statusCode == 200) {
        final ticket = _ticketOf(response.body);
        if (ticket != null) return ticket;
        throw Exception('kein Ticket zurückgeliefert');
      }
    } catch (_) {
      // Older servers only expose the bare endpoint.
    }
    final response = await http
        .post(Uri.parse('$base/api/auth/websocket-ticket'), headers: headers)
        .timeout(_ticketTimeout);
    if (response.statusCode != 200) {
      throw Exception('Ticket-Anfrage fehlgeschlagen: ${response.statusCode}');
    }
    final ticket = _ticketOf(response.body);
    if (ticket == null) throw Exception('kein Ticket zurückgeliefert');
    return ticket;
  }

  String? _ticketOf(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final ticket = decoded['ticket'];
        if (ticket is String && ticket.isNotEmpty) return ticket;
      }
    } catch (_) {}
    return null;
  }

  Uri _wsUrl(String ticket) {
    final base = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final parsed = Uri.parse(base);
    return Uri(
      scheme: parsed.isScheme('https') ? 'wss' : 'ws',
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : null,
      path: '/ws',
      queryParameters: {
        'wsTicket': ticket,
        'orchestrationProtocol': '2',
      },
    );
  }

  // ─── Threads & Messages ──────────────────────────

  /// Thread the agent runs on. A cached [cachedThreadId] is verified with
  /// `orchestration.getThreadProjection`; otherwise a new thread is launched
  /// and its id cached in Hive.
  Future<String> openThread() async {
    final cached = cachedThreadId;
    if (cached != null && _rpc != null) {
      try {
        final projection =
            await _rpc!.request('orchestration.getThreadProjection', {'threadId': cached});
        _applyProjection(projection);
        return cached;
      } catch (_) {
        // Cached thread is gone; launch a new one below.
      }
    }
    if (_rpc == null) {
      throw StateError('T3 Server nicht verbunden.');
    }
    final result =
        await _rpc!.request('orchestration.launchThread', _launchPayload());
    final threadId = (result as Map)['threadId']?.toString() ?? '';
    if (threadId.isNotEmpty) {
      await _hive.setSetting(AppConstants.keyT3ThreadId, threadId);
    }
    return threadId;
  }

  Map<String, dynamic> _launchPayload() => {
        'commandId': 'free-localai-${DateTime.now().microsecondsSinceEpoch}',
        'projectId': 'free_localai',
        'title': 'Free LocalAI Chat',
        'modelSelection': {'instanceId': 'free_localai', 'model': 'local'},
        'runtimeMode': 'full-access',
        'interactionMode': 'default',
        'workspaceStrategy': {'type': 'root'},
      };

  /// Subscribes to the thread and forwards assistant text tokens to [onToken].
  Stream<String> subscribe({
    required String threadId,
    int? afterSequence,
    void Function(String token)? onToken,
  }) {
    final session = _StreamSession(threadId: threadId, onToken: onToken);
    _sessions.add(session);
    final input = <String, dynamic>{'threadId': threadId};
    if (afterSequence != null && afterSequence > 0) {
      input['afterSequence'] = afterSequence;
    }
    _rpc!.requestStream('orchestration.subscribeThread', input);
    return session.stream;
  }

  /// Sends [text] as a `message.dispatch` on the current thread and returns the
  /// final assistant text. Tokens arrive via [onToken].
  Future<String> sendMessage(
      {required String text, void Function(String token)? onToken}) async {
    await connect();
    final threadId = await openThread();
    final session =
        subscribe(threadId: threadId, afterSequence: cachedSequence, onToken: onToken);
    try {
      await _rpc!.request('orchestration.dispatchCommand',
          _dispatchPayload(threadId: threadId, text: text));
      return await session.done.future;
    } catch (e) {
      _log.error('T3 Code dispatch failed', details: e);
      return await session.done.future;
    } finally {
      session.complete();
      _sessions.remove(session);
    }
  }

  Map<String, dynamic> _dispatchPayload(
      {required String threadId, required String text}) {
    return {
      'type': 'message.dispatch',
      'commandId': 'free-localai-${DateTime.now().microsecondsSinceEpoch}',
      'threadId': threadId,
      'messageId': _uuid.v4(),
      'text': text,
      'attachments': <String>[],
      'dispatchMode': {'type': 'start_immediately'},
    };
  }

  // ─── Stream handling ─────────────────────────────

  void _handleStreamFrame(Map frame) {
    _handleStreamItem(frame);
  }

  void _handleStreamItem(Map item) {
    final sequence = (item['sequence'] as num?)?.toInt() ??
        (item['snapshotSequence'] as num?)?.toInt() ??
        _sequence;
    if (sequence > _sequence) {
      _sequence = sequence;
      unawaited(_hive.setSetting(AppConstants.keyT3Sequence, _sequence));
    }
    final kind = item['kind'];
    if (kind == 'snapshot') {
      _applyProjection(item['projection']);
    } else if (kind == 'event') {
      final event = item['event'];
      if (event is Map) _handleEvent(event);
    }
  }

  void _handleEvent(Map event) {
    final type = event['type'];
    final payload = event['payload'];
    if (payload is! Map) return;
    switch (type) {
      case 'message.updated':
        if (payload['role'] == 'assistant') {
          for (final session in List<_StreamSession>.of(_sessions)) {
            session.complete(text: payload['text']?.toString());
          }
        }
        break;
      case 'turn-item.updated':
        if (payload['type'] == 'assistant_message') {
          final id = payload['id']?.toString();
          final text = payload['text']?.toString() ?? '';
          if (id == null) break;
          final previous = _textByItemId[id] ?? '';
          if (text.startsWith(previous)) {
            final delta = text.substring(previous.length);
            if (delta.isNotEmpty) {
              _textByItemId[id] = text;
              for (final session in _sessions) session.emit(delta);
            }
          } else if (previous.isEmpty && text.isNotEmpty) {
            _textByItemId[id] = text;
            for (final session in _sessions) session.emit(text);
          }
        }
        break;
      case 'run.updated':
      case 'run.created':
        if (_isTerminalRun(payload)) {
          for (final session in List<_StreamSession>.of(_sessions)) {
            session.complete();
          }
        }
        break;
    }
  }

  bool _isTerminalRun(Map run) => _terminalRunStatuses.contains(run['status']);

  void _applyProjection(Map? projection) {
    if (projection == null) return;
    final thread = projection['thread'];
    if (thread is Map) {
      currentSessionTitle.value = thread['title']?.toString() ?? '';
    }
    final runs = projection['runs'];
    if (runs is List && runs.isNotEmpty) {
      final sorted = runs.whereType<Map>().toList()
        ..sort((a, b) => _ordinalOf(a).compareTo(_ordinalOf(b)));
      currentSessionState.value = sorted.last['status']?.toString() ?? '';
    } else {
      currentSessionState.value = 'idle';
    }
  }

  int _ordinalOf(Map run) => (run['ordinal'] as num?)?.toInt() ?? 0;

  @override
  void onClose() {
    _disposed = true;
    unawaited(disconnect());
    super.onClose();
  }
}

/// One subscription's state: tokens plus the stream handed to callers.
class _StreamSession {
  _StreamSession({required this.threadId, void Function(String)? onToken})
      : _onToken = onToken {
    _controller = StreamController<String>.broadcast();
  }

  final String threadId;
  final void Function(String)? _onToken;
  final _text = StringBuffer();
  final _controller;
  final done = Completer<String>();

  Stream<String> get stream => _controller!.stream;

  void emit(String delta) {
    _text.write(delta);
    _onToken?.call(delta);
    if (!_controller!.isClosed) _controller!.add(delta);
  }

  void complete({String? text}) {
    if (done.isCompleted) return;
    final finalText = text != null && text.isNotEmpty ? text : _text.toString();
    done.complete(finalText);
    if (!_controller!.isClosed) _controller!.close();
  }
}

class _RpcCall {
  _RpcCall(this.completer);
  final Completer<dynamic> completer;
}

class _RpcStream {
  _RpcStream(this.onDone);
  final void Function() onDone;
}

/// Minimal Effect RPC-over-WebSocket client. Frames use the same envelopes as
/// `RpcSerialization.layerJson` (see effect's `rpc/RpcMessage.ts`).
class _T3WsRpc {
  _T3WsRpc._(this._onFrame, this._onDisconnected);

  static const Duration _pingInterval = Duration(seconds: 5);

  final void Function(Map frame) _onFrame;
  final void Function() _onDisconnected;

  T3WsChannel? _channel;
  StreamSubscription? _sub;
  Timer? _pingTimer;
  int _nextId = 0;
  final Map<int, _RpcCall> _pending = {};
  final Map<int, _RpcStream> _streams = {};
  bool _closed = false;

  int bytesSent = 0;
  int bytesReceived = 0;

  static Future<_T3WsRpc> connect(
    T3WsConnector connector,
    Uri url, {
    required void Function() onClosed,
    required void Function(Map frame) onFrame,
  }) async {
    final rpc = _T3WsRpc._(onFrame, onClosed);
    rpc._channel = await connector(url);
    await rpc._channel!.ready;
    rpc._sub = rpc._channel!.messages.listen(rpc._onFrames,
        onDone: rpc._onChannelClosed,
        onError: (_) => rpc._onChannelClosed());
    rpc._pingTimer = Timer.periodic(
        _pingInterval, (_) => rpc._sendFrame({'_tag': 'Ping'}));
    return rpc;
  }

  Future<T> request<T>(String tag, [Map? payload]) {
    final id = _nextId++;
    final call = _RpcCall(Completer<dynamic>());
    _pending[id] = call;
    _sendFrame({
      '_tag': 'Request',
      'id': id,
      'tag': tag,
      'payload': payload ?? const {},
      'headers': const [],
    });
    return call.completer.future as Future<T>;
  }

  void requestStream(String tag, Map payload) {
    final id = _nextId++;
    _streams[id] = _RpcStream(() {});
    _sendFrame({
      '_tag': 'Request',
      'id': id,
      'tag': tag,
      'payload': payload,
      'headers': const [],
    });
  }

  void _sendFrame(Map frame) {
    final encoded = jsonEncode(frame);
    bytesSent += encoded.length;
    _channel?.send(encoded);
  }

  void _onFrames(String data) {
    try {
      bytesReceived += data.length;
      final decoded = jsonDecode(data);
      for (final frame in (decoded is List ? decoded : [decoded])) {
        _handleFrame(frame);
      }
    } catch (_) {}
  }

  void _handleFrame(dynamic frame) {
    if (frame is! Map) return;
    final tag = frame['_tag'];
    if (tag == 'Chunk') {
      final values = frame['values'];
      if (values is List) {
        for (final value in values) {
          if (value is Map) _onFrame(value);
        }
      }
    } else if (tag == 'Exit') {
      final id = frame['requestId'];
      final exit = frame['exit'];
      if (id != null && exit is Map) {
        final call = _pending.remove(id);
        if (call != null) {
          if (exit['_tag'] == 'Success') {
            call.completer.complete(exit['value']);
          } else {
            call.completer.completeError(_errorOf(exit));
          }
        }
        _streams.remove(id);
      }
    } else if (tag == 'Defect') {
      _failAll('Server-Defect: ${frame['defect']}');
    }
  }

  Object _errorOf(Map exit) {
    final cause = exit['cause'];
    if (cause is List) {
      for (final item in cause) {
        if (item is Map && item['_tag'] == 'Fail') {
          return item['error'] ?? 'RPC failure';
        }
      }
    }
    return 'RPC failure';
  }

  void _failAll(String reason) {
    if (_closed) return;
    _closed = true;
    _pingTimer?.cancel();
    for (final call in _pending.values) {
      if (!call.completer.isCompleted) {
        call.completer.completeError(StateError(reason));
      }
    }
    _pending.clear();
    final streams = List<_RpcStream>.of(_streams.values);
    _streams.clear();
    for (final stream in streams) stream.onDone();
  }

  void _onChannelClosed() {
    if (_closed) return;
    _failAll('Disconnected');
    _onDisconnected();
  }

  Future<void> close() async {
    _closed = true;
    _pingTimer?.cancel();
    _sub?.cancel();
    _failAll('Disconnected');
    await _channel?.close();
  }
}
