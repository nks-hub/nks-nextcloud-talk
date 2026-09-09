import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/calls/call_banner.dart';
import 'package:nextcloudtalk/features/calls/call_join_controller.dart';
import 'package:nextcloudtalk/features/calls/call_lifecycle_service.dart';
import 'package:nextcloudtalk/features/calls/call_lifecycle_controller.dart';
import 'package:nextcloudtalk/features/calls/call_picture_in_picture.dart';
import 'package:nextcloudtalk/features/calls/call_participants_sheet.dart';
import 'package:nextcloudtalk/features/calls/call_start_button.dart';
import 'package:nextcloudtalk/features/calls/call_transport_service.dart';

import 'test_support.dart';

typedef _View = ({StoredAccount account, String room});

void main() {
  late AppDatabase database;
  late StoredAccount account;
  late ValueNotifier<_View> view;
  late Map<CallRoomKey, _StartController> controllers;
  late Completer<bool> admission;

  setUp(() async {
    database = openTestDatabase();
    account = await AccountRepository(database).upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    view = ValueNotifier((account: account, room: 'rooma123'));
    controllers = {};
  });

  tearDown(() async {
    view.dispose();
    await database.close();
  });

  Future<void> mount(
    WidgetTester tester, {
    String language = 'en',
    bool hasCall = false,
    CallLifecycleError refusal =
        CallLifecycleError.endToEndEncryptionUnsupported,
  }) async {
    admission = Completer<bool>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          callTransportProvider.overrideWith(
            (ref, key) async => CallTransport.externalHpb,
          ),
          callLifecycleStatusProvider.overrideWith(
            (ref, key) async => CallLifecycleRoomStatus(
              key: key,
              status: CallLifecycleStatus(
                ownSessionPresent: false,
                peers: const [],
                state: null,
              ),
            ),
          ),
          callParticipantNamesProvider.overrideWith(
            (ref, key) async => const {},
          ),
          callPictureInPictureProvider.overrideWithValue(
            const UnavailableCallPictureInPicture(),
          ),
          callLifecyclePersistedProvider.overrideWith(
            (ref, key) async => false,
          ),
          callJoinControllerProvider.overrideWith(
            () => _StartController(controllers, admission.future, refusal),
          ),
        ],
        child: localizedTestApp(
          locale: Locale(language),
          home: Scaffold(
            body: ValueListenableBuilder<_View>(
              valueListenable: view,
              builder: (_, value, _) => _Header(view: value, hasCall: hasCall),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'outgoing admission is visible before the server reports a call',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const Key('start-call-audio')));
      await tester.pump();
      expect(find.byKey(const Key('call-banner')), findsOneWidget);
      expect(find.text('Joining the call…'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('start-call-audio')))
            .onPressed,
        isNull,
      );
      admission.complete(false);
      await tester.pumpAndSettle();
    },
  );

  testWidgets('outgoing join failure stays visible without server call state', (
    tester,
  ) async {
    await mount(tester, refusal: CallLifecycleError.network);
    await tester.tap(find.byKey(const Key('start-call-audio')));
    admission.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('Joining the call failed.'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('start-call-audio')))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  for (final language in ['en', 'cs']) {
    testWidgets(
      'an outgoing E2EE refusal is visible without hasCall ($language)',
      (tester) async {
        await mount(tester, language: language);
        await tester.tap(find.byKey(const Key('start-call-video')));
        expect(controllers.values.single.joinCalls, 1);
        admission.complete(false);
        await tester.pumpAndSettle();

        expect(
          find.text(
            language == 'cs'
                ? 'Tato aplikace zatím nepodporuje hovory s koncovým šifrováním.'
                : 'This app does not support end-to-end encrypted calls yet.',
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('call-banner-join')), findsNothing);
        expect(
          find.byKey(const Key('call-banner-lifecycle-retry')),
          findsNothing,
        );
        expect(controllers.values.single.cameraStarts, 0);
      },
    );
  }

  testWidgets('repeated header taps issue only one admission attempt', (
    tester,
  ) async {
    await mount(tester);
    final callback = tester
        .widget<IconButton>(find.byKey(const Key('start-call-audio')))
        .onPressed!;
    callback();
    callback();
    admission.complete(false);
    await tester.pumpAndSettle();
    expect(controllers.values.single.joinCalls, 1);
    expect(
      find.text('This app does not support end-to-end encrypted calls yet.'),
      findsOneWidget,
    );
  });

  for (final switchAccount in [false, true]) {
    for (final withVideo in [false, true]) {
      testWidgets(
        'a late admission stays in its scope (account: $switchAccount, video: $withVideo)',
        (tester) async {
          await mount(tester);
          final container = ProviderScope.containerOf(
            tester.element(find.byType(_Header)),
          );
          final oldKey = (accountId: account.id, roomToken: 'rooma123');
          final keepOldCall = container.listen(
            callJoinControllerProvider(oldKey),
            (_, _) {},
          );
          addTearDown(keepOldCall.close);
          await tester.tap(
            find.byKey(
              Key(withVideo ? 'start-call-video' : 'start-call-audio'),
            ),
          );
          final nextAccount = switchAccount
              ? await AccountRepository(database).upsertAccount(
                  accountId: 'account-b',
                  serverUrl: 'https://other.example.invalid',
                  loginName: 'fixture-user',
                  serverProductName: 'Nextcloud',
                  talkFeatures: const {},
                  createdAt: DateTime.utc(2026, 1, 1),
                )
              : account;
          view.value = (
            account: nextAccount,
            room: switchAccount ? 'rooma123' : 'roomb123',
          );
          await tester.pumpAndSettle();
          admission.complete(withVideo);
          await tester.pumpAndSettle();
          expect(
            container.read(callJoinControllerProvider(oldKey)).phase,
            withVideo ? CallJoinPhase.joined : CallJoinPhase.failed,
          );
          expect(controllers[oldKey]!.cameraStarts, 0);
          expect(
            find.text(
              'This app does not support end-to-end encrypted calls yet.',
            ),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('removing the header during admission cannot start its camera', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('start-call-video')));
    expect(controllers.values.single.joinCalls, 1);
    final controller = controllers.values.single;
    await tester.pumpWidget(const SizedBox.shrink());
    admission.complete(false);
    await tester.pumpAndSettle();
    expect(controller.cameraStarts, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an admitted outgoing video call still starts its camera', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('start-call-video')));
    admission.complete(true);
    await tester.pumpAndSettle();
    expect(controllers.values.single.cameraStarts, 1);
    expect(find.byKey(const Key('call-screen')), findsOneWidget);
    expect(
      find.byKey(const Key('call-banner-encryption-unsupported')),
      findsNothing,
    );
  });

  testWidgets('an admitted audio call opens the participant grid', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('start-call-audio')));
    admission.complete(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-screen')), findsOneWidget);
    expect(find.byKey(const PageStorageKey('call-grid')), findsOneWidget);
    expect(controllers.values.single.cameraStarts, 0);
  });

  testWidgets('accepting the banner call opens the participant grid', (
    tester,
  ) async {
    await mount(tester, hasCall: true);
    await tester.tap(find.byKey(const Key('call-banner-join')));
    admission.complete(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-screen')), findsOneWidget);
    expect(controllers.values.single.joinCalls, 1);
  });

  testWidgets('late admission does not cover a newer route or start video', (
    tester,
  ) async {
    await mount(tester);
    final context = tester.element(find.byType(_Header));
    await tester.tap(find.byKey(const Key('start-call-video')));
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Newer route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    admission.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Newer route'), findsOneWidget);
    expect(find.byKey(const Key('call-screen')), findsNothing);
    expect(controllers.values.first.cameraStarts, 0);
  });

  testWidgets('a camera completing under a newer route cannot open the grid', (
    tester,
  ) async {
    await mount(tester);
    final context = tester.element(find.byType(_Header));
    final controller = controllers.values.single;
    controller.cameraStartup = Completer<void>();
    await tester.tap(find.byKey(const Key('start-call-video')));
    admission.complete(true);
    await tester.pump();
    expect(controller.cameraStarts, 1);
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Newer route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.cameraStartup!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Newer route'), findsOneWidget);
    expect(find.byKey(const Key('call-screen')), findsNothing);
  });
}

final class _Header extends ConsumerWidget {
  const _Header({required this.view, this.hasCall = false});

  final _View view;
  final bool hasCall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversation = CachedConversation(
      accountId: view.account.id,
      token: view.room,
      displayName: 'Room',
      description: '',
      lastActivity: 0,
      unreadMessages: 0,
      favorite: false,
      isArchived: false,
      readOnly: 0,
      roomType: 2,
      roomName: 'Room',
      objectType: '',
      avatarVersion: '',
      isCustomAvatar: false,
      rawJson: jsonEncode({
        'hasCall': hasCall,
        'canStartCall': true,
        'readOnly': 0,
        'lobbyState': 0,
        'permissions': 0,
        'participantType': 3,
      }),
    );
    final actions = callStartActions(
      context,
      ref,
      accountId: view.account.id,
      conversation: conversation,
      isCurrent: () {
        final current = ref.context.widget as _Header;
        return current.view.account.id == view.account.id &&
            current.view.room == view.room;
      },
    );
    return Column(
      children: [
        Row(
          children: [
            for (final action in actions)
              IconButton(
                key: action.id,
                onPressed: action.onPressed,
                icon: Icon(action.icon),
              ),
          ],
        ),
        OngoingCallBanner(account: view.account, conversation: conversation),
      ],
    );
  }
}

final class _StartController extends CallJoinController {
  _StartController(this.controllers, this.admission, this.refusal);

  final Map<CallRoomKey, _StartController> controllers;
  final Future<bool> admission;
  final CallLifecycleError refusal;
  int joinCalls = 0;
  int cameraStarts = 0;
  Completer<void>? cameraStartup;
  bool disposed = false;

  @override
  CallJoinState build(CallRoomKey arg) {
    controllers[arg] = this;
    ref.onDispose(() => disposed = true);
    return const CallJoinState();
  }

  @override
  Future<void> join() async {
    joinCalls++;
    if (state.isBusy || state.phase == CallJoinPhase.joined) return;
    state = const CallJoinState(phase: CallJoinPhase.joining);
    final allowed = await admission;
    if (disposed) return;
    state = allowed
        ? const CallJoinState(phase: CallJoinPhase.joined)
        : CallJoinState(phase: CallJoinPhase.failed, lifecycleError: refusal);
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    if (enabled) cameraStarts++;
    await cameraStartup?.future;
  }
}
