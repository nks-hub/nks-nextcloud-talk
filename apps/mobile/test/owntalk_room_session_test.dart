import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_room_extras.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_settings_store.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'owntalk_extensions_test_support.dart';
import 'test_support.dart';

const _key = (accountId: 'account-a', roomToken: ownTalkTestToken);

Map<String, Object?> _activeRoom() {
  final fixture =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final room = Map<String, Object?>.from(
    ((fixture['ocs']! as Map<String, Object?>)['data']! as List<Object?>).first!
        as Map<String, Object?>,
  );
  final lastMessage = Map<String, Object?>.from(
    room['lastMessage']! as Map<String, Object?>,
  )..['token'] = ownTalkTestToken;
  return room
    ..['token'] = ownTalkTestToken
    ..['sessionId'] = 'active-session'
    ..['lastMessage'] = lastMessage;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Opening the room details on a desktop leaves and re-enters the room, which
  // starts a new room session. The shared settings are plain Basic-auth calls,
  // so a write already on its way must still report what the server did.
  test('a settings write that overlaps a new room session keeps its answer',
      () async {
    final database = openTestDatabase();
    addTearDown(database.close);
    await AccountRepository(database).upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final directory = await Directory.systemTemp.createTemp('owntalk-session-');
    addTearDown(() => directory.delete(recursive: true));
    final server = FakeOwnTalkServer();
    final patchArrived = Completer<void>();
    final releasePatch = Completer<void>();
    final api = HttpNextcloudApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/participants/active')) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'ocs': <String, Object?>{
                'meta': <String, Object?>{
                  'status': 'ok',
                  'statuscode': 200,
                  'message': 'OK',
                },
                'data': _activeRoom(),
              },
            }),
            200,
            headers: const {
              'content-type': 'application/json',
              'set-cookie': 'nc_session=next; Path=/',
            },
          );
        }
        if (request.method == 'PATCH') {
          patchArrived.complete();
          await releasePatch.future;
        }
        return server.handle(request);
      }),
    );
    addTearDown(api.close);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(
          MemoryCredentialVault()..values['account-a'] = 'fixture-password',
        ),
        nextcloudApiProvider.overrideWithValue(api),
        ownTalkSettingsStoreProvider.overrideWith(
          (ref) => OwnTalkSettingsStore.forTesting(directory),
        ),
        ownTalkSettingsPollIntervalProvider.overrideWithValue(
          const Duration(minutes: 5),
        ),
        appLifecycleResumeEventsProvider.overrideWithValue(
          const Stream<void>.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(ownTalkRoomExtrasProvider(_key), (_, _) {});
    final controller = container.read(ownTalkRoomExtrasProvider(_key).notifier);
    await controller.refresh();

    final saving = controller.save({
      OwnTalkSettingField.chatBackgroundColor: '#2F6FEB',
    });
    await patchArrived.future;
    await api.activateRoomSession(
      activeRequest: ActiveRoomSessionRequest(
        accountId: AccountId.parse('account-a'),
        server: ServerBase.parse('https://cloud.example.invalid'),
        roomToken: ConversationToken.parse(
          ownTalkTestToken,
          path: r'$.roomToken',
        ),
      ),
      loginName: 'fixture-user',
      appPassword: 'fixture-password',
    );
    releasePatch.complete();

    final result = await saving;
    expect(result, isA<OwnTalkSettingsSaved>());
    expect(server.settings['chat.backgroundColor'], '#2F6FEB');
    expect(
      container
          .read(ownTalkRoomExtrasProvider(_key))
          .valueOf(OwnTalkSettingField.chatBackgroundColor),
      '#2F6FEB',
    );
  });
}
