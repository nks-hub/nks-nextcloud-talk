import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';

import 'test_support.dart';

const _account = StoredAccount(
  id: 'breakpoint-account',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'breakpoint-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '["avatar"]',
  selected: true,
  createdAtMillis: 1767225600000,
);

const _conversation = CachedConversation(
  accountId: 'breakpoint-account',
  token: 'breakpointtoken',
  displayName: 'Breakpoint room',
  description: 'Breakpoint conversation',
  lastActivity: 1724300000,
  unreadMessages: 0,
  favorite: false,
  isArchived: false,
  readOnly: 0,
  roomType: 2,
  roomName: 'breakpoint-room',
  objectType: '',
  avatarVersion: '',
  isCustomAvatar: false,
  lastMessageText: 'Breakpoint preview',
  lastMessageTimestamp: 1724300000,
  rawJson: '{}',
);

/// Stands in for the shell: it owns the selected token, which is the single
/// record of what is open in both layouts.
final class _Harness extends StatefulWidget {
  const _Harness({this.initialToken});

  final String? initialToken;

  @override
  State<_Harness> createState() => _HarnessState();
}

final class _HarnessState extends State<_Harness> {
  String? _token;
  bool _detailsOpen = false;

  @override
  void initState() {
    super.initState();
    _token = widget.initialToken;
  }

  @override
  Widget build(BuildContext context) {
    return ConversationWorkspace(
      account: _account,
      accounts: const [_account],
      conversations: const [_conversation],
      selectedConversationToken: _token,
      loading: false,
      syncing: false,
      onRefresh: () async {},
      onSelectAccount: (_) {},
      onAddAccount: () {},
      onOpenConversation: (c) => setState(() {
        _token = c.token;
        _detailsOpen = false;
      }),
      onSelectConversation: (c) => setState(() {
        _token = c.token;
        _detailsOpen = false;
      }),
      onCloseConversation: () => setState(() {
        _token = null;
        _detailsOpen = false;
      }),
      detailsOpen: _detailsOpen,
      onOpenDetails: () => setState(() => _detailsOpen = true),
      onCloseDetails: () => setState(() => _detailsOpen = false),
    );
  }
}

void main() {
  late AppDatabase database;

  setUp(() => database = openTestDatabase());
  tearDown(() => database.close());

  Future<void> pump(WidgetTester tester, {String? token}) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
        child: localizedTestApp(home: _Harness(initialToken: token)),
      ),
    );
    await tester.pump();
  }

  /// Tears the tree down while pumping is still the test's own.
  ///
  /// `flutter_test` unmounts whatever is left after the body and then pumps
  /// exactly once, which is not enough: every drift stream the teardown closes
  /// schedules a zero-duration cleanup timer, and the pending-timer invariant
  /// runs before those get a turn. A tearDown is too late for the same reason.
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  final compactConversation = find.byKey(
    const Key('conversation-shell-compact-conversation'),
  );
  final compactList = find.byKey(const Key('conversation-shell-compact'));
  final expanded = find.byKey(const Key('conversation-shell-expanded'));
  final detailPane = find.byKey(const Key('conversation-detail-pane'));

  testWidgets('a drag from the left edge puts the conversation list back', (
    tester,
  ) async {
    // The compact shell swaps the list for the conversation inside one
    // Scaffold instead of pushing a route, so the platform's own back-edge
    // gesture had nothing to pop and did nothing at all.
    tester.view.physicalSize = const Size(400, 900);
    await pump(tester, token: _conversation.token);
    expect(compactConversation, findsOneWidget);
    expect(compactList, findsNothing);

    await tester.timedDrag(
      find.byKey(const Key('conversation-edge-swipe-back')),
      const Offset(200, 0),
      const Duration(milliseconds: 200),
    );
    await tester.pumpAndSettle();

    expect(compactList, findsOneWidget);
    expect(compactConversation, findsNothing);

    await settle(tester);
  });

  testWidgets('a short tug from the edge keeps the conversation open', (
    tester,
  ) async {
    // Anything that closes on the first few pixels would fire while somebody
    // is only scrolling the timeline near the edge.
    tester.view.physicalSize = const Size(400, 900);
    await pump(tester, token: _conversation.token);

    await tester.timedDrag(
      find.byKey(const Key('conversation-edge-swipe-back')),
      const Offset(30, 0),
      const Duration(milliseconds: 400),
    );
    // Not pumpAndSettle: the conversation that stays open keeps its live sync
    // loop scheduling frames, so the tree never settles.
    await tester.pump(const Duration(milliseconds: 300));

    expect(compactConversation, findsOneWidget);

    await settle(tester);
  });

  testWidgets('the details panel stays between 300 and 500 wide', (
    tester,
  ) async {
    // `clamp(300px, 27vw, 500px)` is written as a clamp on the WINDOW width
    // before scaling, which is easy to get backwards; these are the three
    // points that tell a correct formula from a plausible one.
    Future<double> panelWidth(double windowWidth) async {
      tester.view.physicalSize = Size(windowWidth, 900);
      await pump(tester, token: _conversation.token);
      await tester.tap(find.byKey(const Key('open-room-details')));
      await tester.pump();
      final width = tester
          .getSize(find.byKey(const Key('room-details-panel')))
          .width;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      return width;
    }

    // Below the lower knee 27vw would be too narrow, so the floor holds.
    expect(await panelWidth(1000), 300);
    // In the band it tracks the window.
    expect(await panelWidth(1400), closeTo(378, 0.5));
    // Above the upper knee the ceiling holds instead of growing forever.
    expect(await panelWidth(2200), 500);
  });

  testWidgets('the details open beside the conversation, not over it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    await pump(tester, token: _conversation.token);
    expect(find.byKey(const Key('room-details-panel')), findsNothing);

    await tester.tap(find.byKey(const Key('open-room-details')));
    await tester.pump();

    // A panel beside the room, not a route over the whole window.
    expect(find.byKey(const Key('room-details-panel')), findsOneWidget);
    expect(find.byKey(const Key('room-details-screen')), findsNothing);
    expect(expanded, findsOneWidget);
    expect(detailPane, findsOneWidget);

    await tester.tap(find.byKey(const Key('close-room-details')));
    await tester.pump();
    expect(find.byKey(const Key('room-details-panel')), findsNothing);

    await settle(tester);
  });

  testWidgets('closing the conversation takes its details with it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    await pump(tester, token: _conversation.token);
    await tester.tap(find.byKey(const Key('open-room-details')));
    await tester.pump();
    expect(find.byKey(const Key('room-details-panel')), findsOneWidget);

    // Details belong to a room; with no room open there is nothing to detail.
    tester.view.physicalSize = const Size(700, 800);
    await tester.pump();
    await tester.tap(find.byKey(const Key('close-conversation')));
    await tester.pump();
    tester.view.physicalSize = const Size(1400, 900);
    await tester.pump();

    expect(find.byKey(const Key('room-details-panel')), findsNothing);

    await settle(tester);
  });

  testWidgets('narrowing keeps the open conversation on screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    await pump(tester, token: _conversation.token);
    expect(expanded, findsOneWidget);

    tester.view.physicalSize = const Size(700, 800);
    await tester.pump();

    expect(compactConversation, findsOneWidget);
    expect(compactList, findsNothing);

    await settle(tester);
  });

  testWidgets('widening puts the conversation back beside the list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 800);
    await pump(tester, token: _conversation.token);
    expect(compactConversation, findsOneWidget);

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pump();

    expect(expanded, findsOneWidget);
    expect(detailPane, findsOneWidget);
    expect(
      find.descendant(of: detailPane, matching: find.text('Breakpoint room')),
      findsWidgets,
    );
    await settle(tester);
  });

  testWidgets('a conversation opened while narrow survives widening', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 800);
    await pump(tester);
    expect(compactList, findsOneWidget);

    await tester.tap(
      find.byKey(Key('conversation-tile-${_conversation.token}')),
    );
    await tester.pump();
    expect(compactConversation, findsOneWidget);

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pump();

    // The old hand-over dropped this case into an empty detail pane.
    expect(expanded, findsOneWidget);
    expect(
      find.descendant(of: detailPane, matching: find.text('Breakpoint room')),
      findsWidgets,
    );
    await settle(tester);
  });

  testWidgets('system back clears the selection instead of leaving the app', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 800);
    await pump(tester, token: _conversation.token);
    expect(compactConversation, findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(compactList, findsOneWidget);
    expect(compactConversation, findsNothing);
    expect(tester.takeException(), isNull);
    await settle(tester);
  });

  testWidgets('the back affordance clears the selection', (tester) async {
    tester.view.physicalSize = const Size(700, 800);
    await pump(tester, token: _conversation.token);

    await tester.tap(find.byKey(const Key('close-conversation')));
    await tester.pump();

    expect(compactList, findsOneWidget);
    expect(tester.takeException(), isNull);
    await settle(tester);
  });
}
