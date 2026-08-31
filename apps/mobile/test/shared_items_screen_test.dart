import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/shareditems/shared_items_screen.dart';
import 'package:nextcloudtalk/features/shareditems/shared_items_service.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  testWidgets('shows available categories and the selected page', (
    tester,
  ) async {
    final service = _FakeSharedItemsService(
      overviewHandler: (_, _) async => _overview({
        SharedItemType.file: [110],
        SharedItemType.media: [112],
      }),
      pageHandler: (_, _, type, _, _) async => _page(
        type: type,
        messageIds: [type == SharedItemType.file ? 110 : 112],
      ),
    );

    await _pumpScreen(tester, service);

    expect(find.byKey(const Key('shared-items-category-file')), findsOneWidget);
    expect(
      find.byKey(const Key('shared-items-category-media')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('shared-item-110')), findsOneWidget);
    expect(find.text('Fixture message 110'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ignores a stale page after switching categories', (
    tester,
  ) async {
    final filePage = Completer<SharedItemsPageResponse>();
    Future<void>? fileAbort;
    final service = _FakeSharedItemsService(
      overviewHandler: (_, _) async => _overview({
        SharedItemType.file: [110],
        SharedItemType.media: [112],
      }),
      pageHandler: (_, _, type, _, abortTrigger) {
        if (type == SharedItemType.file) {
          fileAbort = abortTrigger;
          return filePage.future;
        }
        return _page(type: type, messageIds: const [112]);
      },
    );

    await _pumpScreen(tester, service, settle: false);
    await tester.pump();
    await tester.tap(find.byKey(const Key('shared-items-category-media')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('shared-item-112')), findsOneWidget);
    await expectLater(fileAbort, completes);

    filePage.complete(
      _page(type: SharedItemType.file, messageIds: const [110]),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('shared-item-112')), findsOneWidget);
    expect(find.byKey(const Key('shared-item-110')), findsNothing);
  });

  testWidgets('loads the next page without replacing existing items', (
    tester,
  ) async {
    var pageCalls = 0;
    final firstIds = List<int>.generate(28, (index) => 200 - index);
    final service = _FakeSharedItemsService(
      overviewHandler: (_, _) async => _overview({
        SharedItemType.file: [200],
      }),
      pageHandler: (_, _, type, cursor, _) async {
        pageCalls++;
        return cursor == 0
            ? _page(type: type, messageIds: firstIds)
            : _page(
                type: type,
                messageIds: const [172],
                lastKnownMessageId: cursor,
              );
      },
    );

    await _pumpScreen(tester, service);
    await tester.scrollUntilVisible(
      find.byKey(const Key('shared-items-load-more')),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('shared-items-load-more')));
    await tester.pumpAndSettle();

    expect(pageCalls, 2);
    expect(find.byKey(const Key('shared-item-172')), findsOneWidget);
    expect(find.byKey(const Key('shared-items-load-more')), findsNothing);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, 5000));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shared-item-200')), findsOneWidget);
  });

  testWidgets('shows an empty overview and scales text without overflow', (
    tester,
  ) async {
    final service = _FakeSharedItemsService(
      overviewHandler: (_, _) async => _overview(const {}),
      pageHandler: (_, _, _, _, _) => throw StateError('page not expected'),
    );

    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpScreen(tester, service, textScaleFactor: 2);

    expect(find.byKey(const Key('shared-items-empty')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retries a failed overview', (tester) async {
    var attempts = 0;
    final service = _FakeSharedItemsService(
      overviewHandler: (_, _) {
        attempts++;
        if (attempts == 1) {
          throw const SharedItemsException(SharedItemsError.network);
        }
        return _overview(const {});
      },
      pageHandler: (_, _, _, _, _) => throw StateError('page not expected'),
    );

    await _pumpScreen(tester, service);
    expect(find.byKey(const Key('shared-items-error')), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.byKey(const Key('shared-items-empty')), findsOneWidget);
  });
}

typedef _OverviewHandler =
    FutureOr<SharedItemsOverviewResponse> Function(
      String accountId,
      String roomToken,
    );
typedef _PageHandler =
    FutureOr<SharedItemsPageResponse> Function(
      String accountId,
      String roomToken,
      SharedItemType type,
      int cursor,
      Future<void>? abortTrigger,
    );

final class _FakeSharedItemsService implements SharedItemsService {
  const _FakeSharedItemsService({
    required this.overviewHandler,
    required this.pageHandler,
  });

  final _OverviewHandler overviewHandler;
  final _PageHandler pageHandler;

  @override
  Future<SharedItemsOverviewResponse> overview({
    required String accountId,
    required String roomToken,
    Future<void>? abortTrigger,
  }) async => overviewHandler(accountId, roomToken);

  @override
  Future<SharedItemsPageResponse> page({
    required String accountId,
    required String roomToken,
    required SharedItemType type,
    required int lastKnownMessageId,
    Future<void>? abortTrigger,
  }) async =>
      pageHandler(accountId, roomToken, type, lastKnownMessageId, abortTrigger);
}

Future<void> _pumpScreen(
  WidgetTester tester,
  SharedItemsService service, {
  bool settle = true,
  double textScaleFactor = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedItemsServiceProvider.overrideWithValue(service)],
      child: localizedTestApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScaleFactor)),
          child: const SharedItemsScreen(
            account: _account,
            conversation: _conversation,
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  }
}

SharedItemsOverviewResponse _overview(
  Map<SharedItemType, List<int>> idsByType,
) {
  final request = SharedItemsOverviewRequest(
    accountId: AccountId.parse(_account.id),
    requestId: ChatRequestId.parse('shared-overview-test'),
    server: ServerBase.parse(_account.serverUrl),
    roomToken: _token(),
    sharedItemsAvailable: true,
    limit: sharedItemsOverviewLimit,
  );
  return decodeSharedItemsOverviewResponse(
    request: request,
    statusCode: 200,
    body: _body({
      for (final entry in idsByType.entries)
        entry.key.wireName: [for (final id in entry.value) _message(id)],
    }),
  );
}

SharedItemsPageResponse _page({
  required SharedItemType type,
  required List<int> messageIds,
  int lastKnownMessageId = 0,
}) {
  final request = SharedItemsPageRequest(
    accountId: AccountId.parse(_account.id),
    requestId: ChatRequestId.parse(
      'shared-page-${messageIds.firstOrNull ?? 0}',
    ),
    server: ServerBase.parse(_account.serverUrl),
    roomToken: _token(),
    sharedItemsAvailable: true,
    type: type,
    lastKnownMessageId: lastKnownMessageId,
    limit: sharedItemsPageLimit,
  );
  final minimum = messageIds.isEmpty
      ? null
      : messageIds.reduce((left, right) => left < right ? left : right);
  return decodeSharedItemsPageResponse(
    request: request,
    statusCode: 200,
    body: _body({for (final id in messageIds) '$id': _message(id)}),
    headers: ChatResponseHeaders.fromMap({
      if (minimum != null) 'X-Chat-Last-Given': '$minimum',
    }),
  );
}

Uint8List _body(Object? data) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'ocs': {
        'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
        'data': data,
      },
    }),
  ),
);

Map<String, Object?> _message(int id) => {
  'id': id,
  'token': _conversation.token,
  'actorType': 'users',
  'actorId': 'fixture-author',
  'actorDisplayName': 'Fixture author',
  'timestamp': 1724300000 + id,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': 'reference-$id',
  'message': 'Fixture message $id',
  'messageParameters': <String, Object?>{},
  'markdown': false,
  'reactions': <String, Object?>{},
};

ConversationToken _token() => ConversationToken.parse(
  _conversation.token,
  path: r'$.roomToken',
  code: TalkProtocolErrorCode.invalidSharedItemsRequest,
);

const _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '["rich-object-list-media"]',
  selected: true,
  createdAtMillis: 1767225600000,
  lastSyncError: null,
);

const _conversation = CachedConversation(
  accountId: 'account-a',
  token: 'rooma123',
  displayName: 'Fixture room',
  description: '',
  lastActivity: 1,
  unreadMessages: 0,
  favorite: false,
  isArchived: false,
  readOnly: 0,
  roomType: 2,
  roomName: '',
  objectType: '',
  avatarVersion: '',
  isCustomAvatar: false,
  peerStatus: null,
  peerStatusIcon: null,
  peerStatusMessage: null,
  lastMessageText: null,
  lastMessageTimestamp: null,
  rawJson: '{}',
);
