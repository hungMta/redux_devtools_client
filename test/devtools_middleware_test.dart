import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:redux/redux.dart';
import 'package:redux_devtools_client/redux_devtools_client.dart';
import 'package:test/test.dart';

class Increment {
  Increment(this.by);
  final int by;
  String get type => 'INCREMENT';
  Map<String, dynamic> toJson() => {'by': by, 'token': 'secret'};
}

Store<int> buildStore(DevToolsMiddleware<int> devtools) => Store<int>(
  (state, action) => action is Increment ? state + action.by : state,
  initialState: 0,
  middleware: [devtools.call],
);

Future<(WebSocket, StreamIterator<Map<String, dynamic>>)> connectViewer(
  DevToolsMiddleware<int> devtools,
) async {
  final port = await devtools.listeningPort;
  final socket = await WebSocket.connect('ws://localhost:$port');
  final messages = StreamIterator(
    socket.map((data) => jsonDecode(data as String) as Map<String, dynamic>),
  );
  return (socket, messages);
}

Future<List<Map<String, dynamic>>> take(
  StreamIterator<Map<String, dynamic>> messages,
  int count,
) async {
  final got = <Map<String, dynamic>>[];
  while (got.length < count &&
      await messages.moveNext().timeout(const Duration(seconds: 5))) {
    got.add(messages.current);
  }
  return got;
}

void main() {
  test('a late viewer gets INIT with current state, then history', () async {
    final logs = <String>[];
    final devtools = DevToolsMiddleware<int>(
      port: 0,
      stateToJson: (s) => {'count': s},
      stateThrottle: Duration.zero,
      onLog: logs.add,
    );
    final store = buildStore(devtools);
    store.dispatch(Increment(2));
    store.dispatch(Increment(3));

    final (socket, messages) = await connectViewer(devtools);
    final got = await take(messages, 3);
    expect(got.map((m) => m['type']), ['INIT', 'ACTION', 'ACTION']);
    expect(got[0]['lastActionId'], 2);
    expect(jsonDecode(got[0]['stateJson']), {'count': 5});
    expect(got[1]['payload'], {'by': 2, 'token': '<redacted>'});
    expect(got[1].containsKey('stateJson'), isFalse);
    expect(logs.any((l) => l.contains('listening on ws://localhost:')), isTrue);

    store.dispatch(Increment(1));
    final live = (await take(messages, 1)).single;
    expect(live['id'], 3);
    expect(jsonDecode(live['stateJson']), {'count': 6});

    socket.add(jsonEncode({'type': 'REQUEST_STATE'}));
    final state = (await take(messages, 1)).single;
    expect(state['type'], 'STATE');
    expect(state['afterActionId'], 3);

    await socket.close();
    await devtools.dispose();
  });

  test('throttled actions get a trailing STATE with the latest state', () async {
    final devtools = DevToolsMiddleware<int>(
      port: 0,
      stateToJson: (s) => s,
      stateThrottle: const Duration(milliseconds: 200),
      onLog: (_) {},
    );
    final store = buildStore(devtools);
    devtools.attach(store);
    final (socket, messages) = await connectViewer(devtools);
    expect((await take(messages, 1)).single['type'], 'INIT');

    store.dispatch(Increment(1));
    store.dispatch(Increment(1));
    store.dispatch(Increment(1));

    final got = await take(messages, 4);
    expect(got.map((m) => m['type']), ['ACTION', 'ACTION', 'ACTION', 'STATE']);
    expect(got.take(3).any((m) => m.containsKey('stateJson')), isFalse);
    expect(got[3]['afterActionId'], 3);
    expect(got[3]['stateJson'], '3');

    await socket.close();
    await devtools.dispose();
  });

  test('keeps only historySize actions and never throws without viewers',
      () async {
    final devtools = DevToolsMiddleware<int>(
      port: 0,
      stateToJson: (s) => s,
      historySize: 10,
      onLog: (_) {},
    );
    final store = buildStore(devtools);
    for (var i = 0; i < 500; i++) {
      store.dispatch(Increment(1));
    }
    expect(store.state, 500);

    final (socket, messages) = await connectViewer(devtools);
    final got = await take(messages, 11);
    expect(got.first['lastActionId'], 500);
    expect(got.skip(1).map((m) => m['id']), List.generate(10, (i) => 491 + i));
    await socket.close();
    await devtools.dispose();
  });

  test('serves app info over HTTP for discovery', () async {
    final devtools = DevToolsMiddleware<int>(
      port: 0,
      appName: 'demo',
      stateToJson: (s) => s,
      onLog: (_) {},
    );
    devtools.attach(buildStore(devtools));
    final port = await devtools.listeningPort;
    final client = HttpClient();
    final request = await client.get('localhost', port!, '/info');
    final body = await (await request.close()).transform(utf8.decoder).join();
    final info = jsonDecode(body);
    expect(info['reduxDevTools'], 1);
    expect(info['appName'], 'demo');
    client.close();
    await devtools.dispose();
  });

  test('moves to the next port when the first is taken', () async {
    final blocker = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final devtools = DevToolsMiddleware<int>(
      port: blocker.port,
      stateToJson: (s) => s,
      onLog: (_) {},
    );
    devtools.attach(buildStore(devtools));
    expect(await devtools.listeningPort, isNot(blocker.port));
    await devtools.dispose();
    await blocker.close();
  });
}
