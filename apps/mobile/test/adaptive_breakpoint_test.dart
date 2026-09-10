import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_shell.dart';
import 'package:nextcloudtalk/features/conversations/list_pane_preference.dart'
    show kMinListPaneWidth;
import 'package:nextcloudtalk/features/rooms/room_details_screen.dart';

import 'accessibility_probe.dart' show overflowsWhile;
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

const _secondConversation = CachedConversation(
  accountId: 'breakpoint-account',
  token: 'secondbreakpoint',
  displayName: 'Second breakpoint room',
  description: 'Second conversation',
  lastActivity: 1724300100,
  unreadMessages: 0,
  favorite: false,
  isArchived: false,
  readOnly: 0,
  roomType: 2,
  roomName: 'second-breakpoint-room',
  objectType: '',
  avatarVersion: '',
  isCustomAvatar: false,
  lastMessageText: 'Second preview',
  lastMessageTimestamp: 1724300100,
  rawJson: '{}',
);

/// Stands in for the shell: it owns the selected token, which is the single
/// record of what is open in both layouts.
final class _Harness extends StatefulWidget {
  const _Harness({
    this.initialToken,
    this.conversations = const [_conversation],
    this.listWidth,
  });

  final String? initialToken;
  final List<CachedConversation> conversations;

  /// The width a splitter drag would have stored, so a list wider than the
  /// window can pay for can be pumped the way it comes back from disk.
  final double? listWidth;

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

  void selectWhileDetailsStayOpen(String token) {
    setState(() => _token = token);
  }

  @override
  Widget build(BuildContext context) {
    return ConversationWorkspace(
      account: _account,
      accounts: const [_account],
      conversations: widget.conversations,
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
      listWidth: widget.listWidth,
      onResizeList: widget.listWidth == null ? null : (_) {},
      onResizeListEnd: widget.listWidth == null ? null : () {},
    );
  }
}

void main() {
  late AppDatabase database;

  setUp(() => database = openTestDatabase());
  tearDown(() => database.close());

  Future<void> pump(
    WidgetTester tester, {
    String? token,
    List<CachedConversation> conversations = const [_conversation],
    TargetPlatform? platform,
    double? listWidth,
  }) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
        child: localizedTestApp(
          home: _Harness(
            initialToken: token,
            conversations: conversations,
            listWidth: listWidth,
          ),
          theme: platform == null
              ? null
              : AppTheme.light().copyWith(platform: platform),
        ),
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
  final compactNavigator = find.descendant(
    of: find.byKey(const Key('conversation-shell-compact-navigator')),
    matching: find.byType(Navigator),
  );
  final expanded = find.byKey(const Key('conversation-shell-expanded'));
  final detailPane = find.byKey(const Key('conversation-detail-pane'));

  testWidgets('iOS edge pop reveals the live conversation-list route', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    await pump(
      tester,
      token: _conversation.token,
      platform: TargetPlatform.iOS,
    );

    expect(compactConversation, findsOneWidget);
    expect(compactList, findsNothing);
    final navigator = tester.widget<Navigator>(compactNavigator);
    expect(navigator.pages, hasLength(2));
    expect(
      (navigator.pages.first as MaterialPage<void>).allowSnapshotting,
      isFalse,
    );
    expect(
      (navigator.pages.last as MaterialPage<void>).allowSnapshotting,
      isFalse,
    );

    final gesture = await tester.startGesture(const Offset(1, 450));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();

    expect(compactList, findsOneWidget);
    expect(find.text(_conversation.lastMessageText!), findsOneWidget);
    expect(
      find.byKey(const Key('conversation-edge-swipe-preview')),
      findsNothing,
    );

    await gesture.moveBy(const Offset(240, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(compactConversation, findsNothing);
    expect(compactList, findsOneWidget);

    await settle(tester);
  });

  testWidgets('iOS system back pops a child route before the room', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    await pump(
      tester,
      token: _conversation.token,
      platform: TargetPlatform.iOS,
    );

    final nestedNavigator = tester.state<NavigatorState>(compactNavigator);
    expect(
      Navigator.of(tester.element(compactConversation)),
      same(nestedNavigator),
    );
    nestedNavigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Conversation child route')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Conversation child route'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Conversation child route'), findsNothing);
    expect(compactConversation, findsOneWidget);
    expect(compactList, findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(compactConversation, findsNothing);
    expect(compactList, findsOneWidget);
    expect(tester.takeException(), isNull);
    await settle(tester);
  });

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
    expect(
      find.byKey(const Key('conversation-edge-swipe-preview')),
      findsNothing,
    );

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

  testWidgets('a window too narrow for both panes still shows the list', (
    tester,
  ) async {
    // FOUND ON A 7-INCH TABLET IN PORTRAIT, 6 September 2026, AND REPORTED
    // AGAIN THE SAME NIGHT ON A DESKTOP WINDOW: 901 dp is over the two-pane
    // breakpoint and 49 dp short of the room a conversation was said to need,
    // so the list folded itself. With nothing open that left the "select a
    // conversation" placeholder over the whole window; with a conversation
    // open it left no way back to the list, because the toggle in the
    // conversation pane only flips the STORED preference and the fold
    // overruled it again — pressing it twice changed nothing on screen.
    // The fold is gone. Only the person's own toggle hides the list now.
    tester.view.physicalSize = const Size(901, 1440);
    await pump(
      tester,
      conversations: const [_conversation, _secondConversation],
    );

    expect(
      find.byKey(const Key('conversation-shell-expanded')),
      findsOneWidget,
      reason: '901 dp is past the two-pane breakpoint',
    );
    expect(find.byKey(const Key('conversation-list-pane')), findsOneWidget);

    // Opening a conversation leaves the list where it is, so the next one can
    // be picked without touching anything else.
    await tester.tap(find.text('Breakpoint room'));
    await tester.pump();
    expect(
      find.byKey(const Key('conversation-list-pane')),
      findsOneWidget,
      reason: 'this is the dead end that was reported: no list, no way back',
    );
    // And the list is live, not a leftover: the next conversation opens from
    // it, which is what could not be done.
    await tester.tap(find.text('Second breakpoint room'));
    await tester.pump();
    expect(find.text('Second conversation'), findsWidgets);

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

  testWidgets('the composer survives a sync error at 200 % text', (
    tester,
  ) async {
    // The error banner is the one part of the pane that grows without asking.
    // At 200 % text on a 360 px phone it wrapped to 467 px, took every pixel
    // the timeline had and pushed the composer off the bottom: the person
    // could neither read the room nor answer it.
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final overflows = await overflowsWhile(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appDatabaseProvider.overrideWithValue(database)],
          child: localizedTestApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: const _Harness(initialToken: 'breakpointtoken'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    });

    expect(overflows, isEmpty, reason: overflows.join(' | '));
    expect(
      find.byIcon(Icons.cloud_off_rounded),
      findsOneWidget,
      reason: 'without the banner this proves nothing',
    );
    expect(find.byKey(const Key('chat-composer')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('chat-composer'))).bottom,
      lessThanOrEqualTo(740),
    );

    await settle(tester);
  });

  testWidgets('a conversation row fits the narrowest list at 200 % text', (
    tester,
  ) async {
    // The list may be dragged to 240, and at 200 % text the date beside the
    // name is wider than what is left: the row overflowed by 65 px. Nothing
    // on a phone finds this — a phone is one pane wide.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final overflows = await overflowsWhile(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appDatabaseProvider.overrideWithValue(database)],
          child: localizedTestApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: const _Harness(listWidth: kMinListPaneWidth),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    });

    expect(overflows, isEmpty, reason: overflows.join(' | '));
    expect(find.text('Breakpoint room'), findsWidgets);

    await settle(tester);
  });

  testWidgets('a window too narrow for three panes opens details as a page', (
    tester,
  ) async {
    // The reported shape: a tablet in landscape, or a desktop window dragged
    // half way. The panel used to open anyway and leave the conversation
    // 128 px wide, which overflowed its own header — the whole point of the
    // details is to sit BESIDE something that is still readable.
    tester.view.physicalSize = const Size(800, 900);
    await pump(tester, token: _conversation.token);
    final before = tester
        .getSize(find.byKey(const Key('conversation-detail-pane')))
        .width;

    await tester.tap(find.byKey(const Key('open-room-details')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const Key('room-details-panel')), findsNothing);
    expect(
      find.byKey(const Key('room-details-screen')),
      findsOneWidget,
      reason: 'the button has to do something: a page when a panel cannot fit',
    );
    expect(
      tester.getSize(find.byKey(const Key('conversation-detail-pane'))).width,
      before,
      reason: 'the conversation keeps its width instead of paying for a panel',
    );
    expect(tester.takeException(), isNull);

    await settle(tester);
  });

  testWidgets('a list wider than the window can pay for gives the width back', (
    tester,
  ) async {
    // A width dragged on a big monitor comes back on a small one, and used to
    // be obeyed to the pixel: at 720 a stored 520 left 191 px of conversation
    // and its header overflowed by 11.
    tester.view.physicalSize = const Size(720, 900);
    await pump(tester, token: _conversation.token, listWidth: 520);

    final list = tester
        .getSize(find.byKey(const Key('conversation-list-pane')))
        .width;
    final chat = tester
        .getSize(find.byKey(const Key('conversation-detail-pane')))
        .width;
    expect(list, lessThan(520));
    expect(list, greaterThanOrEqualTo(kMinListPaneWidth));
    expect(chat, greaterThan(360), reason: 'wider than the narrowest phone');
    expect(tester.takeException(), isNull);

    await settle(tester);
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

  testWidgets('the details panel replaces state when its room changes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    await pump(
      tester,
      token: _conversation.token,
      conversations: const [_conversation, _secondConversation],
    );
    await tester.tap(find.byKey(const Key('open-room-details')));
    await tester.pump();

    final firstState = tester.state(find.byType(RoomDetailsScreen));
    tester
        .state<_HarnessState>(find.byType(_Harness))
        .selectWhileDetailsStayOpen(_secondConversation.token);
    await tester.pump();

    expect(find.byKey(const Key('room-details-panel')), findsOneWidget);
    expect(
      tester.state(find.byType(RoomDetailsScreen)),
      isNot(same(firstState)),
    );
    expect(find.text(_secondConversation.displayName), findsWidgets);

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

  testWidgets('Android system back still clears the compact selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 800);
    await pump(
      tester,
      token: _conversation.token,
      platform: TargetPlatform.android,
    );
    expect(compactConversation, findsOneWidget);
    expect(
      find.byKey(const Key('conversation-shell-compact-navigator')),
      findsNothing,
    );

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
