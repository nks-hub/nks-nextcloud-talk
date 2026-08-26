import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/attachment_repository.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/features/chat/attachment_service.dart';
import 'package:nextcloudtalk/features/chat/chat_service.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

/// Counts the server round trips one attachment upload costs.
///
/// The wiring mirrors `app_providers.dart`: the attachment runtime confirms a
/// finalized upload through [ChatService], so both services share one account,
/// one database and one server. Every request the mock answers is logged, so a
/// change that adds a round trip to an upload fails here instead of only
/// showing up in a server access log.
void main() {
  test(
    'an upload with no open room costs three steps and one catch-up',
    () async {
      final fixture = await _UploadFixture.create();
      addTearDown(fixture.close);

      await fixture.settleRoom();
      fixture.reset();

      final session = await fixture.service.enqueue(fixture.enqueueRequest());
      await session.events.firstWhere(
        (event) => event.phase == AttachmentJobPhase.completed,
      );
      await fixture.settleTraffic();

      expect(fixture.log, <String>[
        'POST attachment/folder',
        'PUT dav',
        'POST attachment',
        // The confirmation has to observe the server-created message, and the
        // catch-up drains to convergence so the room can long poll again.
        'GET chat future',
        'GET chat future',
      ]);
      expect(fixture.capabilityRequests, 0, reason: 'capabilities stay cached');
    },
  );

  test('an upload from an open room adds no chat request of its own', () async {
    final fixture = await _UploadFixture.create();
    addTearDown(fixture.close);

    await fixture.settleRoom();
    final binding = fixture.chatService.bindLiveRoom(
      accountId: 'account-a',
      roomToken: 'rooma123',
    );
    addTearDown(binding.close);
    await binding.synchronize();

    fixture.reset();
    fixture.holdFuturePolls = true;
    final poll = binding.synchronize();
    await fixture.livePollStarted.future;

    final session = await fixture.service.enqueue(fixture.enqueueRequest());
    await session.events.firstWhere(
      (event) => event.phase == AttachmentJobPhase.completed,
    );
    await poll;
    await fixture.settleTraffic();

    expect(fixture.log, <String>[
      'GET chat future',
      'POST attachment/folder',
      'PUT dav',
      'POST attachment',
    ]);
    expect(
      fixture.chatRequests,
      1,
      reason: 'the room poll already fetched the confirming message',
    );
  });
}

final class _UploadFixture {
  _UploadFixture._({
    required this.directory,
    required this.database,
    required this.sourceFile,
    required this.bytes,
    required this.credentials,
    required this.repository,
  });

  static const _referenceId = '11111111-1111-4111-8111-111111111111';
  static const _confirmationMessageId = 120;

  static Future<_UploadFixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'nctalk-upload-budget-',
    );
    final bytes = utf8.encode('12345678');
    final sourceFile = File(
      '${directory.path}${Platform.pathSeparator}source.bin',
    );
    await sourceFile.writeAsBytes(bytes, flush: true);

    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final accounts = AccountRepository(database);
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final credentials = MemoryCredentialVault();
    credentials.values[account.id] = 'fixture-app-password-never-use';

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

    final fixture = _UploadFixture._(
      directory: directory,
      database: database,
      sourceFile: sourceFile,
      bytes: bytes,
      credentials: credentials,
      repository: AttachmentRepository(database),
    );
    fixture._wire(AccountRepository(database), ChatRepository(database));
    return fixture;
  }

  final Directory directory;
  final AppDatabase database;
  final File sourceFile;
  final List<int> bytes;
  final MemoryCredentialVault credentials;
  final AttachmentRepository repository;

  final List<String> log = <String>[];
  final Completer<void> livePollStarted = Completer<void>();
  final List<Completer<http.Response>> _heldPolls =
      <Completer<http.Response>>[];

  int chatRequests = 0;
  int capabilityRequests = 0;
  bool holdFuturePolls = false;
  bool _finalized = false;
  bool _confirmationDelivered = false;

  late final HttpNextcloudApi api;
  late final ChatService chatService;
  late final AttachmentService service;

  void reset() {
    log.clear();
    chatRequests = 0;
    capabilityRequests = 0;
  }

  void _wire(AccountRepository accounts, ChatRepository chat) {
    final client = MockClient(_handle);
    api = HttpNextcloudApi(client: client);
    chatService = ChatService(
      accounts: accounts,
      chat: chat,
      credentials: credentials,
      api: api,
    );
    service = AttachmentService(
      repository: repository,
      credentials: credentials,
      releaseSource: (source) async {
        final file = File.fromUri(Uri.parse(source.handle.value));
        if (await file.exists()) {
          await file.delete();
        }
      },
      transport: HttpAttachmentTransport(
        client: client,
        sourceProvider: _FileSourceProvider(),
      ),
      identifierFactory: _IdentifierFactory(),
      retryDelays: const <Duration>[Duration(milliseconds: 1)],
      confirmationRetryDelays: const <Duration>[Duration(milliseconds: 1)],
      catchUpConfirmation:
          ({required accountId, required roomToken, required threadId}) =>
              chatService.catchUpRoom(
                accountId: accountId.value,
                roomToken: roomToken.value,
                threadId: threadId,
              ),
    );
  }

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/cloud/capabilities')) {
      capabilityRequests++;
      log.add('GET capabilities');
      return http.Response(jsonEncode(_capabilities()), 200);
    }
    if (request.method == 'POST' && path.endsWith('/attachment/folder')) {
      log.add('POST attachment/folder');
      return http.Response(jsonEncode(_probeSuccess()), 200);
    }
    if (request.method == 'PUT') {
      log.add('PUT dav');
      return http.Response('', 201);
    }
    if (request.method == 'POST' && path.endsWith('/attachment')) {
      log.add('POST attachment');
      _finalized = true;
      _releaseHeldPolls();
      return http.Response(jsonEncode(_finalizeSuccess()), 200);
    }
    if (request.method == 'GET' && path.contains('/apps/spreed/api/v1/chat/')) {
      chatRequests++;
      final future = request.url.queryParameters['lookIntoFuture'] == '1';
      log.add('GET chat ${future ? 'future' : 'history'}');
      if (!future) {
        return http.Response(
          jsonEncode(_emptyHistory()),
          200,
          headers: const <String, String>{
            'X-Chat-Last-Given': '109',
            'X-Chat-Last-Common-Read': '109',
          },
        );
      }
      if (holdFuturePolls && !_finalized) {
        // Stands in for the 30 s long poll an open room keeps parked on the
        // server until the upload's own message wakes it.
        final held = Completer<http.Response>();
        _heldPolls.add(held);
        if (!livePollStarted.isCompleted) {
          livePollStarted.complete();
        }
        return held.future;
      }
      return _futureAnswer();
    }
    fail('Unexpected request: ${request.method} ${request.url}');
  }

  void _releaseHeldPolls() {
    final held = List<Completer<http.Response>>.of(_heldPolls);
    _heldPolls.clear();
    for (final completer in held) {
      completer.complete(_futureAnswer());
    }
  }

  http.Response _futureAnswer() {
    if (!_finalized || _confirmationDelivered) {
      return http.Response('', 304);
    }
    _confirmationDelivered = true;
    return http.Response(
      jsonEncode(_confirmationPage()),
      200,
      headers: const <String, String>{
        'X-Chat-Last-Given': '$_confirmationMessageId',
        'X-Chat-Last-Common-Read': '$_confirmationMessageId',
      },
    );
  }

  /// Brings the room to the state a freshly opened chat screen leaves behind.
  Future<void> settleRoom() =>
      chatService.syncRoom(accountId: 'account-a', roomToken: 'rooma123');

  /// Waits until no further request reaches the server, so a catch-up that
  /// keeps running past job completion is still counted.
  Future<void> settleTraffic() async {
    var seen = -1;
    while (seen != log.length) {
      seen = log.length;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  AttachmentEnqueueRequest enqueueRequest() => AttachmentEnqueueRequest(
    accountId: AccountId.parse('account-a'),
    server: ServerBase.parse('https://cloud.example.invalid'),
    roomToken: ConversationToken.parse(
      'rooma123',
      path: r'$.roomToken',
      code: TalkProtocolErrorCode.invalidAttachmentModel,
    ),
    source: PreparedAttachmentSource(
      handle: AttachmentSourceHandle.parse(sourceFile.uri.toString()),
      ownership: AttachmentSourceOwnership.appOwnedCopy,
      byteLength: bytes.length,
      sha256: AttachmentSha256.parse(
        'ef797c8118f02dfb649607dd5d3f8c7623048c9c063d532cc95c5ed7a898a64f',
      ),
      mimeType: 'image/png',
      displayName: 'source.png',
    ),
    metadata: AttachmentMetadata(
      kind: AttachmentMessageKind.file,
      caption: null,
      replyTo: null,
      threadId: null,
      threadTitle: null,
      silent: false,
    ),
    davUserId: DavUserId.parse('fixture-user'),
    profile: _attachmentProfile(),
    credentialGeneration: 1,
    capabilityGeneration: 1,
    roomCanWrite: true,
    policy: AttachmentUploadPolicy(
      normalUploadMaximumBytes: 32,
      chunkSizeBytes: 4,
    ),
  );

  Future<void> close() async {
    await service.close();
    api.close();
    await database.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  static Map<String, Object?> _confirmationPage() {
    final response =
        jsonDecode(
              jsonEncode(
                readFixtureJson(
                  'chat-messages/fixtures/chat-future.response.json',
                ),
              ),
            )!
            as Map<String, Object?>;
    final ocs = response['ocs']! as Map<String, Object?>;
    final messages = ocs['data']! as List<Object?>;
    final message = Map<String, Object?>.from(
      messages.first! as Map<String, Object?>,
    );
    message['id'] = _confirmationMessageId;
    message['timestamp'] = 1770000000 + _confirmationMessageId;
    message['referenceId'] = _referenceId;
    message['actorId'] = 'fixture-user';
    message['messageType'] = 'comment';
    message['systemMessage'] = '';
    message['threadId'] = _confirmationMessageId;
    message['isThread'] = false;
    message['message'] = '{file}';
    message['messageParameters'] = <String, Object?>{
      'file': <String, Object?>{
        'type': 'file',
        'id': 'fixture-file',
        'name': 'source.png',
        'path': 'Talk/source.png',
        'link': 'https://cloud.example.invalid/index.php/f/1',
      },
    };
    ocs['data'] = <Object?>[message];
    return response;
  }

  static Map<String, Object?> _emptyHistory() => <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <Object?>[],
    },
  };

  static Map<String, Object?> _probeSuccess() => <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'folder': 'Talk/Fixture Room',
        'renames': <Object?>[],
      },
    },
  };

  static Map<String, Object?> _finalizeSuccess() => <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{},
    },
  };

  static Map<String, Object?> _capabilities() => capabilitiesJson(
    talkFeatures: const <String>[
      'conversation-v4',
      'chat-v2',
      'chat-reference-id',
    ],
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

AttachmentCapabilityProfile _attachmentProfile() =>
    AttachmentCapabilityProfile.fromSnapshot(
      CapabilitySnapshot.fromJson(<String, Object?>{
        'ocs': <String, Object?>{
          'meta': <String, Object?>{
            'status': 'ok',
            'statuscode': 200,
            'message': 'OK',
          },
          'data': <String, Object?>{
            'version': <String, Object?>{
              'major': 34,
              'minor': 0,
              'micro': 0,
              'string': '34.0.0',
              'edition': '',
            },
            'capabilities': <String, Object?>{
              'spreed': <String, Object?>{
                'features': <String>[
                  'chat-reference-id',
                  'voice-message-sharing',
                ],
                'config': <String, Object?>{
                  'attachments': <String, Object?>{
                    'allowed': true,
                    'conversation-subfolders': true,
                  },
                },
              },
            },
          },
        },
      }, context: CapabilityContext.authenticated),
      federated: false,
    );

final class _IdentifierFactory implements AttachmentIdentifierFactory {
  int _request = 0;

  @override
  AttachmentJobId newJobId() =>
      AttachmentJobId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');

  @override
  AttachmentRequestId newRequestId() =>
      AttachmentRequestId.parse('attachment-request-${++_request}');

  @override
  ChatReferenceId newReferenceId() =>
      ChatReferenceId.parse(_UploadFixture._referenceId);

  @override
  DavUploadSessionId newUploadSessionId() =>
      DavUploadSessionId.parse('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
}

final class _FileSourceProvider implements AttachmentSourceProvider {
  @override
  Future<AttachmentSourceLease> open(
    AttachmentSourceHandle handle, {
    AttachmentCancellationSignal? cancellationSignal,
  }) async => _FileSourceLease(File.fromUri(Uri.parse(handle.value)));
}

final class _FileSourceLease implements AttachmentSourceLease {
  const _FileSourceLease(this.file);

  final File file;

  @override
  Stream<List<int>> openRead({int offset = 0, int? length}) =>
      file.openRead(offset, length == null ? null : offset + length);

  @override
  Future<void> close() async {}
}
