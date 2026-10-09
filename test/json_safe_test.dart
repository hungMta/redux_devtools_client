import 'package:redux_devtools_client/redux_devtools_client.dart';
import 'package:test/test.dart';

enum Side { buy }

class WithJson {
  Map<String, dynamic> toJson() => {'a': 1, 'when': DateTime.utc(2026)};
}

class Throws {
  Map<String, dynamic> toJson() => throw StateError('boom');
}

class Plain {
  @override
  String toString() => 'Plain()';
}

void main() {
  test('converts nested objects, enums, dates and non-string keys', () {
    final result = toJsonSafe({
      1: Side.buy,
      'obj': WithJson(),
      'set': {1, 2},
      'plain': Plain(),
      'nan': double.nan,
    });
    expect(result, {
      '1': 'buy',
      'obj': {'a': 1, 'when': '2026-01-01T00:00:00.000Z'},
      'set': [1, 2],
      'plain': 'Plain()',
      'nan': 'NaN',
    });
  });

  test('a failing toJson does not throw', () {
    expect(toJsonSafe({'x': Throws()}), {'x': startsWith('<error:')});
  });

  test('redacts keys case-insensitively at any depth', () {
    final result = toJsonSafe({
      'auth': {'accessToken': 'abc', 'user': 'u'},
      'list': [
        {'Password': 'p'},
      ],
    }, redactKeys: kDefaultRedactKeys);
    expect(result, {
      'auth': {'accessToken': '<redacted>', 'user': 'u'},
      'list': [
        {'Password': '<redacted>'},
      ],
    });
  });
}
