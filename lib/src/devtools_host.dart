import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// WebSocket server inside the app that DevTools viewers connect to.
///
/// Tries [port], then the next [portAttempts] - 1 ports, so several apps (or
/// simulators sharing the Mac's network) can run side by side.
class DevToolsHost {
  DevToolsHost({
    required this.port,
    this.portAttempts = 10,
    required this.onViewerConnected,
    required this.onViewerMessage,
    this.info,
    this.onLog,
  });

  final int port;
  final int portAttempts;
  final void Function(WebSocket viewer) onViewerConnected;
  final void Function(WebSocket viewer, String message) onViewerMessage;
  final void Function(String message)? onLog;

  /// Served as JSON at `GET /info`, so the viewer can find and label apps.
  final Map<String, Object?> Function()? info;

  final Set<WebSocket> _viewers = {};
  HttpServer? _server;
  final Completer<int?> _ready = Completer();

  /// The bound port, or null if no port in the range was free.
  Future<int?> get listeningPort => _ready.future;

  bool get hasViewers => _viewers.isNotEmpty;

  Future<void> start() async {
    final attempts = port == 0 ? 1 : portAttempts;
    for (var i = 0; i < attempts; i++) {
      try {
        final server = await HttpServer.bind(InternetAddress.anyIPv4, port + i);
        _server = server;
        server.listen((request) => unawaited(_handle(request)));
        _ready.complete(server.port);
        await _announce(server.port);
        return;
      } on SocketException {
        continue;
      }
    }
    onLog?.call(
      'could not listen on ports $port-${port + attempts - 1}, DevTools disabled',
    );
    _ready.complete(null);
  }

  Future<void> _announce(int boundPort) async {
    final urls = ['ws://localhost:$boundPort'];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) urls.add('ws://${address.address}:$boundPort');
        }
      }
    } catch (_) {}
    onLog?.call('Redux DevTools listening on ${urls.join('  ')}');
  }

  Future<void> _handle(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      if (request.uri.path == '/info') {
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'reduxDevTools': 1, ...?info?.call()}));
        await request.response.close();
        return;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..write('Redux DevTools endpoint. Connect with the DevTools app.');
      await request.response.close();
      return;
    }
    final WebSocket viewer;
    try {
      viewer = await WebSocketTransformer.upgrade(request);
    } catch (_) {
      return;
    }
    _viewers.add(viewer);
    onLog?.call('viewer connected (${_viewers.length})');
    viewer.listen(
      (data) {
        if (data is String) onViewerMessage(viewer, data);
      },
      onDone: () {
        _viewers.remove(viewer);
        onLog?.call('viewer disconnected (${_viewers.length})');
      },
      onError: (_) {},
      cancelOnError: true,
    );
    onViewerConnected(viewer);
  }

  void sendTo(WebSocket viewer, String message) {
    try {
      viewer.add(message);
    } catch (_) {
      _viewers.remove(viewer);
    }
  }

  void broadcast(String message) {
    for (final viewer in _viewers.toList()) {
      sendTo(viewer, message);
    }
  }

  Future<void> close() async {
    for (final viewer in _viewers.toList()) {
      await viewer.close();
    }
    _viewers.clear();
    await _server?.close(force: true);
  }
}
