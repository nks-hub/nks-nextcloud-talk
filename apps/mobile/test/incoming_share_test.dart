import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/share/incoming_share_bridge.dart';
import 'package:nextcloudtalk/features/share/incoming_share_coordinator.dart';
import 'package:nextcloudtalk/features/share/incoming_share_host.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(IncomingShareBridge.channelName);

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('host asks the native inbox for an iOS launch share', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    var launchCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getLaunchShare') {
            launchCalls++;
            return null;
          }
          return true;
        });

    await tester.pumpWidget(
      ProviderScope(
        child: _localizedApp(const IncomingShareHost(child: SizedBox.shrink())),
      ),
    );
    await tester.pumpAndSettle();

    expect(launchCalls, 1);
    // Reset in the body: the invariant that catches a leaked debug variable
    // runs before tearDowns do.
    debugDefaultTargetPlatformOverride = null;
  });

  test('bridge parses cold text and completes its exact native id', () async {
    MethodCall? completed;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getLaunchShare') {
            return <String, Object?>{'id': 'share-1', 'text': 'hello'};
          }
          completed = call;
          return true;
        });
    final bridge = IncomingShareBridge(channel: channel);
    addTearDown(bridge.dispose);

    final share = await bridge.getLaunchShare();
    await bridge.complete(share!.id);

    expect(share.text, 'hello');
    expect(share.file, isNull);
    expect(completed?.method, 'completeShare');
    expect(completed?.arguments, <String, Object?>{'id': 'share-1'});
  });

  test('file metadata rejects an overlong attachment caption', () {
    expect(
      () => parseIncomingShare(<String, Object?>{
        'id': 'share-2',
        'text': 'x' * 4001,
        'filePath': '/owned/file',
        'mimeType': 'image/jpeg',
        'displayName': 'photo.jpg',
        'byteLength': 2,
        'sha256': 'a' * 64,
      }),
      throwsFormatException,
    );
  });

  test('coordinator delivers cold and warm shares once per id', () async {
    final platform = _FakeIncomingSharePlatform(
      launch: const IncomingShare(id: 'cold', text: 'cold', file: null),
    );
    final coordinator = IncomingShareCoordinator(platform);
    addTearDown(coordinator.close);

    await coordinator.start();
    platform.open(const IncomingShare(id: 'warm', text: 'warm', file: null));
    platform.open(const IncomingShare(id: 'warm', text: 'warm', file: null));
    await Future<void>.delayed(Duration.zero);

    expect(coordinator.takeNext()?.id, 'cold');
    expect(coordinator.takeNext()?.id, 'warm');
    expect(coordinator.takeNext(), isNull);
  });

  test('completing one native share pulls the next durable item', () async {
    final platform = _QueuedIncomingSharePlatform([
      const IncomingShare(id: 'first', text: 'first', file: null),
      const IncomingShare(id: 'second', text: 'second', file: null),
    ]);
    final coordinator = IncomingShareCoordinator(platform);
    addTearDown(coordinator.close);

    await coordinator.start();
    final first = coordinator.takeNext()!;
    await coordinator.complete(first);

    expect(platform.completed, ['first']);
    expect(coordinator.takeNext()?.id, 'second');
    expect(coordinator.takeNext(), isNull);
  });

  testWidgets('the picker lists every conversation and sends to the one tapped', (
    tester,
  ) async {
    IncomingShareTarget? sent;
    await tester.pumpWidget(
      _localizedApp(
        IncomingShareTargetDialog(
          share: const IncomingShare(id: 'share-3', text: 'hello', file: null),
          loadAccounts: () async => const [
            IncomingShareAccount(
              id: 'account-a',
              label: 'alice · cloud.example',
              rooms: [IncomingShareRoom(token: 'room-a', label: 'Project')],
            ),
            IncomingShareAccount(
              id: 'account-b',
              label: 'bob · other.example',
              rooms: [IncomingShareRoom(token: 'room-b', label: 'Team')],
            ),
          ],
          send: (target) async => sent = target,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Every conversation of every account is on screen at once, under its
    // account's heading - no picker has to be opened first.
    expect(find.text('alice · cloud.example'), findsOneWidget);
    expect(find.text('bob · other.example'), findsOneWidget);
    expect(find.text('Project'), findsOneWidget);
    expect(find.text('Team'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('incoming-share-send')))
          .onPressed,
      isNull,
    );

    await tester.tap(
      find.byKey(const Key('incoming-share-room-account-b-room-b')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('incoming-share-send')));
    await tester.pumpAndSettle();

    expect(sent?.accountId, 'account-b');
    expect(sent?.roomToken, 'room-b');
  });

  testWidgets('the picker searches once there are enough conversations', (
    tester,
  ) async {
    IncomingShareTarget? sent;
    await tester.pumpWidget(
      _localizedApp(
        IncomingShareTargetDialog(
          share: const IncomingShare(id: 'share-5', text: 'hello', file: null),
          loadAccounts: () async => [
            IncomingShareAccount(
              id: 'account-a',
              label: 'alice',
              rooms: [
                for (var index = 0; index < 9; index++)
                  IncomingShareRoom(
                    token: 'room-$index',
                    label: index == 7 ? 'Roadmap' : 'Room $index',
                  ),
              ],
            ),
          ],
          send: (target) async => sent = target,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('incoming-share-search')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('incoming-share-search')),
      'road',
    );
    await tester.pumpAndSettle();
    expect(find.text('Roadmap'), findsOneWidget);
    expect(find.text('Room 0'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('incoming-share-search')),
      'nothing matches this',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('incoming-share-no-matches')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('incoming-share-search')),
      'road',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('incoming-share-room-account-a-room-7')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('incoming-share-send')));
    await tester.pumpAndSettle();

    expect(sent?.roomToken, 'room-7');
  });

  testWidgets('a thread under a conversation is a target of its own', (
    tester,
  ) async {
    IncomingShareTarget? sent;
    await tester.pumpWidget(
      _localizedApp(
        IncomingShareTargetDialog(
          share: const IncomingShare(id: 'share-6', text: 'hello', file: null),
          loadAccounts: () async => const [
            IncomingShareAccount(
              id: 'account-a',
              label: 'alice',
              rooms: [
                IncomingShareRoom(
                  token: 'room-a',
                  label: 'Project',
                  threads: [
                    IncomingShareThread(id: 41, title: 'Roadmap'),
                    IncomingShareThread(id: 42, title: 'Hiring'),
                  ],
                ),
              ],
            ),
          ],
          send: (target) async => sent = target,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Roadmap'), findsOneWidget);
    expect(find.text('Hiring'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('incoming-share-thread-account-a-room-a-42')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('incoming-share-send')));
    await tester.pumpAndSettle();

    expect(sent?.roomToken, 'room-a');
    expect(sent?.threadId, 42);
    expect(sent?.threadTitle, 'Hiring');
  });

  testWidgets('picking the conversation after a thread drops the thread', (
    tester,
  ) async {
    IncomingShareTarget? sent;
    await tester.pumpWidget(
      _localizedApp(
        IncomingShareTargetDialog(
          share: const IncomingShare(id: 'share-7', text: 'hello', file: null),
          loadAccounts: () async => const [
            IncomingShareAccount(
              id: 'account-a',
              label: 'alice',
              rooms: [
                IncomingShareRoom(
                  token: 'room-a',
                  label: 'Project',
                  threads: [IncomingShareThread(id: 41, title: 'Roadmap')],
                ),
              ],
            ),
          ],
          send: (target) async => sent = target,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('incoming-share-thread-account-a-room-a-41')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('incoming-share-room-account-a-room-a')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('incoming-share-send')));
    await tester.pumpAndSettle();

    expect(sent?.roomToken, 'room-a');
    expect(
      sent?.threadId,
      isNull,
      reason: 'the conversation itself is not the thread that was picked first',
    );
  });

  testWidgets('a file share says so when no server takes attachments', (
    tester,
  ) async {
    await tester.pumpWidget(
      _localizedApp(
        IncomingShareTargetDialog(
          share: const IncomingShare(
            id: 'share-8',
            text: null,
            file: IncomingSharedFile(
              path: '/tmp/probe.png',
              mimeType: 'image/png',
              displayName: 'probe.png',
              byteLength: 12,
              sha256: 'deadbeef',
            ),
          ),
          // The host drops such accounts before the dialog sees them, so an
          // empty list is exactly what a file share meets on a server with
          // attachments turned off.
          loadAccounts: () async => const <IncomingShareAccount>[],
          send: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('incoming-share-no-targets')), findsOneWidget);
    expect(
      find.text('None of your accounts takes file attachments. Their servers '
          'have them turned off; text can still be shared.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('incoming-share-send')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('a file share offers the account whose server took the file', (
    tester,
  ) async {
    IncomingShareTarget? sent;
    await tester.pumpWidget(
      _localizedApp(
        IncomingShareTargetDialog(
          share: const IncomingShare(
            id: 'share-9',
            text: null,
            file: IncomingSharedFile(
              path: '/tmp/probe.png',
              mimeType: 'image/png',
              displayName: 'probe.png',
              byteLength: 12,
              sha256: 'deadbeef',
            ),
          ),
          // The other half of the pair above: the host keeps the accounts
          // whose profile came back enabled, and the dialog must offer them
          // for a file exactly as it does for text. Which accounts survive is
          // decided upstream, against the capability profile, and is covered
          // in chat_attachment_context_test.dart - rendering the host here
          // would reach live providers and never settle.
          loadAccounts: () async => const [
            IncomingShareAccount(
              id: 'account-a',
              label: 'alice',
              rooms: [IncomingShareRoom(token: 'room-a', label: 'Project')],
            ),
          ],
          send: (target) async => sent = target,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('incoming-share-no-targets')), findsNothing);
    expect(find.text('probe.png'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('incoming-share-room-account-a-room-a')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('incoming-share-send')));
    await tester.pumpAndSettle();

    expect(sent?.roomToken, 'room-a');
  });

  testWidgets('send failure keeps the picker open for retry', (tester) async {
    await tester.pumpWidget(
      _localizedApp(
        IncomingShareTargetDialog(
          share: const IncomingShare(id: 'share-4', text: 'hello', file: null),
          loadAccounts: () async => const [
            IncomingShareAccount(
              id: 'account-a',
              label: 'alice',
              rooms: [IncomingShareRoom(token: 'room-a', label: 'Project')],
            ),
          ],
          send: (_) => Future<void>.error(StateError('offline')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('incoming-share-room-account-a-room-a')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('incoming-share-send')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('incoming-share-target-dialog')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('incoming-share-error')), findsOneWidget);
  });
}

Widget _localizedApp(Widget home) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: home),
);

final class _FakeIncomingSharePlatform implements IncomingSharePlatform {
  _FakeIncomingSharePlatform({this.launch});

  final IncomingShare? launch;
  final StreamController<IncomingShare> _opened =
      StreamController<IncomingShare>.broadcast();

  void open(IncomingShare share) => _opened.add(share);

  @override
  Stream<IncomingShare> get shareOpened => _opened.stream;

  @override
  Future<IncomingShare?> getLaunchShare() async => launch;

  @override
  Future<void> complete(String id) async {}

  @override
  Future<void> dispose() => _opened.close();
}

final class _QueuedIncomingSharePlatform implements IncomingSharePlatform {
  _QueuedIncomingSharePlatform(this.launches);

  final List<IncomingShare> launches;
  final List<String> completed = [];
  final StreamController<IncomingShare> _opened =
      StreamController<IncomingShare>.broadcast();

  @override
  Stream<IncomingShare> get shareOpened => _opened.stream;

  @override
  Future<IncomingShare?> getLaunchShare() async {
    return launches.isEmpty ? null : launches.removeAt(0);
  }

  @override
  Future<void> complete(String id) async => completed.add(id);

  @override
  Future<void> dispose() => _opened.close();
}
