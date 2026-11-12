import 'dart:collection';
import 'dart:convert';

import '../json_value.dart';
import '../protocol_exception.dart';

const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidOwnTalkExtensionsResponse;

/// Capability key the OwnTalk Extensions server app publishes.
const String ownTalkExtensionsCapabilityKey = 'owntalk_extensions';

/// The only `api` value this client understands.
const int ownTalkExtensionsSupportedApi = 1;

const String ownTalkFeatureColors = 'appearance.colors';
const String ownTalkFeatureBubbles = 'appearance.bubbles';
const String ownTalkFeatureQuickEmoji = 'composer.quickEmoji';

const int _maximumEmojiBytes = 32;
final RegExp _colorPattern = RegExp(r'^#[0-9A-Fa-f]{6}$');
final RegExp _roomTypePattern = RegExp(r'^[a-z0-9]{1,32}$');

/// How the server decides who may edit group and public conversations.
enum OwnTalkAclMode { roles, membership }

/// Talk room types, as the wire integers the conversations API uses.
const int _talkTypeOneToOne = 1;
const int _talkTypeGroup = 2;
const int _talkTypePublic = 3;

/// One shared setting the server accepts, with the feature that gates it.
enum OwnTalkSettingField {
  chatBackgroundColor('chat.backgroundColor', ownTalkFeatureColors, false),
  chatAccentColor('chat.accentColor', ownTalkFeatureColors, false),
  bubbleOwnColor('bubble.ownColor', ownTalkFeatureBubbles, false),
  bubbleOwnTextColor('bubble.ownTextColor', ownTalkFeatureBubbles, false),
  bubbleOtherColor('bubble.otherColor', ownTalkFeatureBubbles, false),
  bubbleOtherTextColor('bubble.otherTextColor', ownTalkFeatureBubbles, false),
  composerQuickEmoji('composer.quickEmoji', ownTalkFeatureQuickEmoji, true);

  const OwnTalkSettingField(this.wireKey, this.feature, this.isEmoji);

  final String wireKey;
  final String feature;
  final bool isEmoji;

  static OwnTalkSettingField? fromWireKey(String key) {
    for (final field in values) {
      if (field.wireKey == key) {
        return field;
      }
    }
    return null;
  }
}

/// Normalizes a value for [field] or returns `null` when it is not acceptable.
///
/// Colours become upper-case `#RRGGBB`. An emoji must be non-empty, at most 32
/// UTF-8 bytes, free of control characters and contain a non-ASCII code point;
/// the server remains the authority on what counts as a single emoji.
String? normalizeOwnTalkSettingValue(OwnTalkSettingField field, String value) {
  if (field.isEmoji) {
    if (value.isEmpty ||
        utf8.encode(value).length > _maximumEmojiBytes ||
        value.runes.any((rune) => rune < 0x20 || rune == 0x7f) ||
        !value.runes.any((rune) => rune > 0x7f)) {
      return null;
    }
    return value;
  }
  return _colorPattern.hasMatch(value) ? value.toUpperCase() : null;
}

/// Optional `owntalk_extensions` capability. Anything unexpected, including an
/// unknown `api`, means "not available" rather than an error.
final class OwnTalkExtensionsCapability {
  OwnTalkExtensionsCapability._({
    required this.version,
    required this.acl,
    required Set<String> features,
    required Set<String> roomTypes,
  }) : features = Set<String>.unmodifiable(features),
       roomTypes = Set<String>.unmodifiable(roomTypes);

  /// Returns `null` for a missing, malformed or unsupported capability.
  static OwnTalkExtensionsCapability? tryParse(Object? raw) {
    const code = TalkProtocolErrorCode.invalidCapabilities;
    const path = r'$.ocs.data.capabilities.owntalk_extensions';
    if (raw == null) {
      return null;
    }
    try {
      final value = requireObject(raw, path: path, code: code);
      if (value['api'] != ownTalkExtensionsSupportedApi) {
        return null;
      }
      final acl = switch (value['acl']) {
        'roles' => OwnTalkAclMode.roles,
        'membership' => OwnTalkAclMode.membership,
        _ => null,
      };
      if (acl == null) {
        return null;
      }
      final roomTypes = requireUniqueStringSet(
        value['roomTypes'],
        path: '$path.roomTypes',
        code: code,
      );
      if (roomTypes.any((type) => !_roomTypePattern.hasMatch(type))) {
        return null;
      }
      return OwnTalkExtensionsCapability._(
        version: requireString(
          value['version'],
          path: '$path.version',
          code: code,
          minLength: 1,
          maxLength: 64,
        ),
        acl: acl,
        features: requireUniqueStringSet(
          value['features'],
          path: '$path.features',
          code: code,
        ),
        roomTypes: roomTypes,
      );
    } on TalkProtocolException {
      return null;
    }
  }

  final String version;
  final OwnTalkAclMode acl;
  final Set<String> features;
  final Set<String> roomTypes;

  bool supportsFeature(String feature) => features.contains(feature);

  @override
  bool operator ==(Object other) =>
      other is OwnTalkExtensionsCapability &&
      other.version == version &&
      other.acl == acl &&
      other.features.length == features.length &&
      other.features.containsAll(features) &&
      other.roomTypes.length == roomTypes.length &&
      other.roomTypes.containsAll(roomTypes);

  @override
  int get hashCode =>
      Object.hash(version, acl, features.length, roomTypes.length);

  bool supportsField(OwnTalkSettingField field) =>
      supportsFeature(field.feature);

  /// Whether shared settings exist for a Talk room type (wire integer).
  bool supportsRoomType(int talkRoomType) => switch (talkRoomType) {
    _talkTypeOneToOne => roomTypes.contains('one2one'),
    _talkTypeGroup => roomTypes.contains('group'),
    _talkTypePublic => roomTypes.contains('public'),
    _ => false,
  };
}

/// The shared settings document of one conversation.
final class OwnTalkRoomSettings {
  OwnTalkRoomSettings._({
    required this.roomToken,
    required this.revision,
    required Map<OwnTalkSettingField, String?> values,
    required Map<OwnTalkSettingField, int> fieldRevisions,
    required this.canEdit,
    required this.aclSource,
    required this.updatedBy,
    required this.updatedAt,
  }) : values = UnmodifiableMapView(values),
       fieldRevisions = UnmodifiableMapView(fieldRevisions);

  /// A conversation without stored settings, as the server reports it.
  factory OwnTalkRoomSettings.empty(String roomToken) => OwnTalkRoomSettings._(
    roomToken: roomToken,
    revision: 0,
    values: {for (final field in OwnTalkSettingField.values) field: null},
    fieldRevisions: const {},
    canEdit: false,
    aclSource: null,
    updatedBy: null,
    updatedAt: null,
  );

  /// Parses the `ocs.data` object of a GET/PATCH answer. Unknown settings and
  /// unknown top-level members are ignored.
  factory OwnTalkRoomSettings.fromJson(
    Object? json, {
    String path = r'$.ocs.data',
  }) {
    final data = requireObject(json, path: path, code: _responseCode);
    requireInt(
      data['schemaVersion'],
      path: '$path.schemaVersion',
      code: _responseCode,
      minimum: 1,
      maximum: 1,
    );
    final rawSettings = requireObject(
      data['settings'],
      path: '$path.settings',
      code: _responseCode,
    );
    final values = <OwnTalkSettingField, String?>{};
    for (final field in OwnTalkSettingField.values) {
      final raw = rawSettings[field.wireKey];
      final fieldPath = '$path.settings.${field.wireKey}';
      if (raw == null) {
        values[field] = null;
        continue;
      }
      final text = requireString(
        raw,
        path: fieldPath,
        code: _responseCode,
        minLength: 1,
        maxLength: 64,
      );
      values[field] =
          normalizeOwnTalkSettingValue(field, text) ??
          protocolFailure(_responseCode, fieldPath);
    }
    final rawRevisions = requireObject(
      data['fieldRevisions'],
      path: '$path.fieldRevisions',
      code: _responseCode,
    );
    final fieldRevisions = <OwnTalkSettingField, int>{};
    for (final entry in rawRevisions.entries) {
      final field = OwnTalkSettingField.fromWireKey(entry.key);
      if (field != null) {
        fieldRevisions[field] = requireInt(
          entry.value,
          path: '$path.fieldRevisions.${entry.key}',
          code: _responseCode,
          minimum: 0,
        );
      }
    }
    final permissions = requireObject(
      data['permissions'],
      path: '$path.permissions',
      code: _responseCode,
    );
    final rawUpdatedAt = data['updatedAt'];
    return OwnTalkRoomSettings._(
      roomToken: requireString(
        data['roomToken'],
        path: '$path.roomToken',
        code: _responseCode,
        minLength: 4,
        maxLength: 64,
      ),
      revision: requireInt(
        data['revision'],
        path: '$path.revision',
        code: _responseCode,
        minimum: 0,
      ),
      values: values,
      fieldRevisions: fieldRevisions,
      canEdit: requireBool(
        permissions['canEdit'],
        path: '$path.permissions.canEdit',
        code: _responseCode,
      ),
      aclSource: _optionalString(permissions['aclSource'], '$path.permissions'),
      updatedBy: _optionalString(data['updatedBy'], '$path.updatedBy'),
      updatedAt: rawUpdatedAt == null
          ? null
          : requireInt(
              rawUpdatedAt,
              path: '$path.updatedAt',
              code: _responseCode,
              minimum: 0,
            ),
    );
  }

  final String roomToken;
  final int revision;

  /// Every known field, `null` where the conversation uses the client theme.
  final Map<OwnTalkSettingField, String?> values;
  final Map<OwnTalkSettingField, int> fieldRevisions;
  final bool canEdit;
  final String? aclSource;
  final String? updatedBy;
  final int? updatedAt;

  String? operator [](OwnTalkSettingField field) => values[field];

  bool get isEmpty => values.values.every((value) => value == null);

  /// Same shape the server sends, so a cached copy goes through [fromJson].
  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'roomToken': roomToken,
    'revision': revision,
    'settings': {
      for (final entry in values.entries) entry.key.wireKey: entry.value,
    },
    'fieldRevisions': {
      for (final entry in fieldRevisions.entries)
        entry.key.wireKey: entry.value,
    },
    'permissions': {'canEdit': canEdit, 'aclSource': aclSource},
    'updatedBy': updatedBy,
    'updatedAt': updatedAt,
  };

  @override
  bool operator ==(Object other) =>
      other is OwnTalkRoomSettings &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => Object.hash(roomToken, revision);

  @override
  String toString() => 'OwnTalkRoomSettings(revision: $revision)';
}

String? _optionalString(Object? value, String path) => value == null
    ? null
    : requireString(value, path: path, code: _responseCode, maxLength: 256);
