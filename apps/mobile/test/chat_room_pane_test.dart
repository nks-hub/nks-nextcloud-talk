import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_message_content.dart';
import 'package:nextcloudtalk/features/chat/media/chat_attachment_opener.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/features/chat/message_translation_service.dart';
import 'package:nextcloudtalk/features/chat/outgoing_message_status.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

part 'chat_room_pane_interactions.part.dart';
part 'chat_room_pane_rendering.part.dart';
part 'chat_room_pane_thread_context.part.dart';

late AppDatabase database;
late AccountRepository accounts;
late MemoryCredentialVault vault;
late StoredAccount account;
late CachedConversation conversation;

void main() {
  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault();
    account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await database
        .into(database.cachedConversations)
        .insert(
          CachedConversationsCompanion.insert(
            accountId: account.id,
            token: 'rooma123',
            displayName: 'Synthetic room A',
            description: '',
            lastActivity: 1724300000,
            unreadMessages: 0,
            favorite: false,
            readOnly: const Value(0),
            roomType: const Value(2),
            roomName: const Value('synthetic-room-a'),
            objectType: const Value(''),
            avatarVersion: const Value(''),
            isCustomAvatar: const Value(false),
            rawJson: '{}',
          ),
        );
    conversation = await database
        .select(database.cachedConversations)
        .getSingle();
    await database
        .into(database.cachedChatMessages)
        .insert(
          CachedChatMessagesCompanion.insert(
            accountId: account.id,
            roomToken: conversation.token,
            messageId: 10,
            actorType: 'users',
            actorId: 'someone-else',
            actorDisplayName: 'Other person',
            timestamp: 1724300000,
            systemMessage: '',
            messageType: 'comment',
            referenceId: 'fixture-reference',
            displayText: 'Cached hello',
            deleted: false,
            rawJson: '{}',
          ),
        );
  });

  tearDown(() => database.close());

  _registerChatRoomPaneRenderingTests();
  _registerChatRoomPaneInteractionTests();
  _registerChatRoomPaneThreadContextTests();
}

Widget app({
  required Widget home,
  List<Override> overrides = const [],
  Locale locale = const Locale('en'),
}) {
  return ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      credentialVaultProvider.overrideWithValue(vault),
      connectivityWakeEventsProvider.overrideWithValue(
        const Stream<void>.empty(),
      ),
      // This suite covers cached rendering, threads and outbox state, not
      // attachment transport. Resolving the dependency as unavailable keeps
      // the media buttons in a settled state instead of an endless spinner.
      chatAttachmentDependenciesProvider.overrideWith(
        (ref, key) => Future<ChatAttachmentDependencies>.error(
          StateError('attachment dependencies are not wired in this suite'),
          StackTrace.empty,
        ),
      ),
      ...overrides,
    ],
    child: localizedTestApp(
      home: Builder(
        builder: (context) => Localizations.override(
          context: context,
          locale: locale,
          child: home,
        ),
      ),
    ),
  );
}

PresenceChatRoomScreen roomScreen() =>
    PresenceChatRoomScreen(account: account, conversation: conversation);

const _giphyResourceUrl = 'https://giphy.com/gifs/waving-cat-fixture123';
const _onePixelGif = 'R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==';

ChatMessage _attachmentMessage({
  required int id,
  required int fileId,
  required String name,
  required String mimeType,
  required Object previewAvailable,
  required String link,
  String? path,
}) {
  return ChatMessage.fromJson(
    _messageJson(
      id: id,
      actorId: 'attachment-author',
      actorDisplayName: 'Attachment author',
      timestamp: 1767225600 + id,
      message: '{file}',
      markdown: true,
      messageParameters: <String, Object?>{
        'file': <String, Object?>{
          'type': 'file',
          'id': '$fileId',
          'name': name,
          'link': link,
          'path': path ?? 'Talk/$name',
          'mimetype': mimeType,
          'preview-available': previewAvailable,
        },
      },
    ),
  );
}

Map<String, Object?> _messageJson({
  required int id,
  required String actorId,
  required String actorDisplayName,
  required int timestamp,
  required String message,
  bool markdown = false,
  int? threadId,
  bool isThread = false,
  int threadReplies = 0,
  Map<String, Object?> messageParameters = const {},
  Map<String, Object?> reactions = const {},
  List<Object?> reactionsSelf = const [],
  Map<String, Object?>? parent,
}) {
  return <String, Object?>{
    'id': id,
    'token': 'rooma123',
    'actorType': 'users',
    'actorId': actorId,
    'actorDisplayName': actorDisplayName,
    'timestamp': timestamp,
    'systemMessage': '',
    'messageType': 'comment',
    'isReplyable': true,
    'referenceId': 'reference-$id',
    'message': message,
    'messageParameters': messageParameters,
    'markdown': markdown,
    'reactions': reactions,
    'reactionsSelf': reactionsSelf,
    'deleted': null,
    'threadId': threadId,
    'isThread': isThread,
    'threadTitle': isThread ? 'Fixture thread' : null,
    'threadReplies': threadReplies,
    'parent': ?parent,
  };
}

Future<void> _insertCachedMessage(
  AppDatabase database,
  Map<String, Object?> wire, {
  required String displayText,
}) {
  return database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: 'account-a',
          roomToken: wire['token']! as String,
          messageId: wire['id']! as int,
          actorType: wire['actorType']! as String,
          actorId: wire['actorId']! as String,
          actorDisplayName: wire['actorDisplayName']! as String,
          timestamp: wire['timestamp']! as int,
          systemMessage: wire['systemMessage']! as String,
          messageType: wire['messageType']! as String,
          referenceId: wire['referenceId']! as String,
          displayText: displayText,
          deleted: wire['deleted'] == true,
          threadId: Value(wire['threadId'] as int?),
          rawJson: jsonEncode(wire),
        ),
      );
}

Future<void> _insertPendingOperation(
  AppDatabase database,
  StoredAccount account,
  CachedConversation conversation, {
  required String operationId,
  required String outboxState,
  required String message,
  int attemptCount = 0,
}) {
  return database
      .into(database.textSendOperations)
      .insert(
        TextSendOperationsCompanion.insert(
          accountId: account.id,
          operationId: operationId,
          roomToken: conversation.token,
          referenceId: 'reference-$operationId',
          message: message,
          replayContractRevision: 'fixture-revision',
          enqueueSequence: 1,
          outboxState: outboxState,
          attemptCount: attemptCount,
          messageIdsJson: '[]',
          duplicateRiskAcknowledged: false,
          createdAtMillis: 1,
          updatedAtMillis: 1,
        ),
      );
}

/// Pumps until [condition] holds, letting the real database work in between
/// run through [WidgetTester.runAsync]; the fake clock alone never drives it.
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

Key _dayKey(int timestamp) {
  final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000).toLocal();
  return Key('chat-day-${date.year}-${date.month}-${date.day}');
}

int _unixSeconds(DateTime value) =>
    value.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;

RichChatCapabilityProfile _capabilityProfile({
  bool reply = false,
  bool edit = false,
  bool delete = false,
  bool react = false,
  bool privateReply = false,
  bool translation = false,
}) {
  return RichChatCapabilityProfile.fromTalkFeatures(
    talkFeatures: <String>[
      'chat-v2',
      if (reply || privateReply) ...['chat-reference-id', 'chat-replies'],
      if (edit) 'edit-messages',
      if (delete) 'delete-messages',
      if (react) 'reactions',
      if (privateReply) 'private-reply',
    ],
    talkLocalFeatures: const <String>[],
    federated: false,
    moderator: false,
    participantPermissions: 0,
    translationAvailable: translation,
  );
}
