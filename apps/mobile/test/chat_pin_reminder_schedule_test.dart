import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_pin_reminder_schedule.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations_en.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

part 'chat_pin_reminder_schedule_test_support.dart';

void main() {
  setUp(setUpPinReminderScheduleHarness);
  tearDown(tearDownPinReminderScheduleHarness);

  group('pinned message banner', () {
    // Both entry points the app actually opens a room through wrap the same
    // pane, so the banner has to appear in both. A feature visible only from
    // the test-only `ChatRoomScreen` is not shipped.
    testWidgets('appears in the presence chat room screen', (tester) async {
      final conversation = await insertRoom(lastPinnedId: 10);
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('chat-pinned-banner')), findsOneWidget);
      expect(find.text('Pinned message'), findsOneWidget);
      expect(find.text('Cached hello'), findsWidgets);

      await teardownTree(tester);
    });

    testWidgets('appears in the presence chat room pane', (tester) async {
      final conversation = await insertRoom(lastPinnedId: 10);
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(),
          home: Scaffold(
            body: PresenceChatRoomPane(
              account: account,
              conversation: conversation,
            ),
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('chat-pinned-banner')), findsOneWidget);

      await teardownTree(tester);
    });

    testWidgets('stays away when nothing is pinned', (tester) async {
      final conversation = await insertRoom();
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('chat-pinned-banner')), findsNothing);

      await teardownTree(tester);
    });

    // `hiddenPinnedId == lastPinnedId` is exactly how the server reports
    // "this attendee hid the pin".
    testWidgets('stays away once this account hid the pin', (tester) async {
      final conversation = await insertRoom(
        lastPinnedId: 10,
        hiddenPinnedId: 10,
      );
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('chat-pinned-banner')), findsNothing);

      await teardownTree(tester);
    });

    testWidgets('hiding it calls pin/self for this account only', (
      tester,
    ) async {
      final conversation = await insertRoom(lastPinnedId: 10);
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.byKey(const Key('chat-pinned-banner-hide')));
      await flush(tester);

      expect(
        requestLog,
        contains(
          'DELETE /ocs/v2.php/apps/spreed/api/v1/chat/rooma123/10/pin/self',
        ),
      );

      await teardownTree(tester);
    });
  });

  group('pin action', () {
    testWidgets('a moderator can pin a message', (tester) async {
      // participantType 2 is a moderator.
      final conversation = await insertRoom(participantType: 2);
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            onRichChat: (request) =>
                http.Response(jsonEncode(_pinResponse()), 200),
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await settle(tester);
      expect(find.byKey(const Key('message-action-pin')), findsOneWidget);
      expect(find.byKey(const Key('message-action-unpin')), findsNothing);

      await tester.tap(find.byKey(const Key('message-action-pin')));
      await flush(tester);
      await pumpUntil(
        tester,
        () => find.byKey(const Key('chat-pin-success')).evaluate().isNotEmpty,
      );

      expect(
        requestLog,
        contains('POST /ocs/v2.php/apps/spreed/api/v1/chat/rooma123/10/pin'),
      );
      expect(find.byKey(const Key('chat-pin-success')), findsOneWidget);

      await teardownTree(tester);
    });

    testWidgets('the already pinned message offers unpin instead', (
      tester,
    ) async {
      final conversation = await insertRoom(
        participantType: 2,
        lastPinnedId: 10,
      );
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            onRichChat: (request) =>
                http.Response(jsonEncode(_pinResponse()), 200),
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await settle(tester);
      expect(find.byKey(const Key('message-action-pin')), findsNothing);

      await tester.tap(find.byKey(const Key('message-action-unpin')));
      await flush(tester);

      expect(
        requestLog,
        contains('DELETE /ocs/v2.php/apps/spreed/api/v1/chat/rooma123/10/pin'),
      );

      await teardownTree(tester);
    });

    // `#[RequireModeratorParticipant]` guards both pin routes, so an ordinary
    // participant must never be offered the action.
    testWidgets('an ordinary participant is not offered pinning', (
      tester,
    ) async {
      final conversation = await insertRoom(participantType: 3);
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await settle(tester);

      expect(find.byKey(const Key('message-action-pin')), findsNothing);
      expect(find.byKey(const Key('message-action-unpin')), findsNothing);

      await teardownTree(tester);
    });

    testWidgets('a server without pinned-messages offers nothing', (
      tester,
    ) async {
      final conversation = await insertRoom(participantType: 2);
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            talkFeatures: const <String>[
              'conversation-v4',
              'chat-v2',
              'chat-reference-id',
            ],
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await settle(tester);

      expect(find.byKey(const Key('message-action-pin')), findsNothing);
      expect(find.byKey(const Key('message-action-remind')), findsNothing);

      await teardownTree(tester);
    });
  });

  group('reminder action', () {
    testWidgets('setting a reminder posts the chosen timestamp', (
      tester,
    ) async {
      final conversation = await insertRoom();
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            onRichChat: (request) {
              if (request.method == 'GET') {
                // No reminder yet: Talk answers 404, which must read as
                // "none set" rather than as a failure.
                return http.Response(jsonEncode(_failureOcs(404)), 404);
              }
              return http.Response(
                jsonEncode(
                  _reminderOcs(
                    201,
                    int.parse(request.bodyFields['timestamp']!),
                  ),
                ),
                201,
              );
            },
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('message-action-remind')));
      await flush(tester);

      expect(find.byKey(const Key('reminder-sheet-title')), findsOneWidget);
      // With no reminder set there is nothing to remove.
      expect(find.byKey(const Key('reminder-remove')), findsNothing);

      final presets = find.byWidgetPredicate(
        (widget) =>
            widget is ListTile &&
            widget.key.toString().contains('reminder-preset-'),
      );
      expect(presets, findsWidgets);
      await tester.tap(presets.first);
      await flush(tester);

      expect(
        requestLog.where((entry) => entry.startsWith('POST')),
        contains(
          'POST /ocs/v2.php/apps/spreed/api/v1/chat/rooma123/10/reminder',
        ),
      );
      expect(find.byKey(const Key('chat-reminder-set')), findsOneWidget);

      await teardownTree(tester);
    });

    testWidgets('an existing reminder can be removed', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final conversation = await insertRoom();
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            onRichChat: (request) {
              if (request.method == 'GET') {
                return http.Response(
                  jsonEncode(_reminderOcs(200, 4102444800)),
                  200,
                );
              }
              return http.Response(jsonEncode(_emptyOcs(200)), 200);
            },
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('message-action-remind')));
      await flush(tester);

      final remove = find.byKey(const Key('reminder-remove'));
      expect(remove, findsOneWidget);
      await tester.ensureVisible(remove);
      await settle(tester);
      await tester.tap(remove);
      await flush(tester);

      expect(
        requestLog,
        contains(
          'DELETE /ocs/v2.php/apps/spreed/api/v1/chat/rooma123/10/reminder',
        ),
      );
      expect(find.byKey(const Key('chat-reminder-removed')), findsOneWidget);

      await teardownTree(tester);
    });

    testWidgets('a server without remind-me-later offers nothing', (
      tester,
    ) async {
      final conversation = await insertRoom();
      await insertMessage();
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            talkFeatures: const <String>[
              'conversation-v4',
              'chat-v2',
              'chat-reference-id',
              'pinned-messages',
            ],
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await settle(tester);

      expect(find.byKey(const Key('message-action-remind')), findsNothing);

      await teardownTree(tester);
    });
  });

  group('scheduled send', () {
    // `scheduled-messages` is announced only under `features-local`.
    testWidgets('the button stays hidden without the local capability', (
      tester,
    ) async {
      final conversation = await insertRoom();
      await tester.pumpWidget(
        wrap(
          api: buildApi(localFeatures: const <String>[]),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.byKey(const Key('pick-image-attachment')));
      await settle(tester);

      expect(find.byKey(const Key('schedule-message')), findsNothing);

      await teardownTree(tester);
    });

    testWidgets('a global feature entry does not enable it either', (
      tester,
    ) async {
      final conversation = await insertRoom();
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            talkFeatures: const <String>[
              ..._fullFeatures,
              'scheduled-messages',
            ],
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.byKey(const Key('pick-image-attachment')));
      await settle(tester);

      expect(find.byKey(const Key('schedule-message')), findsNothing);

      await teardownTree(tester);
    });

    testWidgets('scheduling posts the composed text and clears it', (
      tester,
    ) async {
      final conversation = await insertRoom();
      String? postedMessage;
      int? postedSendAt;
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            localFeatures: const <String>['scheduled-messages'],
            onRichChat: (request) {
              postedMessage = request.bodyFields['message'];
              postedSendAt = int.tryParse(request.bodyFields['sendAt'] ?? '');
              return http.Response(
                jsonEncode(_scheduleOcs(201, postedSendAt ?? 0)),
                201,
              );
            },
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.enterText(
        find.byKey(const Key('chat-composer')),
        'Send this later',
      );
      await settle(tester);

      await tester.tap(find.byKey(const Key('pick-image-attachment')));
      await settle(tester);

      final button = find.byKey(const Key('schedule-message'));
      expect(button, findsOneWidget);
      await tester.tap(button);
      await settle(tester);

      expect(find.byKey(const Key('send-later-title')), findsOneWidget);
      final presets = find.byWidgetPredicate(
        (widget) =>
            widget is ListTile &&
            widget.key.toString().contains('send-later-preset-'),
      );
      expect(presets, findsWidgets);
      await tester.tap(presets.first);
      await flush(tester);

      expect(postedMessage, 'Send this later');
      expect(postedSendAt, isNotNull);
      expect(
        postedSendAt!,
        greaterThan(DateTime.now().millisecondsSinceEpoch ~/ 1000),
      );
      expect(
        requestLog,
        contains('POST /ocs/v2.php/apps/spreed/api/v1/chat/rooma123/schedule'),
      );
      expect(find.byKey(const Key('chat-schedule-success')), findsOneWidget);
      // The text left the composer only because the server accepted it.
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-composer')))
            .controller
            ?.text,
        isEmpty,
      );

      await teardownTree(tester);
    });

    // The whole point of not putting this in the durable outbox: a scheduled
    // message must never appear as a pending text send, because the outbox
    // would have nothing to correlate against until the server fires it.
    testWidgets('a scheduled send creates no text outbox operation', (
      tester,
    ) async {
      final conversation = await insertRoom();
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            localFeatures: const <String>['scheduled-messages'],
            onRichChat: (request) => http.Response(
              jsonEncode(
                _scheduleOcs(201, int.parse(request.bodyFields['sendAt']!)),
              ),
              201,
            ),
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.enterText(
        find.byKey(const Key('chat-composer')),
        'Send this later',
      );
      await settle(tester);
      await tester.tap(find.byKey(const Key('pick-image-attachment')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('schedule-message')));
      await settle(tester);
      await tester.tap(
        find
            .byWidgetPredicate(
              (widget) =>
                  widget is ListTile &&
                  widget.key.toString().contains('send-later-preset-'),
            )
            .first,
      );
      await flush(tester);

      final operations = await database
          .select(database.textSendOperations)
          .get();
      expect(operations, isEmpty);

      await teardownTree(tester);
    });

    testWidgets('the scheduled list opens and can delete an entry', (
      tester,
    ) async {
      final conversation = await insertRoom(hasScheduledMessages: 1);
      await tester.pumpWidget(
        wrap(
          api: buildApi(
            localFeatures: const <String>['scheduled-messages'],
            onRichChat: (request) {
              if (request.method == 'GET') {
                return http.Response(
                  jsonEncode(
                    _ocs(200, <Object?>[_scheduledMessageJson(4102444800)]),
                  ),
                  200,
                );
              }
              // Talk answers a schedule delete with an empty object.
              return http.Response(
                jsonEncode(_ocs(200, <String, Object?>{})),
                200,
              );
            },
          ),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.byKey(const Key('open-scheduled-messages')));
      await flush(tester);

      expect(find.byKey(const Key('scheduled-messages-sheet')), findsOneWidget);
      final row = find.byKey(const Key('scheduled-message-77'));
      expect(row, findsOneWidget);
      expect(find.text('Scheduled hello'), findsOneWidget);

      await tester.tap(find.byKey(const Key('delete-scheduled-77')));
      await flush(tester);

      expect(
        requestLog,
        contains(
          'DELETE /ocs/v2.php/apps/spreed/api/v1/chat/rooma123/schedule/77',
        ),
      );
      expect(
        find.byKey(const Key('scheduled-message-deleted')),
        findsOneWidget,
      );

      await teardownTree(tester);
    });

    testWidgets('the scheduled list entry point stays hidden when empty', (
      tester,
    ) async {
      final conversation = await insertRoom();
      await tester.pumpWidget(
        wrap(
          api: buildApi(localFeatures: const <String>['scheduled-messages']),
          home: PresenceChatRoomScreen(
            account: account,
            conversation: conversation,
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('open-scheduled-messages')), findsNothing);

      await teardownTree(tester);
    });
  });

  group('time presets', () {
    testWidgets('Friday reminder choices stay independently selectable', (
      tester,
    ) async {
      ReminderSheetResult? result;
      final friday = DateTime(2026, 8, 28, 9);
      await tester.pumpWidget(
        localizedTestApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              key: const Key('open-fixed-reminder-sheet'),
              onPressed: () async {
                result = await showReminderSheet(
                  context: context,
                  now: friday,
                  existing: null,
                );
              },
              child: const Text('Open reminder'),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('open-fixed-reminder-sheet')));
      await tester.pumpAndSettle();

      final tomorrow = find.byKey(const Key('reminder-preset-tomorrow'));
      final weekend = find.byKey(const Key('reminder-preset-this-weekend'));
      expect(tomorrow, findsOneWidget);
      expect(weekend, findsOneWidget);
      await tester.tap(tomorrow);
      await tester.pumpAndSettle();
      expect(result?.at, DateTime(2026, 8, 29, 8));
    });

    testWidgets('Friday send-later choices stay independently selectable', (
      tester,
    ) async {
      DateTime? result;
      final friday = DateTime(2026, 8, 28, 9);
      await tester.pumpWidget(
        localizedTestApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              key: const Key('open-fixed-send-later-sheet'),
              onPressed: () async {
                result = await showSendLaterSheet(
                  context: context,
                  now: friday,
                );
              },
              child: const Text('Open send later'),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('open-fixed-send-later-sheet')));
      await tester.pumpAndSettle();

      final tomorrow = find.byKey(const Key('send-later-preset-tomorrow'));
      final weekend = find.byKey(const Key('send-later-preset-this-weekend'));
      expect(tomorrow, findsOneWidget);
      expect(weekend, findsOneWidget);
      await tester.tap(weekend);
      await tester.pumpAndSettle();
      expect(result, DateTime(2026, 8, 29, 8));
    });

    // The server refuses a reminder or a send time in the past, so a preset
    // that has already gone by must not be offered at all.
    test('a preset already gone by today is dropped', () {
      final strings = AppLocalizationsEn();
      final evening = DateTime(2026, 8, 25, 22);
      final labels = timePresets(
        strings,
        evening,
      ).map((preset) => preset.label).toList();
      expect(labels, isNot(contains(strings.reminderLaterToday)));
      expect(labels, contains(strings.reminderTomorrow));
    });

    test('every preset is in the future', () {
      final now = DateTime(2026, 8, 25, 9, 30);
      for (final preset in timePresets(AppLocalizationsEn(), now)) {
        expect(preset.at.isAfter(now), isTrue, reason: preset.label);
      }
    });

    // 25 August 2026 is a Tuesday, so the weekend is that Saturday and the
    // next week starts the following Monday.
    test('the weekend and next week land on the right days', () {
      final presets = timePresets(
        AppLocalizationsEn(),
        DateTime(2026, 8, 25, 9, 30),
      );
      final strings = AppLocalizationsEn();
      final weekend = presets.firstWhere(
        (preset) => preset.label == strings.reminderThisWeekend,
      );
      final nextWeek = presets.firstWhere(
        (preset) => preset.label == strings.reminderNextWeek,
      );
      expect(weekend.at.weekday, DateTime.saturday);
      expect(nextWeek.at.weekday, DateTime.monday);
      expect(nextWeek.at.isAfter(weekend.at), isTrue);
    });
  });

  group('pinned message state', () {
    test('a conversation cached without a room body reports no pin', () {
      final state = PinnedMessageState.fromCachedConversation(
        _bareConversation('{}'),
      );
      expect(state.isVisible, isFalse);
      expect(scheduledMessageCount(_bareConversation('{}')), 0);
    });

    test('an unreadable payload reports no pin', () {
      final state = PinnedMessageState.fromCachedConversation(
        _bareConversation('not json'),
      );
      expect(state.isVisible, isFalse);
    });
  });
}
