import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:uath_desktop/bridge/bridge_hub.dart';
import 'package:uath_desktop/bridge/protocol.dart';

class BridgeWsServer {
  BridgeWsServer(this.hub);

  final BridgeHub hub;
  HttpServer? _server;
  Timer? _retryTimer;
  var _stopping = false;

  bool get isListening => _server != null;

  Future<void> start() async {
    _stopping = false;
    await _bind();
  }

  Future<void> _bind() async {
    if (_stopping || _server != null) {
      return;
    }
    try {
      final handler = webSocketHandler((socket, _) => hub.handleSocket(socket));
      _server = await shelf_io.serve(
        handler,
        InternetAddress.loopbackIPv4,
        BridgeProtocol.port,
      );
      hub.setWsListening(true, error: null);
      _retryTimer?.cancel();
      _retryTimer = null;
    } catch (error) {
      hub.setWsListening(
        false,
        error: 'Port ${BridgeProtocol.port} unavailable - quit other bridge '
            'instances and keep this window open.',
      );
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 2), () {
        unawaited(_bind());
      });
      rethrow;
    }
  }

  Future<void> stop() async {
    _stopping = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _server?.close(force: true);
    _server = null;
    hub.setWsListening(false, error: null);
  }
}
