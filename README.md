# redux_devtools_client

Redux middleware that lets the Redux DevTools macOS viewer (`../../app`) watch
actions and state. The app hosts a WebSocket server (port 8765, next free port
if taken) and prints its address; the viewer connects to it. Pure Dart, depends
only on `redux`.

```dart
middleware: [
  if (!kReleaseMode)
    DevToolsMiddleware<AppState>(
      appName: 'arrow',
      stateToJson: (s) => s.toJson(),
    ).call,
]
```

Security: listens on loopback only by default (the iOS simulator and
`adb forward` both reach it); pass `allowLan: true` for a physical iPhone.
Requests carrying an `Origin` header (browser pages) are refused. In release
builds `enabled` defaults to false and the middleware only forwards actions.

Options: `port`, `allowLan`, `enabled`, `sendState`, `stateThrottle` (default 300 ms, trailing),
`historySize` (actions replayed to a late viewer, default 500), `redactKeys`
(defaults to password/token/otp/pin…), `stateSanitizer`, `actionSanitizer`,
`actionToJson`, `actionTypeOf`, `onLog` (default `print`). Call
`attach(store)` to start the server before the first action.
