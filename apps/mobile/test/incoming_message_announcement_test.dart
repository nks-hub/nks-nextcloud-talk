import 'dart:ui' show TextDirection;

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/incoming_message_announcement.dart';

void main() {
  testWidgets(
    'batches only remote comments newer than the authoritative baseline',
    (tester) async {
      final spoken = <String>[];
      final controller = IncomingMessageAnnouncementController(
        announce: (message, _) async => spoken.add(message),
      );
      addTearDown(controller.dispose);

      controller.observeAuthoritativeMerge(
        messages: [_row(10, text: 'Cached message')],
        authoritativeMessageId: 10,
        localLoginName: 'local-user',
        activityLabel: 'New activity',
        textDirection: TextDirection.ltr,
        canAnnounce: () => true,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(spoken, isEmpty);

      controller.observeAuthoritativeMerge(
        messages: [
          _row(5, text: 'History page'),
          _row(11, actorId: 'local-user', text: 'Own message'),
          _row(12, systemMessage: 'reaction', text: 'Reaction noise'),
          _row(13, sender: 'Alice', text: 'First incoming message'),
          _row(14, sender: 'Bob', text: 'Second incoming message'),
        ],
        authoritativeMessageId: 14,
        localLoginName: 'local-user',
        activityLabel: 'New activity',
        textDirection: TextDirection.ltr,
        canAnnounce: () => true,
      );
      await tester.pump(const Duration(milliseconds: 349));
      expect(spoken, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));

      expect(spoken, [
        'New activity. Alice: First incoming message. Bob: Second incoming message',
      ]);
    },
  );

  testWidgets('disabled accessibility advances the baseline without speech', (
    tester,
  ) async {
    final spoken = <String>[];
    final controller = IncomingMessageAnnouncementController(
      announce: (message, _) async => spoken.add(message),
      debounce: Duration.zero,
    );
    addTearDown(controller.dispose);

    controller.observeAuthoritativeMerge(
      messages: [_row(20, text: 'Initial')],
      authoritativeMessageId: 20,
      localLoginName: 'local-user',
      activityLabel: 'New activity',
      textDirection: TextDirection.ltr,
      canAnnounce: () => false,
    );
    controller.observeAuthoritativeMerge(
      messages: [_row(21, text: 'While disabled')],
      authoritativeMessageId: 21,
      localLoginName: 'local-user',
      activityLabel: 'New activity',
      textDirection: TextDirection.ltr,
      canAnnounce: () => false,
    );
    controller.observeAuthoritativeMerge(
      messages: [
        _row(21, text: 'While disabled'),
        _row(22, text: 'After enabling'),
      ],
      authoritativeMessageId: 22,
      localLoginName: 'local-user',
      activityLabel: 'New activity',
      textDirection: TextDirection.ltr,
      canAnnounce: () => true,
    );
    await tester.pump(const Duration(milliseconds: 1));

    expect(spoken, ['New activity. Remote user: After enabling']);
  });

  testWidgets('reset treats messages received outside the room as baseline', (
    tester,
  ) async {
    final spoken = <String>[];
    final controller = IncomingMessageAnnouncementController(
      announce: (message, _) async => spoken.add(message),
      debounce: Duration.zero,
    );
    addTearDown(controller.dispose);

    controller.observeAuthoritativeMerge(
      messages: [_row(30, text: 'Initial')],
      authoritativeMessageId: 30,
      localLoginName: 'local-user',
      activityLabel: 'New activity',
      textDirection: TextDirection.ltr,
      canAnnounce: () => true,
    );
    controller.reset();
    controller.observeAuthoritativeMerge(
      messages: [_row(31, text: 'Arrived while away')],
      authoritativeMessageId: 31,
      localLoginName: 'local-user',
      activityLabel: 'New activity',
      textDirection: TextDirection.ltr,
      canAnnounce: () => true,
    );
    await tester.pump();

    expect(spoken, isEmpty);
  });

  testWidgets('announcement work and output stay bounded during a burst', (
    tester,
  ) async {
    final spoken = <String>[];
    final controller = IncomingMessageAnnouncementController(
      announce: (message, _) async => spoken.add(message),
      debounce: Duration.zero,
    );
    addTearDown(controller.dispose);

    controller.observeAuthoritativeMerge(
      messages: const [],
      authoritativeMessageId: 40,
      localLoginName: 'local-user',
      activityLabel: 'New activity',
      textDirection: TextDirection.ltr,
      canAnnounce: () => true,
    );
    controller.observeAuthoritativeMerge(
      messages: [
        for (var id = 41; id <= 80; id++)
          _row(
            id,
            sender: 'Very long sender name ${List.filled(80, 'x').join()}',
            text: 'Long incoming message ${List.filled(200, 'y').join()}',
          ),
      ],
      authoritativeMessageId: 80,
      localLoginName: 'local-user',
      activityLabel: 'New activity',
      textDirection: TextDirection.ltr,
      canAnnounce: () => true,
    );
    await tester.pump(const Duration(milliseconds: 1));

    expect(spoken, hasLength(1));
    expect(spoken.single.runes.length, lessThanOrEqualTo(280));
  });

  testWidgets('local rows ahead of the network cursor do not hide arrivals', (
    tester,
  ) async {
    final spoken = <String>[];
    final controller = IncomingMessageAnnouncementController(
      announce: (message, _) async => spoken.add(message),
      debounce: Duration.zero,
    );
    addTearDown(controller.dispose);

    controller.observeAuthoritativeMerge(
      messages: [_row(123, actorId: 'local-user', text: 'Local outbox row')],
      authoritativeMessageId: 109,
      localLoginName: 'local-user',
      activityLabel: 'New activity',
      textDirection: TextDirection.ltr,
      canAnnounce: () => true,
    );
    controller.observeAuthoritativeMerge(
      messages: [
        _row(120, text: 'Authoritative remote arrival'),
        _row(123, actorId: 'local-user', text: 'Local outbox row'),
      ],
      authoritativeMessageId: 120,
      localLoginName: 'local-user',
      activityLabel: 'New activity',
      textDirection: TextDirection.ltr,
      canAnnounce: () => true,
    );
    await tester.pump(const Duration(milliseconds: 1));

    expect(spoken, ['New activity. Remote user: Authoritative remote arrival']);
  });

  testWidgets('a room hidden during debounce does not announce', (
    tester,
  ) async {
    final spoken = <String>[];
    var visible = true;
    final controller = IncomingMessageAnnouncementController(
      announce: (message, _) async => spoken.add(message),
    );
    addTearDown(controller.dispose);

    controller.observeAuthoritativeMerge(
      messages: [_row(200, text: 'Initial')],
      authoritativeMessageId: 200,
      localLoginName: 'local-user',
      activityLabel: 'New activity',
      textDirection: TextDirection.ltr,
      canAnnounce: () => visible,
    );
    controller.observeAuthoritativeMerge(
      messages: [_row(201, text: 'Would be announced')],
      authoritativeMessageId: 201,
      localLoginName: 'local-user',
      activityLabel: 'New activity',
      textDirection: TextDirection.ltr,
      canAnnounce: () => visible,
    );
    visible = false;
    await tester.pump(const Duration(seconds: 1));

    expect(spoken, isEmpty);
  });
}

IncomingMessageAnnouncementRow _row(
  int messageId, {
  String actorId = 'remote-user',
  String sender = 'Remote user',
  String systemMessage = '',
  String messageType = 'comment',
  String text = 'Message',
  bool deleted = false,
}) => (
  messageId: messageId,
  actorId: actorId,
  actorDisplayName: sender,
  systemMessage: systemMessage,
  messageType: messageType,
  displayText: text,
  deleted: deleted,
);
