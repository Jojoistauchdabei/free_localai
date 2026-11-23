import 'dart:async';
import 'dart:io';

import 't3_agent_service.dart';

/// Real channel on native platforms, built on `dart:io` WebSocket.
class RealT3WsChannel implements T3WsChannel {
  RealT3WsChannel(Uri url) {
    _socket = WebSocket.connect(url.toString());
    _ready = Completer<void>();
    _controller = StreamController<String>.broadcast();
    _socket.then((socket) {
      _socket = socket;
      _ready!.complete();
      socket.cast<String>().listen((message) => _controller!.add(message),
          onDone: _closed);
    }, onError: (Object e) {
      _ready?.completeError(e);
      _closed();
    });
  }

  Future<WebSocket>? _socket;
  Completer<void>? _ready;
  StreamController<String>? _controller;
  bool _isClosed = false;

  @override
  Future<void> get ready => _ready!.future;

  @override
  Stream<String> get messages => _controller!.stream;

  @override
  void send(String message) {
    _socket?.then((socket) => socket.add(message));
  }

  @override
  Future<void> close() async {
    _isClosed = true;
    await _socket?.then((socket) => socket.close());
  }

  void _closed() {
    if (_isClosed) return;
    _isClosed = true;
    _controller!.close();
  }
}
