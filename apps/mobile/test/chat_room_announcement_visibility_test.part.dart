part of 'chat_room_live_sync_test.dart';

void _registerAnnouncementVisibilityTests() {
  for (final covered in [false, true]) {
    testWidgets(
      covered
          ? 'a dialog suppresses an already queued incoming announcement'
          : 'an uncovered chat delivers its queued incoming announcement',
      (tester) async {
        final announcements = <String>[];
        late List<String> beforeFlush;
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(accessibleNavigation: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await _verifyLiveBridge(
          tester,
          threadId: null,
          announcementDebounce: const Duration(seconds: 5),
          incomingMessageAnnounce: (message, _) async {
            announcements.add(message);
          },
          beforeCleanup: () async {
            beforeFlush = List.of(announcements);
            if (covered) {
              unawaited(
                showDialog<void>(
                  context: tester.element(find.byType(ChatRoomPane)),
                  builder: (_) =>
                      const AlertDialog(content: Text('Covering dialog')),
                ),
              );
              await tester.pump();
            }
            await tester.pump(const Duration(seconds: 5));
          },
        );
        expect(beforeFlush, isEmpty);
        expect(
          announcements,
          covered
              ? isEmpty
              : ['New activity. User A: External root live message'],
        );
      },
    );
  }
}
