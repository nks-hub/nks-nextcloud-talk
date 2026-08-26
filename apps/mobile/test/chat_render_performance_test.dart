import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

/// Measures what the chat timeline costs per rendered frame.
///
/// The list is virtualized, so the cost that matters is per *visible* bubble,
/// not per cached message: whenever the pane rebuilds, every bubble in the
/// viewport runs `itemBuilder` again. This suite pins down that per-bubble
/// cost and proves it stays flat as the cached history grows.
void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;
  late StoredAccount account;

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
  });

  tearDown(() => database.close());

  Future<CachedConversation> seedRoom(String token, int messages) async {
    await database
        .into(database.cachedConversations)
        .insert(
          CachedConversationsCompanion.insert(
            accountId: account.id,
            token: token,
            displayName: 'Synthetic room $token',
            description: '',
            lastActivity: 1724300000,
            unreadMessages: 0,
            favorite: false,
            readOnly: const Value(0),
            roomType: const Value(2),
            roomName: Value('synthetic-$token'),
            objectType: const Value(''),
            avatarVersion: const Value(''),
            isCustomAvatar: const Value(false),
            rawJson: '{}',
          ),
        );
    await database.batch((batch) {
      for (var index = 0; index < messages; index++) {
        final wire = _wireMessage(token, 100 + index, index);
        batch.insert(
          database.cachedChatMessages,
          CachedChatMessagesCompanion.insert(
            accountId: account.id,
            roomToken: token,
            messageId: wire['id']! as int,
            actorType: 'users',
            actorId: wire['actorId']! as String,
            actorDisplayName: wire['actorDisplayName']! as String,
            timestamp: wire['timestamp']! as int,
            systemMessage: '',
            messageType: 'comment',
            referenceId: wire['referenceId']! as String,
            displayText: wire['message']! as String,
            deleted: false,
            rawJson: jsonEncode(wire),
          ),
        );
      }
    });
    await database
        .into(database.chatScopes)
        .insert(
          ChatScopesCompanion.insert(
            accountId: account.id,
            roomToken: token,
            scopeKey: 'root',
            historyCursor: '100',
            futureCursor: '${100 + messages - 1}',
            lastCommonRead: '${100 + messages - 1}',
            lastReadMessage: 100 + messages - 1,
            unreadMessages: 0,
            hasHistory: false,
            futureConverged: true,
            blocksJson: '[["100","${100 + messages - 1}"]]',
          ),
        );
    return (database.select(database.cachedConversations)
          ..where((row) => row.token.equals(token)))
        .getSingle();
  }

  Widget app(Widget home) => ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      credentialVaultProvider.overrideWithValue(vault),
      connectivityWakeEventsProvider.overrideWithValue(
        const Stream<void>.empty(),
      ),
      chatAttachmentDependenciesProvider.overrideWith(
        (ref, key) => Future<ChatAttachmentDependencies>.error(
          StateError('attachment dependencies are not wired in this suite'),
          StackTrace.empty,
        ),
      ),
    ],
    child: localizedTestApp(home: home),
  );

  Future<void> openRoom(WidgetTester tester, CachedConversation room) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(PresenceChatRoomScreen(account: account, conversation: room)),
    );
    await tester.pump();
    await tester.pump();
  }

  // Closing the room lets riverpod dispose the room providers and drift close
  // its query streams; without it the room's stream subscription outlives the
  // widget tree and the binding reports a pending timer.
  Future<void> closeRoom(WidgetTester tester) async {
    await tester.pumpWidget(app(const SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  test('decoding one viewport of bubbles stays inside a 60fps frame', () {
    final rows = List.generate(
      _visibleBubbles,
      (index) => jsonEncode(_wireMessage('rooma123', 100 + index, index)),
    );
    final server = ServerBase.parse('https://cloud.example.invalid');

    // Warm the JIT and the renderer's lazily built patterns so the number is
    // steady state, not first-call cost.
    for (var round = 0; round < 20; round++) {
      _decodeAndRender(rows, server);
    }

    final elapsed = _medianMicroseconds(
      rounds: 41,
      body: () => _decodeAndRender(rows, server),
    );
    debugPrint(
      'chat-render: viewport decode+render '
      '${(elapsed / 1000).toStringAsFixed(2)}ms for $_visibleBubbles bubbles '
      '(${(elapsed / _visibleBubbles).toStringAsFixed(1)}us each)',
    );

    // A full viewport may not spend a whole 60fps frame just turning cached
    // rows back into models. Devices are slower than this host, so the budget
    // stays a fraction of 16ms.
    expect(elapsed, lessThan(8000));
  });

  /// Median wall time of a pane rebuild: the frame the reader pays for
  /// whenever anything in the room changes while they are looking at it.
  /// Marking the pane element dirty reproduces exactly what a provider
  /// emission does, without the database round trip inside the measurement.
  Future<double> measureRebuild(
    WidgetTester tester,
    String token,
    int messages,
  ) async {
    await openRoom(tester, await seedRoom(token, messages));
    final pane = tester.element(find.byType(ChatRoomPane));
    final samples = <int>[];
    for (var round = 0; round < 21; round++) {
      pane.markNeedsBuild();
      final watch = Stopwatch()..start();
      await tester.pump();
      watch.stop();
      samples.add(watch.elapsedMicroseconds);
    }
    samples.sort();
    return samples[samples.length ~/ 2] / 1000;
  }

  testWidgets('a pane rebuild costs the same at 200 and 5000 messages', (
    tester,
  ) async {
    // An empty room renders the same pane chrome without a single bubble, so
    // the difference attributes the frame to the timeline rather than to the
    // header, the banners and the composer around it.
    final empty = await measureRebuild(tester, 'room00', 0);
    final small = await measureRebuild(tester, 'rooma1', 200);
    final large = await measureRebuild(tester, 'roomb2', 5000);
    await closeRoom(tester);
    debugPrint(
      'chat-render: pane rebuild empty ${empty.toStringAsFixed(2)}ms, '
      '200 msgs ${small.toStringAsFixed(2)}ms, '
      '5000 msgs ${large.toStringAsFixed(2)}ms',
    );

    // Virtualization guarantee: cached history size must not leak into the
    // per-frame cost. Twenty-five times the history may not cost twice the
    // rebuild.
    expect(large, lessThan(small * 2 + 4));
  });

  testWidgets('scrolling a long history keeps the median pump under a frame', (
    tester,
  ) async {
    await openRoom(tester, await seedRoom('roomc3', 400));
    final list = find.byKey(const Key('chat-message-list'));
    expect(list, findsOneWidget);

    final samples = <double>[];
    final gesture = await tester.startGesture(tester.getCenter(list));
    for (var step = 0; step < 30; step++) {
      await gesture.moveBy(const Offset(0, 40));
      final watch = Stopwatch()..start();
      await tester.pump(const Duration(milliseconds: 16));
      watch.stop();
      samples.add(watch.elapsedMicroseconds / 1000);
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 16));
    await closeRoom(tester);

    samples.sort();
    final median = samples[samples.length ~/ 2];
    final over16 = samples.where((value) => value > 16).length;
    debugPrint(
      'chat-render: scroll pumps median ${median.toStringAsFixed(2)}ms, '
      'p100 ${samples.last.toStringAsFixed(2)}ms, '
      '$over16/${samples.length} over 16ms',
    );

    expect(median, lessThan(16));
    expect(tester.takeException(), isNull);
  });

  // Documents a known defect rather than a wanted behaviour: see the closing
  // expectation for what a fix has to change here.
  testWidgets('a message arriving while the reader is in history moves it', (
    tester,
  ) async {
    const token = 'roomd4';
    await openRoom(tester, await seedRoom(token, 200));

    // Leave the bottom of the timeline the way a reader scrolling back does.
    await tester.drag(
      find.byKey(const Key('chat-message-list')),
      const Offset(0, 600),
    );
    await tester.pump();

    // Anchor on whatever bubble the reader is actually looking at rather than
    // on a hard-coded id, which depends on how far the drag happened to go.
    final prefix = 'chat-message-${account.id}-$token-';
    final built = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> && key.value.startsWith(prefix);
    });
    expect(built, findsWidgets);
    final anchor = find.byKey(tester.widgetList(built).first.key!);
    final before = tester.getTopLeft(anchor);
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('chat-message-list')),
        matching: find.byType(Scrollable),
      ),
    );
    final pixelsBefore = scrollable.position.pixels;
    final extentBefore = scrollable.position.maxScrollExtent;

    // The live loop appends a newer message at the reversed list's offset-zero
    // end while the reader is somewhere above it.
    await database
        .into(database.cachedChatMessages)
        .insert(
          CachedChatMessagesCompanion.insert(
            accountId: account.id,
            roomToken: token,
            messageId: 300,
            actorType: 'users',
            actorId: 'author-1',
            actorDisplayName: 'Author 1',
            timestamp: 1724300000 + (200 * 60),
            systemMessage: '',
            messageType: 'comment',
            referenceId: 'reference-$token-300',
            displayText: 'An arriving message that the reader did not ask for',
            deleted: false,
            rawJson: jsonEncode(_wireMessage(token, 300, 200)),
          ),
        );
    await (database.update(database.chatScopes)..where(
          (row) =>
              row.accountId.equals(account.id) &
              row.roomToken.equals(token) &
              row.scopeKey.equals('root'),
        ))
        .write(ChatScopesCompanion(blocksJson: const Value('[["100","300"]]')));
    for (var pump = 0; pump < 8; pump++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(anchor, findsOneWidget);
    final shift = (tester.getTopLeft(anchor).dy - before.dy).abs();
    debugPrint(
      'chat-render: an incoming message moved the anchored bubble by '
      '${shift.toStringAsFixed(1)}px; scroll offset stayed at '
      '${scrollable.position.pixels.toStringAsFixed(1)} while maxScrollExtent '
      'went ${extentBefore.toStringAsFixed(1)} -> '
      '${scrollable.position.maxScrollExtent.toStringAsFixed(1)}',
    );
    await closeRoom(tester);

    // The defect: a reversed [ListView] lays its newest item out at scroll
    // offset zero, so a message arriving while the reader is up in the history
    // pushes everything they are reading along the axis by that bubble's
    // height. The offset itself does not move, which is why nothing corrects
    // it. Correcting it from here is not possible either: maxScrollExtent is
    // an estimate over the unbuilt children and grows by far more than the one
    // bubble that was actually inserted, so it cannot serve as the correction.
    // The fix is structural - a CustomScrollView whose `center` key separates
    // the history sliver from the arriving-messages sliver, so neither end
    // re-indexes the other. It also has to move `_scrollTowards` and
    // `_handleScroll` in chat_room_pane_sync.dart off maxScrollExtent.
    // When that lands, this expectation becomes `lessThan(1)`.
    expect(shift, greaterThan(1));
    expect(scrollable.position.pixels, pixelsBefore);
  });
}

/// A phone-sized chat viewport holds roughly this many bubbles.
const _visibleBubbles = 12;

Map<String, Object?> _wireMessage(String token, int messageId, int index) {
  // A third of real Talk traffic carries markdown, which is the expensive
  // branch of the renderer, so the fixture keeps that ratio.
  final markdown = index % 3 == 0;
  final body = markdown
      ? 'Synthetic **history** message number $index with a '
            '[link](https://cloud.example.invalid/call/$token) and `code`.'
      : 'Synthetic history message number $index with plain body text.';
  return <String, Object?>{
    'id': messageId,
    'token': token,
    'actorType': 'users',
    'actorId': 'author-${index % 4}',
    'actorDisplayName': 'Author ${index % 4}',
    'timestamp': 1724300000 + (index * 60),
    'systemMessage': '',
    'messageType': 'comment',
    'isReplyable': true,
    'referenceId': 'reference-$token-$messageId',
    'message': body,
    'messageParameters': const <String, Object?>{},
    'markdown': markdown,
    'reactions': const <String, Object?>{},
    'reactionsSelf': const <Object?>[],
    'deleted': null,
    'threadId': null,
    'isThread': false,
    'threadTitle': null,
    'threadReplies': 0,
  };
}

void _decodeAndRender(List<String> rows, ServerBase server) {
  for (final row in rows) {
    final message = ChatMessage.fromJson(jsonDecode(row));
    renderRichChatMessage(
      message: message.message,
      markdownEnabled: message.markdown == true,
      parameters: message.messageParameters,
      server: server,
    );
  }
}

double _medianMicroseconds({
  required int rounds,
  required void Function() body,
}) {
  final samples = <int>[];
  for (var round = 0; round < rounds; round++) {
    final watch = Stopwatch()..start();
    body();
    watch.stop();
    samples.add(watch.elapsedMicroseconds);
  }
  samples.sort();
  return samples[samples.length ~/ 2].toDouble();
}
