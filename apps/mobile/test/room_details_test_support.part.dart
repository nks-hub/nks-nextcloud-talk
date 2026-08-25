part of 'room_details_screen_test.dart';

/// A one-pixel PNG header: enough for the magic-number sniff the upload does.
final Uint8List _onePixelPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
]);

/// Stands in for the gallery, which is a platform channel.
final class _StubImagePicker implements ImageSelectionBackend {
  _StubImagePicker(this.bytes, this.displayName);

  final Uint8List bytes;
  final String displayName;

  @override
  Future<ImageSelection?> selectImage(AttachmentPickerSource source) async {
    return ImageSelection(
      displayName: displayName,
      declaredMimeType: null,
      byteLength: bytes.length,
      openRead: ({int? start, int? end}) =>
          Stream<List<int>>.value(bytes.sublist(start ?? 0, end)),
    );
  }
}

/// Stands in for the system share sheet, which no widget test can reach.
final class _RecordingLinkSharer implements GuestLinkSharer {
  final List<Uri> shared = <Uri>[];

  @override
  Future<bool> share({required Uri uri, required String subject}) async {
    shared.add(uri);
    return true;
  }
}

/// Reads a keyed [Text] widget's content, so an assertion cannot be satisfied
/// by the same string inside a dialog that is still playing its dismissal.
String? _textByKey(WidgetTester tester, String key) {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) {
    return null;
  }
  return tester.widget<Text>(finder).data;
}

http.Response _ocsSuccess([Object? data = const <Object?>[]]) {
  return http.Response(
    jsonEncode({
      'ocs': {
        'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
        'data': data,
      },
    }),
    200,
  );
}

http.Response _ocsFailure(int statusCode) {
  return http.Response(
    jsonEncode({
      'ocs': {
        'meta': {'status': 'failure', 'statuscode': statusCode},
        'data': <Object?>[],
      },
    }),
    statusCode,
  );
}

Future<CachedConversation> _insertConversation(
  AppDatabase database,
  StoredAccount account, {
  required Map<String, Object?> overrides,
}) async {
  final roomJson = Map<String, Object?>.from(_conversationRoomJson())
    ..addAll(overrides);
  final room = ConversationRoom.fromJson(roomJson);
  await database
      .into(database.cachedConversations)
      .insertOnConflictUpdate(
        CachedConversationsCompanion.insert(
          accountId: account.id,
          token: room.token.value,
          displayName: room.displayName,
          description: room.description,
          lastActivity: room.lastActivity,
          unreadMessages: room.unreadMessages,
          favorite: room.isFavorite,
          readOnly: Value(room.readOnly),
          roomType: Value(room.type),
          roomName: Value(room.name),
          objectType: Value(room.objectType),
          avatarVersion: Value(room.avatarVersion),
          isCustomAvatar: Value(room.isCustomAvatar),
          rawJson: jsonEncode(roomJson),
        ),
      );
  return database.select(database.cachedConversations).getSingle();
}

/// One attendee of each role the moderation menu has to distinguish: an
/// owner (untouchable), a moderator (demote only), a plain user (promote or
/// remove) and the signed-in account itself.
List<Map<String, Object?>> _moderationParticipants({
  int promotedAttendeeType = 3,
}) {
  return [
    _participantJson(
      attendeeId: 1,
      actorId: 'synthetic-owner',
      participantType: 1,
      displayName: 'Synthetic Owner',
    ),
    _participantJson(
      attendeeId: 2,
      actorId: 'synthetic-moderator',
      participantType: 2,
      displayName: 'Synthetic Moderator',
    ),
    _participantJson(
      attendeeId: 3,
      actorId: 'synthetic-member',
      participantType: promotedAttendeeType,
      displayName: 'Synthetic Member',
    ),
    _participantJson(
      attendeeId: 4,
      actorId: 'fixture-user',
      participantType: 2,
      displayName: 'Signed-in Moderator',
    ),
  ];
}

Map<String, Object?> _participantJson({
  required int attendeeId,
  String actorType = 'users',
  String actorId = 'synthetic-user',
  required String displayName,
  required int participantType,
  List<String> sessionIds = const <String>[],
  String? status,
}) {
  return {
    'attendeeId': attendeeId,
    'actorType': actorType,
    'actorId': actorId,
    'displayName': displayName,
    'participantType': participantType,
    'lastPing': 1724300000,
    'sessionIds': sessionIds,
    'permissions': 254,
    'attendeePermissions': 0,
    'inCall': 0,
    'status': ?status,
  };
}

Map<String, Object?> _conversationRoomJson() {
  final root =
      _readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  return Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
}

Object? _readFixtureJson(String relativePath) {
  return jsonDecode(File('../../contracts/$relativePath').readAsStringSync());
}

/// Reads the live room title text by key rather than by string content, so
/// a still-closing rename dialog's own text field (which briefly carries the
/// same string while its dismiss transition plays) cannot be mistaken for
/// the summary having refreshed.
String? _roomTitleText(WidgetTester tester) {
  final finder = find.byKey(const Key('room-details-name'));
  if (finder.evaluate().isEmpty) {
    return null;
  }
  return tester.widget<Text>(finder).data;
}

/// Reads the notification picker's subtitle by key for the same reason as
/// [_roomTitleText]: the picker dialog's own option labels repeat these
/// strings and can still be mounted mid dismiss-transition.
String? _notificationSubtitleText(WidgetTester tester) {
  final finder = find.byKey(const Key('room-details-notification-subtitle'));
  if (finder.evaluate().isEmpty) {
    return null;
  }
  return tester.widget<Text>(finder).data;
}

/// The settings actions row pushes the participant list further down than
/// the default test surface; grow it so the whole screen builds without
/// needing to scroll to reach the participant tiles. A conversation whose
/// server supports every administration capability adds nine more rows, which
/// is what [height] is for.
void _growViewport(WidgetTester tester, {double height = 1600}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(400, height);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxAttempts = 100,
}) async {
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    if (condition()) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  fail('Condition was not reached');
}
