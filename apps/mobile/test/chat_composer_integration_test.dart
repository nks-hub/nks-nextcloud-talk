import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/features/chat/composer/giphy.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  testWidgets('emoji and account Giphy selection use the real text send flow', (
    tester,
  ) async {
    final harness = await _ComposerHarness.create();
    addTearDown(harness.close);
    final giphy = _giphyRepository();
    addTearDown(giphy.close);

    await tester.pumpWidget(
      harness.app(
        overrides: <Override>[
          giphyRepositoryProvider.overrideWith((ref, accountId) async {
            expect(accountId, harness.account.id);
            return giphy;
          }),
        ],
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('open-emoji-picker')));
    await _pumpTransition(tester);
    await tester.tap(find.byKey(const Key('emoji-category-people')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('emoji-choice-waving-hand')));
    await _pumpTransition(tester);
    expect(_composer(tester).text, '👋');

    await tester.tap(find.byKey(const Key('open-giphy-picker')));
    final gif = find.byKey(
      const ValueKey<String>('giphy-thumbnail-https://giphy.com/gifs/wave'),
    );
    await _pumpUntil(tester, () => gif.evaluate().isNotEmpty);
    await _pumpTransition(tester);
    final pickerRect = tester.getRect(find.byType(GiphyPicker));
    final viewportHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(pickerRect.top, greaterThanOrEqualTo(0));
    expect(pickerRect.bottom, lessThanOrEqualTo(viewportHeight));
    await tester.ensureVisible(gif);
    await tester.pump();
    await tester.tap(gif);
    await _pumpTransition(tester);

    expect(_composer(tester).text, '👋 https://giphy.com/gifs/wave ');
    await tester.tap(find.byKey(const Key('send-message')));
    await _pumpUntil(
      tester,
      () => harness.sentMessages.isNotEmpty && _composer(tester).text.isEmpty,
    );

    expect(harness.sentMessages, <String>['👋 https://giphy.com/gifs/wave']);
    expect(_composer(tester).text, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'unavailable Giphy integration becomes an honest disabled state',
    (tester) async {
      final harness = await _ComposerHarness.create();
      addTearDown(harness.close);

      await tester.pumpWidget(
        harness.app(
          overrides: <Override>[
            giphyRepositoryProvider.overrideWith(
              (ref, accountId) async => null,
            ),
          ],
        ),
      );
      await _pumpUntil(
        tester,
        () => find
            .byIcon(Icons.chat_bubble_outline_rounded)
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.byKey(const Key('open-giphy-picker')));
      await _pumpUntil(tester, () {
        final button = tester.widget<IconButton>(
          find.byKey(const Key('open-giphy-picker')),
        );
        return button.onPressed == null &&
            button.tooltip == 'GIFs are not available on this server.';
      });

      final button = tester.widget<IconButton>(
        find.byKey(const Key('open-giphy-picker')),
      );
      expect(button.onPressed, isNull);
      expect(button.tooltip, 'GIFs are not available on this server.');
      expect(find.byType(GiphyPicker), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}

TextEditingController _composer(WidgetTester tester) {
  return tester
      .widget<TextField>(find.byKey(const Key('chat-composer')))
      .controller!;
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    if (condition()) {
      return;
    }
  }
  fail('Condition was not reached');
}

Future<void> _pumpTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

final class _ComposerHarness {
  _ComposerHarness({
    required this.database,
    required this.account,
    required this.conversation,
    required this.vault,
    required this.api,
    required this.sentMessages,
  });

  final AppDatabase database;
  final StoredAccount account;
  final CachedConversation conversation;
  final MemoryCredentialVault vault;
  final HttpNextcloudApi api;
  final List<String> sentMessages;

  static Future<_ComposerHarness> create() async {
    final database = openTestDatabase();
    final accounts = AccountRepository(database);
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
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
    final conversation = await database
        .select(database.cachedConversations)
        .getSingle();
    final vault = MemoryCredentialVault()
      ..values[account.id] = 'fixture-app-password';
    final sentMessages = <String>[];
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return http.Response(
            jsonEncode(
              capabilitiesJson(
                talkFeatures: const <String>[
                  'conversation-v4',
                  'chat-v2',
                  'chat-reference-id',
                ],
              ),
            ),
            200,
          );
        }
        if (request.method == 'POST') {
          sentMessages.add(request.bodyFields['message']!);
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(
                _sendResponse(
                  referenceId: request.bodyFields['referenceId']!,
                  message: request.bodyFields['message']!,
                ),
              ),
            ),
            201,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
              'X-Chat-Last-Common-Read': '110',
            },
          );
        }
        if (request.url.path.contains('/avatar/')) {
          return http.Response('', 404);
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/apps/spreed/api/v1/chat/rooma123')) {
          return http.Response('', 304);
        }
        return http.Response('', 404);
      }),
    );
    return _ComposerHarness(
      database: database,
      account: account,
      conversation: conversation,
      vault: vault,
      api: api,
      sentMessages: sentMessages,
    );
  }

  Widget app({List<Override> overrides = const <Override>[]}) {
    return ProviderScope(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
        ...overrides,
      ],
      child: localizedTestApp(
        home: ChatRoomPane(account: account, conversation: conversation),
      ),
    );
  }

  Future<void> close() async {
    api.close();
    await database.close();
  }
}

HttpGiphyRepository _giphyRepository() {
  return HttpGiphyRepository(
    server: ServerBase.parse('https://cloud.example.invalid'),
    authorization: const GiphyAuthorization(
      loginName: 'fixture-user',
      appPassword: 'fixture-app-password',
    ),
    client: MockClient((request) async {
      if (request.url.path.endsWith('/gifs/trending')) {
        return http.Response(
          jsonEncode(<String, Object?>{
            'ocs': <String, Object?>{
              'meta': <String, Object?>{
                'status': 'ok',
                'statuscode': 200,
                'message': 'OK',
              },
              'data': <String, Object?>{
                'entries': <Object?>[
                  <String, Object?>{
                    'thumbnailUrl':
                        'https://cloud.example.invalid/'
                        'apps/integration_giphy/gif/wave',
                    'title': 'Wave',
                    'subline': 'Fixture author',
                    'resourceUrl': 'https://giphy.com/gifs/wave',
                  },
                ],
                'cursor': 1,
              },
            },
          }),
          200,
        );
      }
      if (request.url.path == '/apps/integration_giphy/gif/wave') {
        return http.Response.bytes(
          base64Decode('R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=='),
          200,
          headers: const <String, String>{'content-type': 'image/gif'},
        );
      }
      return http.Response('', 404);
    }),
  );
}

Map<String, Object?> _conversationRoomJson() {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
  final lastMessage = Map<String, Object?>.from(
    room['lastMessage']! as Map<String, Object?>,
  );
  lastMessage['id'] = 109;
  room['lastMessage'] = lastMessage;
  return room;
}

Map<String, Object?> _sendResponse({
  required String referenceId,
  required String message,
}) {
  final response =
      readFixtureJson('chat-messages/fixtures/send-success.response.json')!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  data['referenceId'] = referenceId;
  data['message'] = message;
  return response;
}
