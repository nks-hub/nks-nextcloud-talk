import 'dart:collection';

import '../json_value.dart';
import '../protocol_exception.dart';

const TalkProtocolErrorCode _tagModelCode =
    TalkProtocolErrorCode.invalidRoomSettingsResponse;

enum ConversationTagType {
  custom('custom'),
  favorites('favorites'),
  other('other');

  const ConversationTagType(this.wireValue);

  final String wireValue;
}

/// One user-scoped conversation tag returned by Talk.
final class ConversationTagDefinition {
  ConversationTagDefinition._({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.collapsed,
    required this.type,
    required Map<String, Object?> wire,
  }) : wire = UnmodifiableMapView(wire);

  final String id;
  final String name;
  final int sortOrder;
  final bool collapsed;
  final ConversationTagType type;
  final Map<String, Object?> wire;
}

List<ConversationTagDefinition> parseConversationTagDefinitions(
  Object? value, {
  String path = r'$.ocs.data',
}) {
  final items = requireList(value, path: path, code: _tagModelCode);
  if (items.length > 102) {
    protocolFailure(_tagModelCode, path);
  }
  final ids = <String>{};
  final definitions = <ConversationTagDefinition>[];
  for (var index = 0; index < items.length; index++) {
    final itemPath = '$path[$index]';
    final item = requireObject(
      items[index],
      path: itemPath,
      code: _tagModelCode,
    );
    final id = requireString(
      item['id'],
      path: '$itemPath.id',
      code: _tagModelCode,
      minLength: 1,
      maxLength: 32,
    );
    if (!_numericId.hasMatch(id) || !ids.add(id)) {
      protocolFailure(_tagModelCode, '$itemPath.id');
    }
    final name = requireString(
      item['name'],
      path: '$itemPath.name',
      code: _tagModelCode,
      minLength: 1,
      maxLength: 250,
    );
    if (_hasControlCharacter(name)) {
      protocolFailure(_tagModelCode, '$itemPath.name');
    }
    final typeValue = requireString(
      item['type'],
      path: '$itemPath.type',
      code: _tagModelCode,
      minLength: 1,
      maxLength: 16,
    );
    final type = ConversationTagType.values
        .where((candidate) => candidate.wireValue == typeValue)
        .firstOrNull;
    if (type == null) {
      protocolFailure(_tagModelCode, '$itemPath.type');
    }
    definitions.add(
      ConversationTagDefinition._(
        id: id,
        name: name,
        sortOrder: requireInt(
          item['sortOrder'],
          path: '$itemPath.sortOrder',
          code: _tagModelCode,
          minimum: 0,
        ),
        collapsed: requireBool(
          item['collapsed'],
          path: '$itemPath.collapsed',
          code: _tagModelCode,
        ),
        type: type,
        wire: item,
      ),
    );
  }
  definitions.sort((left, right) {
    final byOrder = left.sortOrder.compareTo(right.sortOrder);
    return byOrder != 0 ? byOrder : left.id.compareTo(right.id);
  });
  return UnmodifiableListView(definitions);
}

final RegExp _numericId = RegExp(r'^\d+$');

bool _hasControlCharacter(String value) =>
    value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
