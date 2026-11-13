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
const String ownTalkFeaturePresets = 'appearance.presets';
const String ownTalkFeatureImage = 'appearance.image';

/// Upload limits when the server does not publish `limits`: the server's own
/// upper bound for the byte size and its default for the longest edge.
const int ownTalkDefaultMaxImageBytes = 10 * 1024 * 1024;
const int ownTalkDefaultMaxImageEdge = 2560;

const int _maximumEmojiBytes = 32;
final RegExp _colorPattern = RegExp(r'^#[0-9A-Fa-f]{6}$');
final RegExp _roomTypePattern = RegExp(r'^[a-z0-9]{1,32}$');
final RegExp _presetPattern = RegExp(r'^[a-z0-9]{1,32}$');
final RegExp _imageHashPattern = RegExp(r'^[0-9a-f]{64}$');

/// Whether [value] is the lower-case hex SHA-256 the server names an image by.
bool isOwnTalkImageHash(String value) => _imageHashPattern.hasMatch(value);

/// How the server decides who may edit group and public conversations.
enum OwnTalkAclMode { roles, membership }

/// Talk room types, as the wire integers the conversations API uses.
const int _talkTypeOneToOne = 1;
const int _talkTypeGroup = 2;
const int _talkTypePublic = 3;

/// What a setting value looks like on the wire.
enum OwnTalkSettingKind { color, emoji, preset, image }

/// One shared setting the server accepts, with the feature that gates it.
enum OwnTalkSettingField {
  chatBackgroundColor(
    'chat.backgroundColor',
    ownTalkFeatureColors,
    OwnTalkSettingKind.color,
  ),
  chatAccentColor(
    'chat.accentColor',
    ownTalkFeatureColors,
    OwnTalkSettingKind.color,
  ),
  bubbleOwnColor(
    'bubble.ownColor',
    ownTalkFeatureBubbles,
    OwnTalkSettingKind.color,
  ),
  bubbleOwnTextColor(
    'bubble.ownTextColor',
    ownTalkFeatureBubbles,
    OwnTalkSettingKind.color,
  ),
  bubbleOtherColor(
    'bubble.otherColor',
    ownTalkFeatureBubbles,
    OwnTalkSettingKind.color,
  ),
  bubbleOtherTextColor(
    'bubble.otherTextColor',
    ownTalkFeatureBubbles,
    OwnTalkSettingKind.color,
  ),
  chatBackgroundPreset(
    'chat.backgroundPreset',
    ownTalkFeaturePresets,
    OwnTalkSettingKind.preset,
  ),

  /// Set only by the upload endpoint; a merge patch can only clear it.
  chatBackgroundImage(
    'chat.backgroundImage',
    ownTalkFeatureImage,
    OwnTalkSettingKind.image,
  ),
  composerQuickEmoji(
    'composer.quickEmoji',
    ownTalkFeatureQuickEmoji,
    OwnTalkSettingKind.emoji,
  );

  const OwnTalkSettingField(this.wireKey, this.feature, this.kind);

  final String wireKey;
  final String feature;
  final OwnTalkSettingKind kind;

  bool get isEmoji => kind == OwnTalkSettingKind.emoji;

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
/// the server remains the authority on what counts as a single emoji. A preset
/// is a short lower-case ID (whether the server offers it is checked against
/// the capability) and an image is the 64 hex digits of its SHA-256.
String? normalizeOwnTalkSettingValue(OwnTalkSettingField field, String value) {
  switch (field.kind) {
    case OwnTalkSettingKind.emoji:
      if (value.isEmpty ||
          utf8.encode(value).length > _maximumEmojiBytes ||
          value.runes.any((rune) => rune < 0x20 || rune == 0x7f) ||
          value.runes.any(_isInvisibleOrDirectional) ||
          !value.runes.any((rune) => rune > 0x7f)) {
        return null;
      }
      return value;
    case OwnTalkSettingKind.color:
      return _colorPattern.hasMatch(value) ? value.toUpperCase() : null;
    case OwnTalkSettingKind.preset:
      return _presetPattern.hasMatch(value) ? value : null;
    case OwnTalkSettingKind.image:
      return _imageHashPattern.hasMatch(value) ? value : null;
  }
}

/// Bidi controls, zero-width characters and the BOM reorder or hide text;
/// ZWJ (U+200D) is not among them because emoji sequences need it.
bool _isInvisibleOrDirectional(int rune) =>
    (rune >= 0x200B && rune <= 0x200C) ||
    (rune >= 0x200E && rune <= 0x200F) ||
    (rune >= 0x202A && rune <= 0x202E) ||
    (rune >= 0x2060 && rune <= 0x2064) ||
    (rune >= 0x2066 && rune <= 0x2069) ||
    rune == 0xFEFF;

/// Optional `owntalk_extensions` capability. Anything unexpected, including an
/// unknown `api`, means "not available" rather than an error.
final class OwnTalkExtensionsCapability {
  OwnTalkExtensionsCapability._({
    required this.version,
    required this.acl,
    required Set<String> features,
    required Set<String> roomTypes,
    required List<String> presets,
    required this.imageLimits,
  }) : features = Set<String>.unmodifiable(features),
       roomTypes = Set<String>.unmodifiable(roomTypes),
       presets = List<String>.unmodifiable(presets);

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
        presets: _parsePresets(value['presets']),
        imageLimits: OwnTalkImageLimits._tryParse(value['limits']),
      );
    } on TalkProtocolException {
      return null;
    }
  }

  final String version;
  final OwnTalkAclMode acl;
  final Set<String> features;
  final Set<String> roomTypes;

  /// Background preset IDs the server accepts, in the order it listed them.
  /// Empty for a server older than 0.3.0.
  final List<String> presets;

  /// Upload limits, or `null` when the server did not publish them.
  final OwnTalkImageLimits? imageLimits;

  int get maxImageBytes =>
      imageLimits?.maxImageBytes ?? ownTalkDefaultMaxImageBytes;

  int get maxImageEdge =>
      imageLimits?.maxImageEdge ?? ownTalkDefaultMaxImageEdge;

  bool supportsFeature(String feature) => features.contains(feature);

  @override
  bool operator ==(Object other) =>
      other is OwnTalkExtensionsCapability &&
      other.version == version &&
      other.acl == acl &&
      other.features.length == features.length &&
      other.features.containsAll(features) &&
      other.roomTypes.length == roomTypes.length &&
      other.roomTypes.containsAll(roomTypes) &&
      _sameList(other.presets, presets) &&
      other.imageLimits == imageLimits;

  @override
  int get hashCode => Object.hash(
    version,
    acl,
    features.length,
    roomTypes.length,
    presets.length,
    imageLimits,
  );

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

/// A malformed `presets` member means "no presets", and an entry that is not a
/// plausible ID is skipped, so a newer server never switches the extension off.
List<String> _parsePresets(Object? raw) {
  if (raw is! List<Object?>) {
    return const [];
  }
  final result = <String>[];
  for (final entry in raw) {
    if (entry is String &&
        _presetPattern.hasMatch(entry) &&
        !result.contains(entry)) {
      result.add(entry);
    }
  }
  return result;
}

bool _sameList(List<String> first, List<String> second) {
  if (first.length != second.length) {
    return false;
  }
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) {
      return false;
    }
  }
  return true;
}

/// What the server accepts for a background image upload.
final class OwnTalkImageLimits {
  const OwnTalkImageLimits({
    required this.maxImageBytes,
    required this.maxImageEdge,
  });

  /// `null` unless both members are positive integers.
  static OwnTalkImageLimits? _tryParse(Object? raw) {
    if (raw is! Map<String, Object?>) {
      return null;
    }
    final bytes = raw['maxImageBytes'];
    final edge = raw['maxImageEdge'];
    if (bytes is! int || edge is! int || bytes < 1 || edge < 1) {
      return null;
    }
    return OwnTalkImageLimits(maxImageBytes: bytes, maxImageEdge: edge);
  }

  final int maxImageBytes;
  final int maxImageEdge;

  @override
  bool operator ==(Object other) =>
      other is OwnTalkImageLimits &&
      other.maxImageBytes == maxImageBytes &&
      other.maxImageEdge == maxImageEdge;

  @override
  int get hashCode => Object.hash(maxImageBytes, maxImageEdge);
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
