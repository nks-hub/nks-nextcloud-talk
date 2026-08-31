import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';
import 'package:nextcloudtalk/features/chat/chat_background_store.dart';
import 'package:nextcloudtalk/features/chat/chat_background_surface.dart';
import 'package:nextcloudtalk/features/rooms/guest_link_sharer.dart';
import 'package:nextcloudtalk/features/rooms/room_details_screen.dart';
import 'package:nextcloudtalk/features/shareditems/shared_items_screen.dart';
import 'package:nextcloudtalk/features/shareditems/shared_items_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:nextcloudtalk/platform/media/image_attachment_picker.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

part 'room_details_administration_test.part.dart';
part 'room_details_avatar_bans_test.part.dart';
part 'room_details_background_test.part.dart';
part 'room_details_call_notifications_test.part.dart';
part 'room_details_clear_history_test.part.dart';
part 'room_details_conversation_tags_test.part.dart';
part 'room_details_importance_sensitivity_test.part.dart';
part 'room_details_message_expiration_test.part.dart';
part 'room_details_overview_moderation_test.part.dart';
part 'room_details_sip_info_test.part.dart';
part 'room_details_shared_items_test.part.dart';
part 'room_details_test_support.part.dart';

late AppDatabase database;
late AccountRepository accounts;
late MemoryCredentialVault vault;
late StoredAccount account;
late CachedConversation conversation;

void main() {
  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault()..values['account-a'] = 'fixture-password';
    account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final roomJson = _conversationRoomJson();
    final room = ConversationRoom.fromJson(roomJson);
    await database
        .into(database.cachedConversations)
        .insert(
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
    conversation = await database
        .select(database.cachedConversations)
        .getSingle();
  });

  tearDown(() => database.close());

  _registerOverviewAndModerationTests();
  _registerAdministrationTests();
  _registerAvatarAndBanTests();
  _registerBackgroundTests();
  _registerCallNotificationTests();
  _registerClearHistoryTests();
  _registerConversationTagsTests();
  _registerImportanceSensitivityTests();
  _registerMessageExpirationTests();
  _registerSipInfoTests();
  _registerSharedItemsTests();
}

Widget app({
  required Widget home,
  required http.Client client,
  List<Override> overrides = const [],
}) {
  final api = HttpNextcloudApi(client: client);
  return ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      credentialVaultProvider.overrideWithValue(vault),
      nextcloudApiProvider.overrideWithValue(api),
      chatBackgroundProvider.overrideWith(
        (ref, key) => Stream<String?>.value(null),
      ),
      chatAttachmentDependenciesProvider.overrideWith(
        (ref, key) => Future<ChatAttachmentDependencies>.error(
          StateError('attachment dependencies are not wired in this suite'),
          StackTrace.empty,
        ),
      ),
      ...overrides,
    ],
    child: localizedTestApp(home: home),
  );
}

http.Client participantsClient(Object? participantsJson) {
  return MockClient((request) async {
    if (request.url.path.endsWith('/participants')) {
      return http.Response(
        jsonEncode({
          'ocs': {
            'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
            'data': participantsJson,
          },
        }),
        200,
      );
    }
    return http.Response('', 404);
  });
}

/// Re-reads the account row after its cached Talk capabilities changed, so
/// the screen sees the same features a real sync would have written.
Future<StoredAccount> withCapabilities(Set<String> features) async {
  await accounts.updateTalkFeatures(account.id, features);
  return (await accounts.getAccount(account.id))!;
}

Future<void> openDetails(
  WidgetTester tester, {
  required StoredAccount forAccount,
  required CachedConversation forConversation,
  required http.Client client,
  GuestLinkSharer? sharer,
  List<Override> overrides = const [],
  double height = 2600,
}) async {
  _growViewport(tester, height: height);
  await tester.pumpWidget(
    app(
      home: RoomDetailsScreen(
        key: ValueKey((
          forAccount.id,
          forConversation.token,
          forAccount.talkFeaturesJson,
        )),
        account: forAccount,
        conversation: forConversation,
        linkSharer: sharer ?? _RecordingLinkSharer(),
      ),
      client: client,
      overrides: overrides,
    ),
  );
  await _pumpUntil(
    tester,
    () => find
        .byKey(const Key('room-details-notification-picker'))
        .evaluate()
        .isNotEmpty,
  );
}
