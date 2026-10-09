/// Message types exchanged with the desktop viewer.
///
/// The app hosts a WebSocket server; viewers connect to it. Every message is a
/// JSON object with a `type` field. State travels as a JSON-encoded string
/// (`stateJson`) so the viewer can keep it unparsed until someone opens it.
abstract final class DevToolsMessageType {
  /// app → viewer, first message on connect:
  /// `instanceId, appName, platform, lastActionId, stateJson`
  static const init = 'INIT';

  /// app → viewer: `id, ts, actionType, payload, stateJson?`
  ///
  /// Right after INIT the app replays recent actions (ids up to
  /// `lastActionId`) without state.
  static const action = 'ACTION';

  /// app → viewer: `afterActionId, stateJson`
  static const state = 'STATE';

  /// viewer → app: no fields
  static const requestState = 'REQUEST_STATE';
}

const kDevToolsDefaultPort = 8765;

/// True in release (product) builds, where the middleware turns itself off.
const bool kDevToolsReleaseBuild = bool.fromEnvironment('dart.vm.product');
