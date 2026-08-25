import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_attachment_context.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late ChatRepository chat;
  late MemoryCredentialVault credentials;
  late AttachmentUploadPolicy uploadPolicy;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    chat = ChatRepository(database);
    credentials = MemoryCredentialVault();
    uploadPolicy = AttachmentUploadPolicy(
      normalUploadMaximumBytes: 1048576,
      chunkSizeBytes: 1024000,
    );
    await _storeAccountAndRoom(
      database: database,
      accounts: accounts,
      credentials: credentials,
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user-a',
      roomJson: _roomJson(),
    );
  });

  tearDown(() => database.close());

  test('resolves an image request with current account authority', () async {
    final api = _api((request) async {
      expect(request.url.host, 'cloud.example.invalid');
      expect(request.url.path, endsWith('/cloud/capabilities'));
      expect(request.headers['Authorization'], startsWith('Basic '));
      return http.Response(jsonEncode(_attachmentCapabilities()), 200);
    });
    addTearDown(api.close);
    final resolver = _resolver(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
      uploadPolicy: uploadPolicy,
    );

    final request = await resolver.resolve(
      accountId: AccountId.parse('account-a'),
      roomToken: _roomToken(),
      source: _source(),
      metadata: _metadata(),
    );

    expect(request.accountId, AccountId.parse('account-a'));
    expect(request.server, ServerBase.parse('https://cloud.example.invalid'));
    expect(request.roomToken, _roomToken());
    expect(request.davUserId, DavUserId.parse('fixture-user-a'));
    expect(request.credentialGeneration, 1);
    expect(request.capabilityGeneration, 1);
    expect(request.roomCanWrite, isTrue);
    expect(request.profile.enabled, isTrue);
    expect(request.policy, same(uploadPolicy));
  });

  test('resolves a fresh voice capability profile before recording', () async {
    final api = _api(
      (_) async => http.Response(jsonEncode(_attachmentCapabilities()), 200),
    );
    addTearDown(api.close);
    final resolver = _resolver(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
      uploadPolicy: uploadPolicy,
    );

    final profile = await resolver.resolveProfile(
      accountId: AccountId.parse('account-a'),
      roomToken: _roomToken(),
    );

    expect(profile.enabled, isTrue);
    expect(profile.voice, isTrue);
    expect(profile.threads, isTrue);
    expect(
      await database.select(database.chatCapabilities).get(),
      hasLength(1),
    );
  });

  test('binds voice, reply and thread metadata to capabilities', () async {
    final api = _api(
      (_) async => http.Response(jsonEncode(_attachmentCapabilities()), 200),
    );
    addTearDown(api.close);
    final resolver = _resolver(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
      uploadPolicy: uploadPolicy,
    );

    final request = await resolver.resolve(
      accountId: AccountId.parse('account-a'),
      roomToken: _roomToken(),
      source: _source(mimeType: 'audio/mpeg', displayName: 'voice.mp3'),
      metadata: _metadata(
        kind: AttachmentMessageKind.voice,
        caption: 'Synthetic caption',
        replyTo: 40,
        threadId: 42,
        threadTitle: 'Synthetic thread',
        silent: true,
      ),
    );

    expect(request.profile.voice, isTrue);
    expect(request.profile.caption, isTrue);
    expect(request.profile.reply, isTrue);
    expect(request.profile.threads, isTrue);
    expect(request.profile.silent, isTrue);
    expect(request.metadata.expectedMessageType, 'voice-message');
  });

  test('keeps authority and generations isolated between accounts', () async {
    await _storeAccountAndRoom(
      database: database,
      accounts: accounts,
      credentials: credentials,
      accountId: 'account-b',
      serverUrl: 'https://second.example.invalid',
      loginName: 'fixture-user-b',
      roomJson: _roomJson(),
    );
    final requestedHosts = <String>[];
    final api = _api((request) async {
      requestedHosts.add(request.url.host);
      return http.Response(jsonEncode(_attachmentCapabilities()), 200);
    });
    addTearDown(api.close);
    final resolver = _resolver(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
      uploadPolicy: uploadPolicy,
    );

    final first = await resolver.resolve(
      accountId: AccountId.parse('account-a'),
      roomToken: _roomToken(),
      source: _source(handle: 'source-a'),
      metadata: _metadata(),
    );
    final second = await resolver.resolve(
      accountId: AccountId.parse('account-b'),
      roomToken: _roomToken(),
      source: _source(handle: 'source-b'),
      metadata: _metadata(),
    );

    expect(requestedHosts, ['cloud.example.invalid', 'second.example.invalid']);
    expect(first.accountId, isNot(second.accountId));
    expect(first.server, isNot(second.server));
    expect(first.davUserId, DavUserId.parse('fixture-user-a'));
    expect(second.davUserId, DavUserId.parse('fixture-user-b'));
    expect(first.capabilityGeneration, 1);
    expect(second.capabilityGeneration, 1);
    expect(
      await database.select(database.chatCapabilities).get(),
      hasLength(2),
    );
  });

  test('fails before network access when the credential is missing', () async {
    credentials.values.clear();
    var requested = false;
    final api = _api((_) async {
      requested = true;
      return http.Response(jsonEncode(_attachmentCapabilities()), 200);
    });
    addTearDown(api.close);

    await expectLater(
      _resolver(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
        uploadPolicy: uploadPolicy,
      ).resolve(
        accountId: AccountId.parse('account-a'),
        roomToken: _roomToken(),
        source: _source(),
        metadata: _metadata(),
      ),
      _throwsContextError(ChatAttachmentContextError.credentialMissing),
    );
    expect(requested, isFalse);
  });

  test('rejects a read-only room before network access', () async {
    await _replaceRoom(database, _roomJson(readOnly: 1));
    var requested = false;
    final api = _api((_) async {
      requested = true;
      return http.Response(jsonEncode(_attachmentCapabilities()), 200);
    });
    addTearDown(api.close);

    await expectLater(
      _resolver(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
        uploadPolicy: uploadPolicy,
      ).resolve(
        accountId: AccountId.parse('account-a'),
        roomToken: _roomToken(),
        source: _source(),
        metadata: _metadata(),
      ),
      _throwsContextError(ChatAttachmentContextError.readOnly),
    );
    expect(requested, isFalse);
  });

  test('rejects a federated room before network access', () async {
    await _replaceRoom(
      database,
      _roomJson(remoteServer: 'remote.example.invalid'),
    );
    var requested = false;
    final api = _api((_) async {
      requested = true;
      return http.Response(jsonEncode(_attachmentCapabilities()), 200);
    });
    addTearDown(api.close);

    await expectLater(
      _resolver(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
        uploadPolicy: uploadPolicy,
      ).resolve(
        accountId: AccountId.parse('account-a'),
        roomToken: _roomToken(),
        source: _source(),
        metadata: _metadata(),
      ),
      _throwsContextError(ChatAttachmentContextError.federatedUnsupported),
    );
    expect(requested, isFalse);
  });

  test('rejects a cached conversation whose payload token differs', () async {
    await _replaceRoom(
      database,
      _roomJson(payloadToken: 'roomb456'),
      cacheToken: 'rooma123',
    );
    final api = _api(
      (_) async => http.Response(jsonEncode(_attachmentCapabilities()), 200),
    );
    addTearDown(api.close);

    await expectLater(
      _resolver(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
        uploadPolicy: uploadPolicy,
      ).resolve(
        accountId: AccountId.parse('account-a'),
        roomToken: _roomToken(),
        source: _source(),
        metadata: _metadata(),
      ),
      _throwsContextError(ChatAttachmentContextError.invalidConversation),
    );
  });

  test(
    'increments only the account capability generation after a change',
    () async {
      var requestCount = 0;
      var now = DateTime.utc(2026, 8, 24, 12);
      final api = _api((_) async {
        requestCount++;
        final features = requestCount == 1
            ? const <String>{'chat-reference-id'}
            : const <String>{'chat-reference-id', 'media-caption'};
        return http.Response(
          jsonEncode(_attachmentCapabilities(talkFeatures: features)),
          200,
        );
      }, clock: () => now);
      addTearDown(api.close);
      final resolver = _resolver(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
        uploadPolicy: uploadPolicy,
      );

      final first = await resolver.resolve(
        accountId: AccountId.parse('account-a'),
        roomToken: _roomToken(),
        source: _source(handle: 'source-a'),
        metadata: _metadata(),
      );
      // The server gains a feature only after the first snapshot has fallen out
      // of its validity window, so the second resolve reads it fresh.
      now = now.add(const Duration(minutes: 6));
      final second = await resolver.resolve(
        accountId: AccountId.parse('account-a'),
        roomToken: _roomToken(),
        source: _source(handle: 'source-b'),
        metadata: _metadata(),
      );

      expect(first.capabilityGeneration, 1);
      expect(second.capabilityGeneration, 2);
      expect(second.credentialGeneration, 1);
    },
  );

  test(
    'a 401 marks reauthentication without recording a false generation',
    () async {
      var requestCount = 0;
      var now = DateTime.utc(2026, 8, 24, 12);
      final api = _api((_) async {
        requestCount++;
        return requestCount == 1
            ? http.Response(jsonEncode(_attachmentCapabilities()), 200)
            : http.Response('', 401);
      }, clock: () => now);
      addTearDown(api.close);
      final resolver = _resolver(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
        uploadPolicy: uploadPolicy,
      );
      await resolver.resolve(
        accountId: AccountId.parse('account-a'),
        roomToken: _roomToken(),
        source: _source(handle: 'source-a'),
        metadata: _metadata(),
      );

      // The session expires only after the first snapshot has fallen out of its
      // validity window, so the second resolve reaches the rejecting server.
      now = now.add(const Duration(minutes: 6));
      await expectLater(
        resolver.resolve(
          accountId: AccountId.parse('account-a'),
          roomToken: _roomToken(),
          source: _source(handle: 'source-b'),
          metadata: _metadata(),
        ),
        _throwsContextError(
          ChatAttachmentContextError.reauthenticationRequired,
        ),
      );
      final stored = await database
          .select(database.chatCapabilities)
          .getSingle();
      expect(stored.generation, 1);
      expect(stored.credentialGeneration, 1);
      expect(stored.lane, ChatAccountLane.reauthenticationRequired.name);
    },
  );

  test('rejects a voice MIME before capabilities are fetched', () async {
    var requested = false;
    final api = _api((_) async {
      requested = true;
      return http.Response(jsonEncode(_attachmentCapabilities()), 200);
    });
    addTearDown(api.close);

    await expectLater(
      _resolver(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
        uploadPolicy: uploadPolicy,
      ).resolve(
        accountId: AccountId.parse('account-a'),
        roomToken: _roomToken(),
        source: _source(mimeType: 'audio/ogg', displayName: 'voice.ogg'),
        metadata: _metadata(kind: AttachmentMessageKind.voice),
      ),
      _throwsContextError(ChatAttachmentContextError.sourceUnsupported),
    );
    expect(requested, isFalse);
  });

  test('rejects metadata that the current capability profile lacks', () async {
    final api = _api(
      (_) async => http.Response(
        jsonEncode(
          _attachmentCapabilities(
            talkFeatures: const <String>{'chat-reference-id'},
          ),
        ),
        200,
      ),
    );
    addTearDown(api.close);

    await expectLater(
      _resolver(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
        uploadPolicy: uploadPolicy,
      ).resolve(
        accountId: AccountId.parse('account-a'),
        roomToken: _roomToken(),
        source: _source(mimeType: 'audio/mpeg', displayName: 'voice.mp3'),
        metadata: _metadata(kind: AttachmentMessageKind.voice),
      ),
      _throwsContextError(ChatAttachmentContextError.attachmentUnsupported),
    );
  });

  test(
    'discards capabilities when the local identity changes in flight',
    () async {
      final api = _api((_) async {
        await (database.update(database.accounts)
              ..where((row) => row.id.equals('account-a')))
            .write(const AccountsCompanion(loginName: Value('replacement')));
        return http.Response(jsonEncode(_attachmentCapabilities()), 200);
      });
      addTearDown(api.close);

      await expectLater(
        _resolver(
          accounts: accounts,
          chat: chat,
          credentials: credentials,
          api: api,
          uploadPolicy: uploadPolicy,
        ).resolve(
          accountId: AccountId.parse('account-a'),
          roomToken: _roomToken(),
          source: _source(),
          metadata: _metadata(),
        ),
        _throwsContextError(ChatAttachmentContextError.contextChanged),
      );
      expect(await database.select(database.chatCapabilities).get(), isEmpty);
    },
  );

  test('rejects a login name that cannot form a DAV user id', () async {
    await (database.update(database.accounts)
          ..where((row) => row.id.equals('account-a')))
        .write(const AccountsCompanion(loginName: Value('..')));
    final api = _api(
      (_) async => http.Response(jsonEncode(_attachmentCapabilities()), 200),
    );
    addTearDown(api.close);

    await expectLater(
      _resolver(
        accounts: accounts,
        chat: chat,
        credentials: credentials,
        api: api,
        uploadPolicy: uploadPolicy,
      ).resolve(
        accountId: AccountId.parse('account-a'),
        roomToken: _roomToken(),
        source: _source(),
        metadata: _metadata(),
      ),
      _throwsContextError(ChatAttachmentContextError.identityUnverified),
    );
  });
}

const Set<String> _requiredAttachmentFeatures = <String>{
  'chat-reference-id',
  'media-caption',
  'voice-message-sharing',
  'chat-replies',
  'threads',
  'silent-send',
};

ChatAttachmentContextResolver _resolver({
  required AccountRepository accounts,
  required ChatRepository chat,
  required MemoryCredentialVault credentials,
  required HttpNextcloudApi api,
  required AttachmentUploadPolicy uploadPolicy,
}) => ChatAttachmentContextResolver(
  accounts: accounts,
  chat: chat,
  credentials: credentials,
  api: api,
  uploadPolicy: uploadPolicy,
  clock: () => DateTime.utc(2026, 8, 24, 12),
);

HttpNextcloudApi _api(
  Future<http.Response> Function(http.Request request) handler, {
  DateTime Function()? clock,
}) => HttpNextcloudApi(client: MockClient(handler), clock: clock);

Matcher _throwsContextError(ChatAttachmentContextError code) => throwsA(
  isA<ChatAttachmentContextException>().having(
    (error) => error.code,
    'code',
    code,
  ),
);

ConversationToken _roomToken() => ConversationToken.parse(
  'rooma123',
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidAttachmentModel,
);

PreparedAttachmentSource _source({
  String handle = 'source-a',
  String mimeType = 'image/jpeg',
  String displayName = 'photo.jpg',
}) => PreparedAttachmentSource(
  handle: AttachmentSourceHandle.parse(handle),
  ownership: AttachmentSourceOwnership.appOwnedCopy,
  byteLength: 1024,
  sha256: AttachmentSha256.parse(
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  ),
  mimeType: mimeType,
  displayName: displayName,
);

AttachmentMetadata _metadata({
  AttachmentMessageKind kind = AttachmentMessageKind.file,
  String? caption,
  int? replyTo,
  int? threadId,
  String? threadTitle,
  bool silent = false,
}) => AttachmentMetadata(
  kind: kind,
  caption: caption,
  replyTo: replyTo,
  threadId: threadId,
  threadTitle: threadTitle,
  silent: silent,
);

Map<String, Object?> _attachmentCapabilities({
  Set<String> talkFeatures = _requiredAttachmentFeatures,
}) {
  final result = capabilitiesJson(talkFeatures: talkFeatures);
  final ocs = result['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final capabilities = data['capabilities']! as Map<String, Object?>;
  final spreed = capabilities['spreed']! as Map<String, Object?>;
  spreed['config'] = <String, Object?>{
    'attachments': <String, Object?>{
      'allowed': true,
      'conversation-subfolders': true,
    },
  };
  return result;
}

Map<String, Object?> _roomJson({
  int readOnly = 0,
  String? remoteServer,
  String payloadToken = 'rooma123',
}) {
  final response =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = jsonDecode(jsonEncode(rooms.first)) as Map<String, Object?>;
  room['token'] = payloadToken;
  room['readOnly'] = readOnly;
  if (remoteServer == null) {
    room.remove('remoteServer');
  } else {
    room['remoteServer'] = remoteServer;
  }
  final preview = room['lastMessage'];
  if (preview is Map<String, Object?>) {
    preview['token'] = payloadToken;
  }
  return room;
}

Future<void> _storeAccountAndRoom({
  required AppDatabase database,
  required AccountRepository accounts,
  required MemoryCredentialVault credentials,
  required String accountId,
  required String serverUrl,
  required String loginName,
  required Map<String, Object?> roomJson,
}) async {
  await accounts.upsertAccount(
    accountId: accountId,
    serverUrl: serverUrl,
    loginName: loginName,
    serverProductName: 'Nextcloud',
    createdAt: DateTime.utc(2026, 1, 1),
  );
  credentials.values[accountId] = 'fixture-app-password-never-use';
  await _insertRoom(
    database: database,
    accountId: accountId,
    cacheToken: roomJson['token']! as String,
    roomJson: roomJson,
  );
}

Future<void> _replaceRoom(
  AppDatabase database,
  Map<String, Object?> roomJson, {
  String cacheToken = 'rooma123',
}) => _insertRoom(
  database: database,
  accountId: 'account-a',
  cacheToken: cacheToken,
  roomJson: roomJson,
);

Future<void> _insertRoom({
  required AppDatabase database,
  required String accountId,
  required String cacheToken,
  required Map<String, Object?> roomJson,
}) async {
  final room = ConversationRoom.fromJson(roomJson);
  await database
      .into(database.cachedConversations)
      .insertOnConflictUpdate(
        CachedConversationsCompanion.insert(
          accountId: accountId,
          token: cacheToken,
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
}
