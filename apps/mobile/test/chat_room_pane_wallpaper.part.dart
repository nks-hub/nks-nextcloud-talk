part of 'chat_room_pane_test.dart';

void _registerChatRoomPaneWallpaperTests() {
  const timestamp = 1724300000;

  Future<void> insertSystemMessage() async {
    final wire = _messageJson(
      id: 70,
      actorId: 'someone-else',
      actorDisplayName: 'Other person',
      timestamp: timestamp,
      message: 'Other person joined the call',
    );
    wire['systemMessage'] = 'call_joined';
    await _insertCachedMessage(
      database,
      wire,
      displayText: 'Other person joined the call',
    );
  }

  Widget pane({required bool wallpaper, ThemeData? theme}) => app(
    home: Theme(
      data: theme ?? AppTheme.light(),
      child: Scaffold(
        body: ChatWallpaperScope(
          active: wallpaper,
          child: ChatRoomPane(account: account, conversation: conversation),
        ),
      ),
    ),
  );

  /// The chip colour as it really is behind [finder]: nothing without a
  /// wallpaper, otherwise the chip's fill.
  Color? chipFill(WidgetTester tester, Finder finder) =>
      ChatBackgroundChip.colorOf(tester.element(finder));

  void expectReadsOnChip(
    WidgetTester tester,
    ColorScheme scheme,
    Color fill,
    Color text,
    String what,
  ) {
    for (final wallpaper in const [Color(0xFF000000), Color(0xFFFFFFFF)]) {
      expect(
        chatBackgroundContrast(Color.alphaBlend(fill, wallpaper), text),
        greaterThanOrEqualTo(4.5),
        reason: '$what over $wallpaper',
      );
    }
  }

  testWidgets('without a wallpaper the day separator and the system message '
      'stay as they were', (tester) async {
    await insertSystemMessage();
    await tester.pumpWidget(pane(wallpaper: false));
    await tester.pump();
    await tester.pump();

    final day = find.byKey(_dayKey(timestamp));
    expect(day, findsOneWidget);
    expect(chipFill(tester, day), isNull);
    expect(
      find.descendant(
        of: day,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).borderRadius != null,
        ),
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  for (final entry in {
    'light': AppTheme.light(),
    'dark': AppTheme.dark(),
  }.entries) {
    testWidgets('over a wallpaper the day separator, the system message and '
        'the header text sit on readable chips (${entry.key})', (tester) async {
      await insertSystemMessage();
      final scheme = entry.value.colorScheme;
      await tester.pumpWidget(pane(wallpaper: true, theme: entry.value));
      await tester.pump();
      await tester.pump();

      final fill = scheme.surface.withValues(alpha: wallpaperChipAlpha(scheme));
      expect(wallpaperChipAlpha(scheme), greaterThanOrEqualTo(0.8));

      final day = find.byKey(_dayKey(timestamp));
      final dayChip = find.descendant(
        of: day,
        matching: find.byType(ChatBackgroundChip),
      );
      expect(dayChip, findsOneWidget);
      expect(chipFill(tester, dayChip), fill);
      final dayText = tester.widget<Text>(
        find.descendant(of: dayChip, matching: find.byType(Text)),
      );
      expectReadsOnChip(
        tester,
        scheme,
        fill,
        dayText.style!.color!,
        'day separator',
      );

      final systemText = find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            (widget.textSpan?.toPlainText() ?? '').startsWith(
              'Other person joined the call',
            ),
      );
      final systemChip = find.ancestor(
        of: systemText,
        matching: find.byType(ChatBackgroundChip),
      );
      expect(systemChip, findsOneWidget);
      expectReadsOnChip(
        tester,
        scheme,
        fill,
        tester.widget<Text>(systemText).style!.color!,
        'system message',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  }

  testWidgets('bubbles keep their own background over a wallpaper', (
    tester,
  ) async {
    await tester.pumpWidget(pane(wallpaper: true));
    await tester.pump();
    await tester.pump();
    final bubble = find.text('Cached hello');
    expect(bubble, findsOneWidget);
    expect(
      find.ancestor(of: bubble, matching: find.byType(ChatBackgroundChip)),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
