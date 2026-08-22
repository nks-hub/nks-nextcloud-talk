import 'dart:collection';

import 'protocol_exception.dart';

const int _maximumJsonDepth = 64;
const int _maximumJsonNodes = 10000;

Map<String, Object?> requireObject(
  Object? value, {
  required String path,
  required TalkProtocolErrorCode code,
}) {
  if (value is! Map<Object?, Object?>) {
    protocolFailure(code, path);
  }

  final result = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      protocolFailure(code, path);
    }
    result[key] = entry.value;
  }
  return RedactedMapView(result);
}

List<Object?> requireList(
  Object? value, {
  required String path,
  required TalkProtocolErrorCode code,
}) {
  if (value is! List<Object?>) {
    protocolFailure(code, path);
  }
  return RedactedListView(value);
}

String requireString(
  Object? value, {
  required String path,
  required TalkProtocolErrorCode code,
  int minLength = 0,
  int? maxLength,
}) {
  if (value is! String ||
      value.length < minLength ||
      (maxLength != null && value.length > maxLength)) {
    protocolFailure(code, path);
  }
  return value;
}

bool requireBool(
  Object? value, {
  required String path,
  required TalkProtocolErrorCode code,
}) {
  if (value is! bool) {
    protocolFailure(code, path);
  }
  return value;
}

int requireInt(
  Object? value, {
  required String path,
  required TalkProtocolErrorCode code,
  int? minimum,
  int? maximum,
}) {
  if (value is! int ||
      (minimum != null && value < minimum) ||
      (maximum != null && value > maximum)) {
    protocolFailure(code, path);
  }
  return value;
}

Set<String> requireUniqueStringSet(
  Object? value, {
  required String path,
  required TalkProtocolErrorCode code,
}) {
  final values = requireList(value, path: path, code: code);
  final result = <String>{};
  for (var index = 0; index < values.length; index++) {
    final item = requireString(
      values[index],
      path: '$path[$index]',
      code: code,
    );
    if (!result.add(item)) {
      protocolFailure(code, path);
    }
  }
  return RedactedSetView(result);
}

Object? freezeJson(Object? value) {
  return JsonFreezeSession().freeze(value);
}

final class JsonFreezeSession {
  JsonFreezeSession({
    int maximumDepth = _maximumJsonDepth,
    int maximumNodes = _maximumJsonNodes,
    this.errorCode = TalkProtocolErrorCode.invalidCapabilities,
    this.errorPath = r'$.ocs.data.capabilities',
  }) : _maximumDepth = maximumDepth,
       _remainingNodes = maximumNodes {
    if (maximumDepth < 0 || maximumNodes < 1) {
      throw ArgumentError('JSON freeze limits must be positive.');
    }
  }

  final int _maximumDepth;
  int _remainingNodes;
  final TalkProtocolErrorCode errorCode;
  final String errorPath;

  Object? freeze(Object? value) => _freeze(value, depth: 0);

  Object? _freeze(Object? value, {required int depth}) {
    if (depth > _maximumDepth) {
      protocolFailure(errorCode, errorPath);
    }
    _remainingNodes--;
    if (_remainingNodes < 0) {
      protocolFailure(errorCode, errorPath);
    }

    if (value is Map<Object?, Object?>) {
      final result = <String, Object?>{};
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) {
          protocolFailure(errorCode, errorPath);
        }
        result[key] = _freeze(entry.value, depth: depth + 1);
      }
      return RedactedMapView(result);
    }
    if (value is List<Object?>) {
      return RedactedListView(
        value.map((item) => _freeze(item, depth: depth + 1)),
      );
    }
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    protocolFailure(errorCode, errorPath);
  }
}

final class RedactedMapView<K, V> extends MapBase<K, V> {
  RedactedMapView(Map<K, V> source) : _source = Map<K, V>.unmodifiable(source);

  final Map<K, V> _source;

  @override
  V? operator [](Object? key) => _source[key];

  @override
  void operator []=(K key, V value) =>
      throw UnsupportedError('Cannot modify an immutable map.');

  @override
  void clear() => throw UnsupportedError('Cannot modify an immutable map.');

  @override
  Iterable<K> get keys => _source.keys;

  @override
  V? remove(Object? key) =>
      throw UnsupportedError('Cannot modify an immutable map.');

  @override
  String toString() => '{<redacted>}';
}

final class RedactedListView<E> extends ListBase<E> {
  RedactedListView(Iterable<E> source) : _source = List<E>.unmodifiable(source);

  final List<E> _source;

  @override
  E operator [](int index) => _source[index];

  @override
  void operator []=(int index, E value) =>
      throw UnsupportedError('Cannot modify an immutable list.');

  @override
  int get length => _source.length;

  @override
  set length(int value) =>
      throw UnsupportedError('Cannot modify an immutable list.');

  @override
  String toString() => '[<redacted>]';
}

final class RedactedSetView<E> extends SetBase<E> {
  RedactedSetView(Iterable<E> source) : _source = Set<E>.unmodifiable(source);

  final Set<E> _source;

  @override
  bool add(E value) =>
      throw UnsupportedError('Cannot modify an immutable set.');

  @override
  bool contains(Object? element) => _source.contains(element);

  @override
  Iterator<E> get iterator => _source.iterator;

  @override
  int get length => _source.length;

  @override
  E? lookup(Object? element) => _source.lookup(element);

  @override
  bool remove(Object? value) =>
      throw UnsupportedError('Cannot modify an immutable set.');

  @override
  Set<E> toSet() => Set<E>.of(_source);

  @override
  String toString() => '{<redacted>}';
}
