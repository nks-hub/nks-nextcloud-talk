import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/newconversation/new_conversation_service.dart';
import 'package:nextcloudtalk/features/rooms/room_settings_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import 'test_support.dart';

/// Opt-in creates and deletes only uniquely named rooms on a dedicated account.
void main() {
  test(
    'live preset creation and atomic public password lifecycle',
    () async {
      final live = _CreationLive();
      try {
        await live.prepare();
        await live.exercise();
        await live.waitForWebReadback();
        live.receipt['lifecyclePassed'] = true;
      } catch (_) {
        if (live.admitted) {
          live.receipt['failureReadback'] = (await live.rooms())
              .where((room) => live.expectedNames.contains(room.name))
              .map(
                (room) => {'type': room.type, 'hasPassword': room.hasPassword},
              )
              .toList();
        }
        rethrow;
      } finally {
        try {
          await live.cleanup();
        } finally {
          stdout.writeln(jsonEncode(live.receipt));
          live.api.close();
          await live.database.close();
        }
      }
    },
    skip: Platform.environment['NCTALK_CREATION_LIVE'] != 'YES'
        ? 'Set NCTALK_CREATION_LIVE=YES and dedicated account environment.'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

String _env(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) throw StateError('Missing $name');
  return value;
}

final class _CreationLive {
  final database = openTestDatabase();
  final api = HttpNextcloudApi();
  final vault = MemoryCredentialVault();
  final marker = 'Creation verification ${const Uuid().v4()}';
  final roomPassword = 'Aa9!${const Uuid().v4()}';
  final expectedNames = <String>{};
  final baseline = <String>{};
  final receipt = <String, Object?>{'event': 'conversation-creation-live'};
  late final ServerBase server;
  late final String username;
  late final String password;
  late final HttpNewConversationService creation;
  late final RoomSettingsService settings;
  var admitted = false;
  static const accountId = 'creation-live-owner';

  Future<void> prepare() async {
    server = ServerBase.parse(_env('NCTALK_CREATION_ORIGIN'));
    username = _env('NCTALK_CREATION_OWNER');
    password = _env('NCTALK_CREATION_PASSWORD');
    if (server.uri.scheme != 'https' ||
        !username.toLowerCase().contains('test')) {
      throw StateError('HTTPS and a dedicated test identity are required');
    }
    final profile = await api.getOwnProfile(
      server: server,
      loginName: username,
      appPassword: password,
    );
    if (profile.userId != username) {
      throw StateError('Canonical identity mismatch');
    }
    final accounts = AccountRepository(database);
    await accounts.upsertAccount(
      accountId: accountId,
      serverUrl: server.uri.toString(),
      loginName: username,
      serverProductName: 'Nextcloud',
      createdAt: DateTime.now().toUtc(),
    );
    vault.values[accountId] = password;
    creation = HttpNewConversationService(
      accounts: accounts,
      credentials: vault,
      api: api,
    );
    settings = RoomSettingsService(
      accounts: accounts,
      credentials: vault,
      chat: ChatRepository(database),
      api: api,
    );
    baseline.addAll((await rooms()).map((room) => room.token.value));
    final options = await creation.prepareCreation(accountId: accountId);
    if (options.catalog == null ||
        !options.supportsPassword ||
        !options.supportsExtendedFields) {
      throw StateError('Required creation capabilities are absent');
    }
    receipt['forcePasswords'] = options.forcePasswords;
    receipt['presets'] = options.catalog!.selectablePresets
        .map((p) => p.identifier)
        .toList();
    admitted = true;
  }

  Future<List<ConversationRoom>> rooms() async {
    final response = await api.getConversations(
      conversationRequest: ConversationListRequest(
        accountId: AccountId.parse(accountId),
        requestId: ConversationRequestId.parse(const Uuid().v4()),
        server: server,
        mode: ConversationFetchMode.full,
        includeLastMessage: false,
      ),
      loginName: username,
      appPassword: password,
    );
    if (response is! ConversationListSuccess) {
      throw StateError('Room readback refused');
    }
    return response.rooms;
  }

  Future<ConversationRoom> ownedRoom(ConversationToken token) async {
    final found = (await rooms()).where((r) => r.token == token).toList();
    if (found.length != 1) throw StateError('Expected created room is missing');
    final room = found.single;
    if (baseline.contains(room.token.value) ||
        !expectedNames.contains(room.name) ||
        room.participantType != 1 ||
        room.hasCall) {
      throw StateError('Created-room ownership guard failed');
    }
    final response = await api.getParticipants(
      participantsRequest: ParticipantsRequest(
        accountId: AccountId.parse(accountId),
        server: server,
        roomToken: room.token,
        includeStatus: false,
      ),
      loginName: username,
      appPassword: password,
    );
    if (response is! ParticipantsSuccess ||
        response.participants.length != 1 ||
        response.participants.single.actorType != 'users' ||
        response.participants.single.actorId != username) {
      throw StateError('The created room must contain only the test owner');
    }
    return room;
  }

  Future<ConversationRoom> create(
    String suffix,
    String preset,
    int type,
  ) async {
    final name = '$marker $suffix';
    final options = await creation.prepareCreation(accountId: accountId);
    final expected = options.effectiveParameters(preset, {'roomType': type});
    if (expected['roomType'] != type) {
      throw StateError('Unexpected forced room type');
    }
    expectedNames.add(name);
    final result = await creation.createPreparedConversation(
      options: options,
      roomName: name,
      presetIdentifier: preset,
      userParameters: {'roomType': type},
      password: type == 3 ? roomPassword : '',
    );
    final room = await ownedRoom(result.roomToken);
    if (result.failedInvitationCount != 0) {
      throw StateError('Unexpected invitations');
    }
    final observed = <String, int>{
      'roomType': room.type,
      'readOnly': room.readOnly,
      'listable': _wireInt(room, 'listable'),
      'messageExpiration': _wireInt(room, 'messageExpiration'),
      'lobbyState': room.lobbyState,
      'sipEnabled': room.sipEnabled,
      'recordingConsent': _wireInt(room, 'recordingConsent'),
      'mentionPermissions': room.mentionPermissions,
    };
    final displayed = {
      ...expected,
      if (options.recordingConsentPolicy == 0 ||
          options.recordingConsentPolicy == 1)
        'recordingConsent': options.recordingConsentPolicy!,
    };
    for (final entry in observed.entries) {
      if (displayed.containsKey(entry.key) &&
          entry.value != displayed[entry.key]) {
        throw StateError('Preset readback mismatch: ${entry.key}');
      }
    }
    final mask = expected['permissions'];
    if (mask != null && mask != 0 && room.defaultPermissions != (mask | 1)) {
      throw StateError('Preset default-permissions mismatch');
    }
    if (room.hasPassword != (type == 3)) {
      throw StateError('Initial password readback mismatch');
    }
    receipt['created'] ??= <Object?>[];
    (receipt['created'] as List).add({
      'preset': preset,
      'type': room.type,
      'hasPassword': room.hasPassword,
      'settingsMatched': true,
    });
    return room;
  }

  Future<void> exercise() async {
    receipt['stage'] = 'create private';
    final room = await create('private', 'default', 2);
    receipt['stage'] = 'prepare public';
    final access = await settings.preparePublicChange(
      accountId: accountId,
      roomToken: room.token.value,
    );
    receipt['stage'] = 'make public with password';
    await settings.setPublic(
      accountId: accountId,
      roomToken: room.token.value,
      public: true,
      password: roomPassword,
      prepared: access,
    );
    final public = await ownedRoom(room.token);
    if (public.type != 3 || !public.hasPassword) {
      throw StateError('Atomic protection failed');
    }
    receipt['stage'] = 'make private';
    await settings.setPublic(
      accountId: accountId,
      roomToken: room.token.value,
      public: false,
    );
    final private = await ownedRoom(room.token);
    if (private.type != 2) {
      throw StateError('Private transition failed');
    }
    receipt['privatePasswordRetained'] = private.hasPassword;
    receipt['atomicPublicPassword'] = true;
    receipt['closedToGuests'] = true;
    receipt['stage'] = 'create webinar';
    await create('webinar', 'webinar', 3);
    receipt['stage'] = 'verified';
  }

  Future<void> cleanup() async {
    if (!admitted) return;
    final candidates = (await rooms())
        .where(
          (room) =>
              !baseline.contains(room.token.value) &&
              expectedNames.contains(room.name),
        )
        .toList();
    var removed = 0;
    for (final candidate in candidates) {
      final verified = await ownedRoom(candidate.token);
      await settings.deleteRoom(
        accountId: accountId,
        roomToken: candidate.token.value,
        canDeleteConversation: verified.canDeleteConversation,
      );
      removed++;
    }
    final remaining = (await rooms())
        .where((room) => expectedNames.contains(room.name))
        .length;
    receipt['removedRooms'] = removed;
    receipt['remainingRooms'] = remaining;
    if (remaining != 0) throw StateError('Created-room cleanup is incomplete');
  }

  Future<void> waitForWebReadback() async {
    final path = Platform.environment['NCTALK_CREATION_RELEASE_FILE'];
    if (path == null) return;
    final signal = File(path);
    if (await signal.exists()) {
      throw StateError('The readback signal must be new');
    }
    final created = (await rooms())
        .where((room) => expectedNames.contains(room.name))
        .toList();
    stdout.writeln(
      jsonEncode({
        'event': 'await-creation-web-readback',
        'releaseFile': path,
        'rooms': created
            .map(
              (r) => {
                'token': r.token.value,
                'name': r.name,
                'type': r.type,
                'hasPassword': r.hasPassword,
              },
            )
            .toList(),
      }),
    );
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (!await signal.exists()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Web readback deadline expired');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    receipt['webReadbackReleased'] = true;
  }
}

int _wireInt(ConversationRoom room, String key) {
  final value = room.wire[key];
  if (value is! int) throw StateError('Missing integer room field: $key');
  return value;
}
