import '../bootstrap/capabilities.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';

const roomPresetsMaximumBytes = 256 * 1024;
const _code = TalkProtocolErrorCode.invalidRoomPresets;

/// Nine creation parameters supported by Spreed v24.0.4.
const roomPresetParameterMaximums = <String, int>{
  'roomType': 3,
  'readOnly': 1,
  'listable': 2,
  'messageExpiration': 9007199254740991,
  'lobbyState': 1,
  'sipEnabled': 2,
  'permissions': 511,
  'recordingConsent': 1,
  'mentionPermissions': 1,
};

Map<String, int> validateRoomPresetParameters(
  Object? value, {
  String path = r'$.parameters',
}) {
  // PHP serializes an empty associative array as [], including ForcedPreset.
  if (value is List && value.isEmpty) return const {};
  final object = requireObject(value, path: path, code: _code);
  final result = <String, int>{};
  for (final entry in object.entries) {
    final maximum = roomPresetParameterMaximums[entry.key];
    if (maximum == null) {
      protocolFailure(_code, path);
    }
    result[entry.key] = requireInt(
      entry.value,
      path: path,
      code: _code,
      minimum: entry.key == 'roomType' ? 2 : 0,
      maximum: maximum,
    );
  }
  return Map.unmodifiable(result);
}

final class RoomPreset {
  const RoomPreset._(
    this.identifier,
    this.name,
    this.description,
    this.parameters,
  );

  final String identifier;
  final String name;
  final String description;
  final Map<String, int> parameters;

  @override
  String toString() => 'RoomPreset()';
}

final class RoomPresetSelection {
  RoomPresetSelection._(
    this.presetIdentifier,
    Map<String, int> values,
    Set<String> forced,
  ) : parameters = Map.unmodifiable(values),
      forcedKeys = Set.unmodifiable(forced);

  final String presetIdentifier;
  final Map<String, int> parameters;
  final Set<String> forcedKeys;
}

/// Immutable server presets; unsupported policies are never partially applied.
final class RoomPresetCatalog {
  RoomPresetCatalog._(List<RoomPreset> values)
    : presets = List.unmodifiable(values);

  factory RoomPresetCatalog.fromJson(Object? value) {
    if (value is! List || value.isEmpty || value.length > 64) {
      protocolFailure(_code, r'$.ocs.data');
    }
    final ids = <String>{};
    final presets = <RoomPreset>[];
    for (final item in value) {
      final map = requireObject(item, path: r'$.ocs.data[]', code: _code);
      final id = _text(map['identifier'], 128, allowEmpty: false);
      if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id) || !ids.add(id)) {
        protocolFailure(_code, r'$.ocs.data[].identifier');
      }
      presets.add(
        RoomPreset._(
          id,
          _text(map['name'], 512),
          _text(map['description'], 4096),
          validateRoomPresetParameters(map['parameters']),
        ),
      );
    }
    if (!ids.contains('default') || !ids.contains('forced')) {
      protocolFailure(_code, r'$.ocs.data');
    }
    return RoomPresetCatalog._(presets);
  }

  final List<RoomPreset> presets;
  RoomPreset get defaultPreset =>
      presets.firstWhere((p) => p.identifier == 'default');
  RoomPreset get forcedPreset =>
      presets.firstWhere((p) => p.identifier == 'forced');
  List<RoomPreset> get selectablePresets =>
      List.unmodifiable(presets.where((p) => p.identifier != 'forced'));

  RoomPresetSelection resolve({
    required String presetIdentifier,
    Map<String, int> userChoices = const {},
  }) {
    final selected = selectablePresets.where(
      (p) => p.identifier == presetIdentifier,
    );
    if (selected.isEmpty) protocolFailure(_code, r'$.preset');
    return RoomPresetSelection._(presetIdentifier, {
      ...defaultPreset.parameters,
      ...selected.single.parameters,
      ...validateRoomPresetParameters(userChoices),
      ...forcedPreset.parameters,
    }, forcedPreset.parameters.keys.toSet());
  }

  @override
  String toString() => 'RoomPresetCatalog(count: ${presets.length})';
}

final class RoomPresetsRequest {
  RoomPresetsRequest({
    required this.accountId,
    required this.server,
    required CapabilitySnapshot capabilities,
  }) {
    if (capabilities.context != CapabilityContext.authenticated ||
        !capabilities.supportsTalk('conversation-presets')) {
      protocolFailure(_code, r'$.capabilities');
    }
  }

  final AccountId accountId;
  final ServerBase server;
  Uri get uri => server.uri.replace(
    path: '${server.basePath}/ocs/v2.php/apps/spreed/api/v1/presets/room',
    queryParameters: const {'format': 'json'},
  );

  @override
  String toString() => 'RoomPresetsRequest()';
}

RoomPresetCatalog decodeRoomPresetsResponse({
  required int statusCode,
  required Object? json,
}) {
  final root = requireObject(json, path: r'$', code: _code);
  final ocs = requireObject(root['ocs'], path: r'$.ocs', code: _code);
  final meta = requireObject(ocs['meta'], path: r'$.ocs.meta', code: _code);
  if (statusCode != 200 ||
      meta['status'] != 'ok' ||
      meta['statuscode'] != 200) {
    protocolFailure(_code, r'$.ocs.meta');
  }
  return RoomPresetCatalog.fromJson(ocs['data']);
}

String _text(Object? value, int maximum, {bool allowEmpty = true}) {
  final text = requireString(value, path: r'$.ocs.data[]', code: _code);
  if ((!allowEmpty && text.isEmpty) ||
      text.length > maximum ||
      text.codeUnits.any(
        (c) => (c < 0x20 && c != 10 && c != 13) || c == 0x7f,
      )) {
    protocolFailure(_code, r'$.ocs.data[]');
  }
  return text;
}
