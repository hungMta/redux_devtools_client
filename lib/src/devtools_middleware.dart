import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:redux/redux.dart';

import 'devtools_host.dart';
import 'json_safe.dart';
import 'protocol.dart';

typedef JsonSanitizer = Object? Function(Object? json);

/// Redux middleware that lets the Redux DevTools desktop viewer watch every
/// action and the state after it.
///
/// The app hosts a WebSocket server (default port 8765, printed to the console
/// on start); the viewer connects to it, like Flutter DevTools. Add `.call` to
/// the store's middleware list in debug builds only; in a release build it
/// passes actions through and never opens a port, even if left in. Nothing
/// here throws into the app: errors go to [onLog] and are otherwise ignored.
///
/// While no viewer is connected only the last [historySize] actions are kept
/// (without state), so an idle DevTools costs almost nothing. A viewer that
/// connects gets the current state and that history first.
///
/// State is sent at most once per [stateThrottle]. Actions inside the window go
/// out without state, and a trailing `STATE` message carries the state after
/// the last of them, so no change is lost; the viewer groups those actions.
class DevToolsMiddleware<S> {
  DevToolsMiddleware({
    required this.stateToJson,
    this.actionToJson,
    this.actionTypeOf,
    this.port = kDevToolsDefaultPort,
    this.allowLan = false,
    this.enabled = !kDevToolsReleaseBuild,
    this.appName = 'app',
    this.sendState = true,
    this.stateThrottle = const Duration(milliseconds: 300),
    this.historySize = 500,
    this.redactKeys = kDefaultRedactKeys,
    this.stateSanitizer,
    this.actionSanitizer,
    void Function(String message)? onLog,
  }) : onLog = onLog ?? print;

  /// Converts the store state to something JSON-like. Need not be pure JSON:
  /// the result goes through [toJsonSafe].
  final Object? Function(S state) stateToJson;

  /// Converts an action to JSON-like data. Defaults to `toJson()` when the
  /// action has one, else `{type, value: toString()}`.
  final Object? Function(dynamic action)? actionToJson;

  /// Label shown in the action list. Defaults to `action.type` when present,
  /// else the runtime type.
  final String Function(dynamic action)? actionTypeOf;

  /// First port to try; the next 9 are tried if it is taken. 0 picks any.
  final int port;

  /// Also listen on the LAN, for a physical iPhone. Off by default: anyone on
  /// the same network could then read the state.
  final bool allowLan;

  /// When false the middleware only forwards actions. Defaults to false in
  /// release builds.
  final bool enabled;
  final String appName;
  final bool sendState;
  final Duration stateThrottle;

  /// Actions replayed to a viewer that connects later.
  final int historySize;

  /// Map keys (lower-case) whose values are replaced with `<redacted>` in both
  /// state and payloads.
  final Set<String> redactKeys;
  final JsonSanitizer? stateSanitizer;
  final JsonSanitizer? actionSanitizer;

  /// Defaults to `print`, so the listening address shows in the run console.
  final void Function(String message) onLog;

  final String _instanceId = _randomId();
  final Queue<Map<String, Object?>> _history = Queue();
  Store<S>? _store;
  DevToolsHost? _host;
  int _seq = 0;
  DateTime? _lastStateSentAt;
  Timer? _trailingStateTimer;
  int? _pendingStateActionId;

  /// The port the app listens on once started, or null if none was free.
  Future<int?> get listeningPort async =>
      enabled ? _ensureHost().listeningPort : null;

  /// Starts the server before the first action, so the address is printed at
  /// launch. Optional: the first dispatched action starts it too.
  void attach(Store<S> store) {
    if (!enabled) return;
    _store = store;
    _ensureHost();
  }

  void call(Store<S> store, dynamic action, NextDispatcher next) {
    next(action);
    if (!enabled) return;
    try {
      _store = store;
      _ensureHost();
      _recordAction(action);
    } catch (e) {
      _log('$e');
    }
  }

  DevToolsHost _ensureHost() {
    final existing = _host;
    if (existing != null) return existing;
    final host = DevToolsHost(
      port: port,
      allowLan: allowLan,
      onViewerConnected: _onViewerConnected,
      onViewerMessage: _onViewerMessage,
      info: () => {
        'instanceId': _instanceId,
        'appName': appName,
        'platform': Platform.operatingSystem,
      },
      onLog: _log,
    );
    _host = host;
    unawaited(host.start());
    return host;
  }

  void _recordAction(dynamic action) {
    final id = ++_seq;
    final now = DateTime.now();
    final message = <String, Object?>{
      'type': DevToolsMessageType.action,
      'id': id,
      'ts': now.millisecondsSinceEpoch,
      'actionType': _actionType(action),
      'payload': _encodeAction(action),
    };
    _history.addLast(message);
    while (_history.length > historySize) {
      _history.removeFirst();
    }

    final host = _host;
    if (host == null || !host.hasViewers) return;

    if (sendState) {
      final last = _lastStateSentAt;
      if (last == null || now.difference(last) >= stateThrottle) {
        _lastStateSentAt = now;
        _pendingStateActionId = null;
        host.broadcast(jsonEncode({...message, 'stateJson': _encodeState()}));
        return;
      }
      _pendingStateActionId = id;
      _trailingStateTimer ??= Timer(
        stateThrottle - now.difference(last),
        _flushTrailingState,
      );
    }
    host.broadcast(jsonEncode(message));
  }

  void _flushTrailingState() {
    _trailingStateTimer = null;
    final actionId = _pendingStateActionId;
    if (actionId == null) return;
    _pendingStateActionId = null;
    _lastStateSentAt = DateTime.now();
    _host?.broadcast(_stateMessage(afterActionId: actionId));
  }

  String _stateMessage({int? afterActionId}) => jsonEncode({
    'type': DevToolsMessageType.state,
    'afterActionId': afterActionId ?? _seq,
    'stateJson': _encodeState(),
  });

  void _onViewerConnected(WebSocket viewer) {
    final host = _host;
    if (host == null) return;
    try {
      host.sendTo(
        viewer,
        jsonEncode({
          'type': DevToolsMessageType.init,
          'instanceId': _instanceId,
          'appName': appName,
          'platform': Platform.operatingSystem,
          'lastActionId': _seq,
          'stateJson': sendState ? _encodeState() : null,
        }),
      );
      _lastStateSentAt = DateTime.now();
      for (final message in _history) {
        host.sendTo(viewer, jsonEncode(message));
      }
    } catch (e) {
      _log('$e');
    }
  }

  void _onViewerMessage(WebSocket viewer, String raw) {
    try {
      final message = jsonDecode(raw);
      if (message is Map &&
          message['type'] == DevToolsMessageType.requestState) {
        _host?.sendTo(viewer, _stateMessage());
      }
    } catch (e) {
      _log('$e');
    }
  }

  String? _encodeState() {
    final store = _store;
    if (store == null) return null;
    Object? json;
    try {
      json = toJsonSafe(stateToJson(store.state), redactKeys: redactKeys);
      json = stateSanitizer?.call(json) ?? json;
    } catch (e) {
      json = {'<error>': e.toString()};
    }
    return jsonEncode(json);
  }

  Object? _encodeAction(dynamic action) {
    Object? json;
    try {
      final custom = actionToJson;
      json = custom != null
          ? custom(action)
          : toJsonSafe(action, redactKeys: redactKeys);
      json = toJsonSafe(json, redactKeys: redactKeys);
      json = actionSanitizer?.call(json) ?? json;
    } catch (e) {
      json = {'<error>': e.toString()};
    }
    if (json is String && action is! String) {
      return {'type': _actionType(action), 'value': json};
    }
    return json;
  }

  String _actionType(dynamic action) {
    try {
      final custom = actionTypeOf;
      if (custom != null) return custom(action);
      if (action is String) return action;
      try {
        final type = (action as dynamic).type;
        if (type != null) return type.toString();
      } on NoSuchMethodError {
        // Falls through to the runtime type.
      }
    } catch (_) {}
    return action.runtimeType.toString();
  }

  void _log(String message) {
    try {
      onLog('[redux_devtools] $message');
    } catch (_) {}
  }

  /// Closes the server and every viewer connection.
  Future<void> dispose() async {
    _trailingStateTimer?.cancel();
    await _host?.close();
  }

  static String _randomId() {
    final random = Random();
    return List.generate(
      12,
      (_) => random.nextInt(36).toRadixString(36),
    ).join();
  }
}
