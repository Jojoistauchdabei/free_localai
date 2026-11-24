import 'dart:async';
import 'dart:js_interop';

import 't3_agent_service.dart';

@JS()
extension type _JSWebSocket(JSObject _) {
  external _JSWebSocket(String url);
  external void send(JSString data);
  external void close();
  external void addEventListener(JSString type, JSFunction? callback);
}

@JS()
extension type _JSWebSocketEvent(JSObject _) implements JSObject {
  external JSAny? get data;
}

/// Real channel on web, built on the browser WebSocket API.
class RealT3WsChannel implements T3WsChannel {
  RealT3WsChannel(Uri url) {
    _socket = _JSWebSocket(url.toString());
    _ready = Completer<void>();
    _controller = StreamController<String>.broadcast();
    _socket.addEventListener('open'.toJS, ((JSAny? _) {
      if (!_ready!.isCompleted) _ready!.complete();
    }).toJS);
    _socket.addEventListener('message'.toJS, ((JSAny? event) {
      final data = (event as _JSWebSocketEvent?)?.data?.dartify();
      if (data is String) _controller!.add(data);
    }).toJS);
    _socket.addEventListener('error'.toJS, ((JSAny? _) {
      if (!_ready!.isCompleted) {
        _ready!.completeError(StateError('WebSocket error'));
      }
    }).toJS);
    _socket.addEventListener('close'.toJS, ((JSAny? _) {
      if (!_controller!.isClosed) _controller!.close();
    }).toJS);
  }

  _JSWebSocket? _socket;
  Completer<void>? _ready;
  StreamController<String>? _controller;

  @override
  Future<void> get ready => _ready!.future;

  @override
  Stream<String> get messages => _controller!.stream;

  @override
  void send(String message) {
    _socket?.send(message.toJS);
  }

  @override
  Future<void> close() async {
    _socket?.close();
    await _controller?.close();
  }
}
