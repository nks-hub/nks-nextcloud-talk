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
  return UnmodifiableMapView(result);
}

List<Object?> requireList(
  Object? value, {
  required String path,
  required TalkProtocolErrorCode code,
}) {
  if (value is! List<Object?>) {
    protocolFailure(code, path);
  }
  return List<Object?>.unmodifiable(value);
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
  return Set<String>.unmodifiable(result);
}

Object? freezeJson(Object? value) {
  return _freezeJson(value, depth: 0, budget: _JsonBudget());
}

Object? _freezeJson(
  Object? value, {
  required int depth,
  required _JsonBudget budget,
}) {
  if (depth > _maximumJsonDepth) {
    protocolFailure(
      TalkProtocolErrorCode.invalidCapabilities,
      r'$.ocs.data.capabilities',
    );
  }
  budget.consume();

  if (value is Map<Object?, Object?>) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        protocolFailure(
          TalkProtocolErrorCode.invalidCapabilities,
          r'$.ocs.data.capabilities',
        );
      }
      result[key] = _freezeJson(entry.value, depth: depth + 1, budget: budget);
    }
    return UnmodifiableMapView(result);
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(
      value.map((item) => _freezeJson(item, depth: depth + 1, budget: budget)),
    );
  }
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  protocolFailure(
    TalkProtocolErrorCode.invalidCapabilities,
    r'$.ocs.data.capabilities',
  );
}

final class _JsonBudget {
  int remaining = _maximumJsonNodes;

  void consume() {
    remaining--;
    if (remaining < 0) {
      protocolFailure(
        TalkProtocolErrorCode.invalidCapabilities,
        r'$.ocs.data.capabilities',
      );
    }
  }
}
