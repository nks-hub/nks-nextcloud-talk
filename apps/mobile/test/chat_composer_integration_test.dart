import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/stale_modifier_repair.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/attachment_repository.dart';
import 'package:nextcloudtalk/data/chat_repository.dart';
import 'package:nextcloudtalk/data/credential_vault.dart';
import 'package:nextcloudtalk/features/chat/attachment_service.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';
import 'package:nextcloudtalk/features/chat/composer/chat_media_composer.dart';
import 'package:nextcloudtalk/features/chat/media/image_attachment_upload_panel.dart';
import 'package:nextcloudtalk/features/chat/composer/clipboard_image_offer.dart';
import 'package:nextcloudtalk/features/chat/composer/clipboard_image_source.dart';
import 'package:nextcloudtalk/features/chat/composer/giphy.dart';
import 'package:nextcloudtalk/features/chat/composer/giphy_attachment.dart';
import 'package:nextcloudtalk/features/chat/emoji_only_message.dart';
import 'package:nextcloudtalk/features/chat/location_share_service.dart';
import 'package:nextcloudtalk/features/chat/quick_emoji_hold_button.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_room_extras.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_settings_store.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:nextcloudtalk/platform/app_settings.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'clipboard_image_test_support.dart';
import 'owntalk_extensions_test_support.dart';
import 'test_support.dart';

part 'chat_composer_location_test.part.dart';
part 'chat_composer_giphy_reopen_test.part.dart';
part 'chat_composer_nonblocking_test.part.dart';
part 'chat_composer_quick_emoji_test.part.dart';
part 'chat_composer_clipboard_offer_test.part.dart';
part 'chat_composer_compact_reply_test.part.dart';

typedef _ShortComposerGeometry = ({
  String name,
  Size physicalSize,
  double pixelRatio,
  double topPadding,
  double keyboard,
  double visibleHeight,
  bool attachment,
});

void main() {
  _registerLocationComposerTests();
  _registerGiphyReopenTests();
  _registerNonBlockingComposerTests();
  _registerQuickEmojiComposerTests();
  _registerClipboardOfferComposerTests();
  _registerCompactReplyComposerTest();
  for (final geometry in <_ShortComposerGeometry>[
    (
      name: 'Galaxy S9 landscape',
      physicalSize: const Size(2220, 1080),
      pixelRatio: 2.625,
      topPadding: 63,
      keyboard: 580,
      visibleHeight: 500,
      attachment: true,
    ),
    _s21LandscapeComposerGeometry,
    (
      name: '300dp short detail pane',
      physicalSize: const Size(787.5, 1080),
      pixelRatio: 2.625,
      topPadding: 63,
      keyboard: 580,
      visibleHeight: 500,
      attachment: false,
    ),
  ]) {
    testWidgets(
      '${geometry.name} keeps the composer above a tall keyboard',
      (tester) => _verifyShortComposer(tester, geometry),
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  testWidgets(
    'media reply reaches finalize and clears its banner on enqueue',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      await tester.runAsync(harness.seedReplyMessage);

      await tester.pumpWidget(harness.app());
      await _pumpUntil(
        tester,
        () =>
            find
                .byKey(const Key('chat-message-target-109'))
                .evaluate()
                .isNotEmpty &&
            find.byType(ChatMediaComposer).evaluate().isNotEmpty,
      );
      await tester.longPress(find.byKey(const Key('chat-message-target-109')));
      await _pumpTransition(tester);
      await tester.tap(find.byKey(const Key('message-action-reply')));
      await _pumpTransition(tester);
      expect(find.byKey(const Key('chat-reply-banner')), findsOneWidget);

      final controller = tester
          .widget<ChatMediaComposer>(find.byType(ChatMediaComposer))
          .controller!;
      late Future<bool> acceptedFuture;
      await tester.runAsync(() async {
        acceptedFuture = controller.submitGiphyAttachment(
          (_) async => GiphyAttachmentPayload(
            body: _animatedGif,
            mimeType: 'image/gif',
            displayName: 'reply-fixture.gif',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 1));
      });
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-reply-banner')).evaluate().isEmpty,
      );
      expect(await tester.runAsync(() => acceptedFuture), isTrue);
      await _pumpUntil(tester, () => harness.finalizedMetadata.isNotEmpty);

      expect(harness.finalizedMetadata.single['replyTo'], 109);
      expect(harness.finalizedMetadata.single.containsKey('threadId'), isFalse);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  testWidgets('Giphy selection sends a reference and keeps the composer', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    _addHarnessTearDown(tester, harness);
    final giphy = _giphyRepository();
    addTearDown(giphy.close);

    await tester.pumpWidget(
      harness.app(
        overrides: <Override>[
          giphyRepositoryProvider.overrideWith((ref, accountId) async {
            expect(accountId, harness.account.id);
            return giphy;
          }),
        ],
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('open-emoji-picker')));
    await _pumpTransition(tester);
    // The picker expands above the compose row instead of covering it: the
    // line being typed into has to stay on screen while picking.
    expect(find.byKey(const Key('inline-emoji-panel')), findsOneWidget);
    expect(find.byKey(const Key('chat-composer')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('inline-emoji-panel'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('chat-composer'))).dy),
    );
    await tester.tap(find.byKey(const Key('emoji-category-people')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('emoji-choice-waving-hand')));
    await _pumpTransition(tester);
    expect(_composer(tester).text, '👋');
    // The picker stays open for a second pick; sending the message is what
    // dismisses it (the close button does too).
    expect(find.byKey(const Key('emoji-close')), findsOneWidget);
    await _pumpUntil(tester, () => _sendButtonEnabled(tester));
    await tester.tap(find.byKey(const Key('send-message-gesture')));
    await _pumpUntil(
      tester,
      () => harness.sentMessages.length == 1 && _composer(tester).text.isEmpty,
    );
    await _pumpTransition(tester);
    expect(harness.sentMessages, <String>['👋']);
    expect(find.byKey(const Key('inline-emoji-panel')), findsNothing);
    await tester.tap(find.byKey(const Key('open-emoji-picker')));
    await _pumpTransition(tester);
    await tester.tap(find.byKey(const Key('emoji-category-people')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('emoji-choice-waving-hand')));
    await _pumpTransition(tester);
    await tester.tap(find.byKey(const Key('emoji-close')));
    await _pumpTransition(tester);
    expect(find.byKey(const Key('inline-emoji-panel')), findsNothing);

    await _tapGiphy(tester);
    final gif = find.byKey(
      const ValueKey<String>('giphy-thumbnail-https://giphy.com/gifs/wave'),
    );
    await _pumpUntil(tester, () => gif.evaluate().isNotEmpty);
    await _pumpTransition(tester);
    final thumbnailImage = tester.widget<Image>(
      find.descendant(of: gif, matching: find.byType(Image)),
    );
    final resizedThumbnail = thumbnailImage.image as ResizeImage;
    expect(resizedThumbnail.width, 480);
    expect(resizedThumbnail.height, 480);
    final pickerRect = tester.getRect(find.byType(GiphyPicker));
    final viewportHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(pickerRect.top, greaterThanOrEqualTo(0));
    expect(pickerRect.bottom, lessThanOrEqualTo(viewportHeight));
    await tester.ensureVisible(gif);
    await tester.pump();
    await tester.tap(gif);
    await _pumpTransition(tester);
    await _pumpUntil(tester, () => harness.sentMessages.length == 2);

    // The GIF travels as a reference the bubble renders, so nothing is
    // uploaded into the user's own storage.
    expect(harness.sentMessages.last, 'https://giphy.com/gifs/wave');
    expect(harness.uploadedAttachments, isEmpty);
    expect(harness.finalizedFileNames, isEmpty);
    // Text already typed must survive sending a GIF.
    expect(_composer(tester).text, '👋');

    await _pumpUntil(tester, () => _sendButtonEnabled(tester));
    await tester.tap(find.byKey(const Key('send-message-gesture')));
    await _pumpUntil(
      tester,
      () => harness.sentMessages.length == 3 && _composer(tester).text.isEmpty,
    );

    expect(harness.sentMessages.last, '👋');
    expect(_composer(tester).text, isEmpty);
    expect(tester.takeException(), isNull);
    await _unmountComposer(tester);
  });

  testWidgets(
    'unavailable Giphy integration becomes an honest disabled state',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);

      await tester.pumpWidget(
        harness.app(
          overrides: <Override>[
            giphyRepositoryProvider.overrideWith(
              (ref, accountId) async => null,
            ),
          ],
        ),
      );
      await _pumpUntil(tester, () => _giphyButtonEnabled(tester));
      await _tapGiphy(tester);
      await _pumpUntil(tester, () => !_giphyButtonEnabled(tester));
      await _openComposerMenu(tester);
      final tile = find.byKey(const Key('open-giphy-picker'));
      await _pumpUntil(
        tester,
        () => find
            .text('GIFs are not available on this server.')
            .evaluate()
            .isNotEmpty,
      );
      expect(tester.widget<ListTile>(tile).enabled, isFalse);
      expect(find.byType(GiphyPicker), findsNothing);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
  );

  testWidgets(
    'first Giphy tap keeps the probe alive before the watched frame',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      final probeClient = _ControlledGiphyClient();
      addTearDown(probeClient.close);
      var factoryInvocations = 0;

      await tester.pumpWidget(
        harness.app(
          overrides: <Override>[
            giphyRepositoryFactoryProvider.overrideWithValue(({
              required ServerBase server,
              required GiphyAuthorization authorization,
            }) {
              factoryInvocations++;
              return HttpGiphyRepository(
                server: server,
                authorization: authorization,
                client: probeClient,
              );
            }),
          ],
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
      );
      await _pumpUntil(tester, () => _giphyButtonEnabled(tester));

      await _tapGiphy(tester);
      await tester.runAsync(() async {
        for (var attempt = 0; attempt < 600; attempt++) {
          if (probeClient.requestStarted.isCompleted) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });
      final startedBeforeFrame = probeClient.requestStarted.isCompleted;

      await tester.pump();
      await _pumpUntil(tester, () => probeClient.requestStarted.isCompleted);
      expect(find.byKey(const Key('pick-image-attachment')), findsOneWidget);
      probeClient.complete(_giphyResponse());
      await _pumpUntil(
        tester,
        () => find.byType(GiphyPicker).evaluate().isNotEmpty,
      );

      expect(startedBeforeFrame, isTrue);
      expect(factoryInvocations, 1);
      expect(probeClient.closed, isFalse);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
  );

  testWidgets(
    'a completed Giphy probe cannot cross a changed account or room scope',
    (tester) async {
      final harness = (await tester.runAsync(_ComposerHarness.create))!;
      _addHarnessTearDown(tester, harness);
      final probeClient = _ControlledGiphyClient();
      addTearDown(probeClient.close);
      final factoryOverride = giphyRepositoryFactoryProvider.overrideWithValue(
        ({
          required ServerBase server,
          required GiphyAuthorization authorization,
        }) {
          return HttpGiphyRepository(
            server: server,
            authorization: authorization,
            client: probeClient,
          );
        },
      );

      await tester.pumpWidget(
        harness.app(overrides: <Override>[factoryOverride]),
      );
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
      );
      await _pumpUntil(tester, () => _giphyButtonEnabled(tester));
      await _tapGiphy(tester);
      await _pumpUntil(tester, () => probeClient.requestStarted.isCompleted);

      final accountB = harness.account.copyWith(
        id: 'account-b',
        serverUrl: 'https://cloud-b.example.invalid',
        loginName: 'fixture-user-b',
      );
      final conversationB = harness.conversation.copyWith(
        accountId: accountB.id,
        token: 'roomb123',
        displayName: 'Room B',
      );
      await tester.pumpWidget(
        harness.app(
          account: accountB,
          conversation: conversationB,
          overrides: <Override>[factoryOverride],
        ),
      );
      await tester.pump();

      probeClient.complete(_giphyResponse());
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();

      expect(find.byType(GiphyPicker), findsNothing);
      expect(harness.sentMessages, isEmpty);
      expect(tester.takeException(), isNull);
      await _unmountComposer(tester);
    },
  );
  testWidgets('a bare Enter sends and Shift+Enter does not, in the real pane', (
    tester,
  ) async {
    // The rule itself is asserted in `composer_enter_key_test.dart`. What
    // only the real pane can show is that the `Focus` around the field sees
    // Enter at all, rather than the multiline field swallowing it first.
    // Reset inside the body, not in a tearDown: the invariant that catches
    // a leaked debug variable runs before tearDowns do.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    _addHarnessTearDown(tester, harness);

    await tester.pumpWidget(harness.app());
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const Key('chat-composer')));
    await tester.pump();

    await tester.enterText(
      find.byKey(const Key('chat-composer')),
      'ctrl-free send',
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(milliseconds: 50));
    expect(_composer(tester).text, startsWith('ctrl-free send'));
    expect(
      harness.sentMessages,
      isEmpty,
      reason: 'Shift+Enter belongs to the field, not to sending',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _pumpUntil(tester, () => harness.sentMessages.isNotEmpty);

    // Only the send matters here; clearing the composer afterwards is
    // already covered by the emoji test above.
    expect(harness.sentMessages, <String>['ctrl-free send']);
    expect(tester.takeException(), isNull);
    await _unmountComposer(tester);
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('Escape backs out of a reply', (tester) async {
    final harness = (await tester.runAsync(_ComposerHarness.create))!;
    _addHarnessTearDown(tester, harness);
    await tester.runAsync(harness.seedReplyMessage);

    await tester.pumpWidget(harness.app());
    await _pumpUntil(
      tester,
      () =>
          find
              .byKey(const Key('chat-message-target-109'))
              .evaluate()
              .isNotEmpty &&
          find.byType(ChatMediaComposer).evaluate().isNotEmpty,
    );
    await tester.longPress(find.byKey(const Key('chat-message-target-109')));
    await _pumpTransition(tester);
    await tester.tap(find.byKey(const Key('message-action-reply')));
    await _pumpTransition(tester);
    expect(find.byKey(const Key('chat-reply-banner')), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-composer')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-reply-banner')).evaluate().isEmpty,
    );

    expect(find.byKey(const Key('chat-reply-banner')), findsNothing);
    expect(harness.sentMessages, isEmpty);
    expect(tester.takeException(), isNull);
    await _unmountComposer(tester);
  }, timeout: const Timeout(Duration(seconds: 20)));
}

TextEditingController _composer(WidgetTester tester) {
  return tester
      .widget<TextField>(find.byKey(const Key('chat-composer')))
      .controller!;
}

bool _sendButtonEnabled(WidgetTester tester) {
  return tester
          .widget<IconButton>(find.byKey(const Key('send-message')))
          .onPressed !=
      null;
}

/// Pumps until [condition] holds.
///
/// The bound is a net against a hang, not a budget for the work: the chains
/// waited on here span drift, real file I/O and a mocked HTTP round trip, and
/// at the old bound of 100 they outran it on a loaded machine — the media
/// reply test then failed reproducibly while the code was fine. Six hundred
/// rounds is roughly seven seconds, still inside the twenty-second timeout,
/// and the work itself finishes in three.
Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 600; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    if (condition()) {
      return;
    }
  }
  fail('Condition was not reached');
}

Future<void> _pumpTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void _addHarnessTearDown(WidgetTester tester, _ComposerHarness harness) {
  addTearDown(() async {
    await tester.runAsync(harness.close);
  });
}

Future<void> _unmountComposer(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

Future<void> _verifyShortComposer(
  WidgetTester tester,
  _ShortComposerGeometry geometry,
) async {
  tester.view.devicePixelRatio = geometry.pixelRatio;
  tester.view.physicalSize = geometry.physicalSize;
  tester.view.padding = FakeViewPadding(top: geometry.topPadding);
  tester.view.viewPadding = FakeViewPadding(top: geometry.topPadding);
  tester.view.viewInsets = FakeViewPadding.zero;
  addTearDown(tester.view.reset);

  final harness = (await tester.runAsync(_ComposerHarness.create))!;
  _addHarnessTearDown(tester, harness);
  await tester.pumpWidget(harness.app(inRoomScreen: true));
  await _pumpUntil(
    tester,
    () =>
        find.byType(ChatMediaComposer).evaluate().isNotEmpty &&
        find.byKey(const Key('chat-composer')).evaluate().isNotEmpty,
  );
  await _pumpUntil(
    tester,
    () => find.text('No messages yet').evaluate().isNotEmpty,
  );

  final composer = find.byKey(const Key('chat-composer'));
  final editable = find.descendant(
    of: composer,
    matching: find.byType(EditableText),
  );
  final mediaWidget = find.byType(ChatMediaComposer);
  final editableElement = tester.element(editable);
  final mediaElement = tester.element(mediaWidget);
  final media = tester.widget<ChatMediaComposer>(mediaWidget).controller!;
  expect(tester.widget<TextField>(composer).decoration?.isDense, isTrue);
  await tester.enterText(composer, 'First line\nSecond line');
  await tester.pump();
  expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isTrue);
  expect(tester.element(editable), same(editableElement));
  expect(tester.element(mediaWidget), same(mediaElement));
  if (geometry.attachment) {
    final attached = await tester.runAsync(
      () => media.attachImageBytes(
        tinyPng,
        mimeType: 'image/png',
        displayName: 'layout-fixture.png',
      ),
    );
    expect(attached, isTrue);
    expect(tester.element(mediaWidget), same(mediaElement));
    await _pumpUntil(tester, () => media.hasPreparedAttachment);
  }
  tester.view.viewInsets = FakeViewPadding(bottom: geometry.keyboard);
  await _pumpTransition(tester);
  expect(tester.element(editable), same(editableElement));
  expect(tester.element(mediaWidget), same(mediaElement));
  expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isTrue);
  if (geometry.attachment) {
    expect(media.hasPreparedAttachment, isTrue);
  }
  expect(tester.widget<TextField>(composer).decoration?.isDense, isTrue);
  await tester.enterText(composer, 'First line\nSecond line updated');
  await tester.pump();
  expect(_composer(tester).text, 'First line\nSecond line updated');

  final visibleBottom = geometry.visibleHeight / geometry.pixelRatio;
  final send = find.byKey(const Key('send-message-gesture'));
  expect(send.hitTestable(), findsOneWidget);
  expect(tester.getRect(send).bottom, lessThanOrEqualTo(visibleBottom));
  final controls = <Finder>[
    composer,
    find.byKey(const Key('pick-image-attachment')),
    find.byKey(const Key('open-emoji-picker')),
    send,
  ];
  for (final control in controls) {
    expect(control, findsOneWidget);
    await tester.ensureVisible(control);
    await tester.pump();
    expect(control.hitTestable(), findsOneWidget);
    final rect = tester.getRect(control);
    expect(rect.width, greaterThanOrEqualTo(48));
    expect(rect.height, greaterThanOrEqualTo(48));
    expect(rect.bottom, lessThanOrEqualTo(visibleBottom));
  }

  if (geometry.attachment) {
    final summary = find.byKey(const Key('compact-attachment-summary'));
    await _pumpUntil(tester, () => summary.evaluate().isNotEmpty);
    await tester.ensureVisible(summary);
    await tester.pump();
    expect(summary.hitTestable(), findsOneWidget);
    final summaryRect = tester.getRect(summary);
    expect(summaryRect.width, greaterThanOrEqualTo(48));
    expect(summaryRect.height, greaterThanOrEqualTo(48));
    expect(summaryRect.bottom, lessThanOrEqualTo(visibleBottom));

    await tester.tap(summary);
    await _pumpTransition(tester);
    expect(find.byKey(const Key('compact-attachment-sheet')), findsOneWidget);
    expect(find.byKey(const Key('remove-prepared-attachment')), findsOneWidget);
    tester.view.viewInsets = FakeViewPadding.zero;
    await _pumpTransition(tester);
    expect(tester.element(editable), same(editableElement));
    expect(tester.element(mediaWidget), same(mediaElement));
    expect(media.hasPreparedAttachment, isTrue);
    expect(find.byKey(const Key('compact-attachment-sheet')), findsOneWidget);
    expect(tester.takeException(), isNull);
    Navigator.of(
      tester.element(find.byKey(const Key('compact-attachment-sheet'))),
    ).pop();
    await _pumpTransition(tester);
  }

  await tester.enterText(composer, '');
  await tester.pump();
  expect(_composer(tester).text, isEmpty);
  expect(harness.sentMessages, isEmpty);
  expect(harness.uploadedAttachments, isEmpty);
  expect(harness.finalizedFileNames, isEmpty);
  expect(tester.takeException(), isNull);
  tester.view.viewInsets = FakeViewPadding.zero;
  await _unmountComposer(tester);
}

final class _ComposerHarness {
  _ComposerHarness({
    required this.database,
    required this.account,
    required this.conversation,
    required this.vault,
    required this.api,
    required this.sentMessages,
    required this.chatSendStarted,
    required this.chatSendFields,
    required this.attachmentUploadStarted,
    required this.chatSendHold,
    required this.chatSendFailures,
    required this.attachmentUploadHold,
    required this.sourceStore,
    required this.attachmentService,
    required this.attachmentClient,
    required this.attachmentRoot,
    required this.uploadedAttachments,
    required this.finalizedFileNames,
    required this.finalizedMetadata,
  });

  final AppDatabase database;
  final StoredAccount account;
  final CachedConversation conversation;
  final MemoryCredentialVault vault;
  final HttpNextcloudApi api;
  final List<String> sentMessages;

  /// Messages and uploads whose request has reached the fixture server,
  /// answered or not.
  final List<String> chatSendStarted;

  /// The form fields of every send request that reached the fixture server.
  final List<Map<String, String>> chatSendFields;
  final List<int> attachmentUploadStarted;

  /// While one of these is pending, the matching fixture request stays open, so
  /// a test can look at the composer with a send still on the wire.
  final List<Completer<void>> chatSendHold;

  /// While not empty, every read of the stored password waits for the first
  /// of these. A send is admitted only after such a read, so this is what a
  /// slow admission looks like.
  final List<Completer<void>> admissionHold = <Completer<void>>[];

  /// Whether a password read finds nothing, which refuses the admission that
  /// asked for it.
  bool admissionRefused = false;

  final List<Completer<void>> attachmentUploadHold;

  /// Messages whose send request dies on the wire instead of being answered.
  final Set<String> chatSendFailures;
  final DurableAttachmentSourceStore sourceStore;
  final AttachmentService attachmentService;
  final http.Client attachmentClient;
  final Directory attachmentRoot;
  final List<List<int>> uploadedAttachments;
  final List<String> finalizedFileNames;
  final List<Map<String, Object?>> finalizedMetadata;

  static Future<_ComposerHarness> create({
    FakeOwnTalkServer? ownTalk,
    bool voice = false,
    int maximumSourceBytes = durableAttachmentDefaultMaximumBytes,
  }) async {
    final database = openTestDatabase();
    final accounts = AccountRepository(database);
    final account = await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final roomJson = _conversationRoomJson();
    final room = ConversationRoom.fromJson(roomJson);
    await database
        .into(database.cachedConversations)
        .insert(
          CachedConversationsCompanion.insert(
            accountId: account.id,
            token: room.token.value,
            displayName: room.displayName,
            description: room.description,
            lastActivity: room.lastActivity,
            unreadMessages: room.unreadMessages,
            favorite: room.isFavorite,
            readOnly: Value(room.readOnly),
            roomType: Value(room.type),
            roomName: Value(room.name),
            objectType: Value(room.objectType),
            avatarVersion: Value(room.avatarVersion),
            isCustomAvatar: Value(room.isCustomAvatar),
            rawJson: jsonEncode(roomJson),
          ),
        );
    final conversation = await database
        .select(database.cachedConversations)
        .getSingle();
    final vault = MemoryCredentialVault()
      ..values[account.id] = 'fixture-app-password';
    final sentMessages = <String>[];
    final chatSendStarted = <String>[];
    final chatSendFields = <Map<String, String>>[];
    final attachmentUploadStarted = <int>[];
    final chatSendHold = <Completer<void>>[];
    final chatSendFailures = <String>{};
    final attachmentUploadHold = <Completer<void>>[];
    final uploadedAttachments = <List<int>>[];
    final finalizedFileNames = <String>[];
    final finalizedMetadata = <Map<String, Object?>>[];
    final attachmentRoot = await Directory.systemTemp.createTemp(
      'nctalk-composer-attachments-',
    );
    final sourceStore = DurableAttachmentSourceStore(
      root: attachmentRoot,
      maximumSourceBytes: maximumSourceBytes,
    );
    await sourceStore.initialize();
    final attachmentClient = MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/folder')) {
        return http.Response.bytes(_attachmentProbeSuccess(), 200);
      }
      if (request.method == 'PUT') {
        attachmentUploadStarted.add(request.bodyBytes.length);
        if (attachmentUploadHold.isNotEmpty) {
          await attachmentUploadHold.first.future;
        }
        uploadedAttachments.add(List<int>.from(request.bodyBytes));
        return http.Response('', 201);
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/attachment')) {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        final fileName = body['fileName']! as String;
        finalizedFileNames.add(fileName);
        finalizedMetadata.add(
          Map<String, Object?>.from(
            jsonDecode(body['talkMetaData']! as String) as Map<String, Object?>,
          ),
        );
        return http.Response.bytes(_attachmentFinalizeSuccess(fileName), 200);
      }
      fail('Unexpected attachment request: ${request.method} ${request.url}');
    });
    final attachmentService = AttachmentService(
      repository: AttachmentRepository(database),
      credentials: vault,
      releaseSource: (source) => sourceStore.discard(source.handle),
      transport: HttpAttachmentTransport(
        client: attachmentClient,
        sourceProvider: sourceStore,
      ),
      watchConfirmationCandidates: () =>
          const Stream<AttachmentConfirmationSnapshot>.empty(),
      confirmationRetryDelays: const <Duration>[Duration(hours: 1)],
    );
    await attachmentService.ready;
    final api = HttpNextcloudApi(
      // No snapshot outlives its read, so every send here is admitted the way
      // a cold start admits it: from the stored capabilities, with the server
      // asked afterwards.
      capabilityCacheTtl: Duration.zero,
      client: MockClient((request) async {
        if (ownTalk != null &&
            request.url.path.contains('/owntalk_extensions/')) {
          return ownTalk.handle(request);
        }
        if (request.url.path.endsWith('/cloud/capabilities')) {
          final capabilities = _attachmentCapabilities(voice);
          if (ownTalk != null) {
            (((capabilities['ocs']! as Map<String, Object?>)['data']!
                        as Map<String, Object?>)['capabilities']!
                    as Map<String, Object?>)['owntalk_extensions'] =
                ownTalkCapabilityJson();
          }
          return http.Response(jsonEncode(capabilities), 200);
        }
        if (request.method == 'POST') {
          chatSendStarted.add(request.bodyFields['message']!);
          chatSendFields.add(Map<String, String>.of(request.bodyFields));
          if (chatSendFailures.contains(request.bodyFields['message'])) {
            throw http.ClientException('connection lost');
          }
          if (chatSendHold.isNotEmpty) {
            await chatSendHold.first.future;
          }
          sentMessages.add(request.bodyFields['message']!);
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(
                _sendResponse(
                  referenceId: request.bodyFields['referenceId']!,
                  message: request.bodyFields['message']!,
                ),
              ),
            ),
            201,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
              'X-Chat-Last-Common-Read': '110',
            },
          );
        }
        if (request.url.path.contains('/avatar/')) {
          return http.Response('', 404);
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/apps/spreed/api/v1/chat/rooma123')) {
          return http.Response('', 304);
        }
        return http.Response('', 404);
      }),
    );
    return _ComposerHarness(
      database: database,
      account: account,
      conversation: conversation,
      vault: vault,
      api: api,
      sentMessages: sentMessages,
      chatSendStarted: chatSendStarted,
      chatSendFields: chatSendFields,
      attachmentUploadStarted: attachmentUploadStarted,
      chatSendHold: chatSendHold,
      chatSendFailures: chatSendFailures,
      attachmentUploadHold: attachmentUploadHold,
      sourceStore: sourceStore,
      attachmentService: attachmentService,
      attachmentClient: attachmentClient,
      attachmentRoot: attachmentRoot,
      uploadedAttachments: uploadedAttachments,
      finalizedFileNames: finalizedFileNames,
      finalizedMetadata: finalizedMetadata,
    );
  }

  Future<void> seedReplyMessage() async {
    final room = _conversationRoomJson();
    final message = Map<String, Object?>.from(
      room['lastMessage']! as Map<String, Object?>,
    );
    await database
        .into(database.cachedChatMessages)
        .insert(
          CachedChatMessagesCompanion.insert(
            accountId: account.id,
            roomToken: conversation.token,
            messageId: message['id']! as int,
            actorType: message['actorType']! as String,
            actorId: message['actorId']! as String,
            actorDisplayName: message['actorDisplayName']! as String,
            timestamp: message['timestamp']! as int,
            systemMessage: message['systemMessage']! as String,
            messageType: message['messageType']! as String,
            referenceId: message['referenceId']! as String,
            displayText: message['message']! as String,
            deleted: false,
            rawJson: jsonEncode(message),
          ),
        );
  }

  Widget app({
    StoredAccount? account,
    CachedConversation? conversation,
    bool wrapInScaffold = false,
    bool inRoomScreen = false,
    List<Override> overrides = const <Override>[],
  }) {
    return ProviderScope(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(_GatedVault(this)),
        nextcloudApiProvider.overrideWithValue(api),
        attachmentSourceProvider.overrideWith((ref) async => sourceStore),
        attachmentServiceProvider.overrideWith(
          (ref) async => attachmentService,
        ),
        ...overrides,
      ],
      child: localizedTestApp(
        home: inRoomScreen
            ? PresenceChatRoomScreen(
                account: account ?? this.account,
                conversation: conversation ?? this.conversation,
              )
            : wrapInScaffold
            ? Scaffold(
                body: ChatRoomPane(
                  account: account ?? this.account,
                  conversation: conversation ?? this.conversation,
                ),
              )
            : ChatRoomPane(
                account: account ?? this.account,
                conversation: conversation ?? this.conversation,
              ),
      ),
    );
  }

  Future<void> close() async {
    await api.close();
    await attachmentService.close();
    attachmentClient.close();
    await database.close();
    if (await attachmentRoot.exists()) {
      await attachmentRoot.delete(recursive: true);
    }
  }
}

HttpGiphyRepository _giphyRepository() {
  return HttpGiphyRepository(
    server: ServerBase.parse('https://cloud.example.invalid'),
    authorization: const GiphyAuthorization(
      loginName: 'fixture-user',
      appPassword: 'fixture-app-password',
    ),
    client: MockClient((request) async {
      if (request.url.path.endsWith('/gifs/trending')) {
        return http.Response(
          jsonEncode(<String, Object?>{
            'ocs': <String, Object?>{
              'meta': <String, Object?>{
                'status': 'ok',
                'statuscode': 200,
                'message': 'OK',
              },
              'data': <String, Object?>{
                'entries': <Object?>[
                  <String, Object?>{
                    'thumbnailUrl':
                        'https://cloud.example.invalid/'
                        'apps/integration_giphy/gif/wave',
                    'title': 'Wave',
                    'subline': 'Fixture author',
                    'resourceUrl': 'https://giphy.com/gifs/wave',
                  },
                ],
                'cursor': 1,
              },
            },
          }),
          200,
        );
      }
      if (request.url.path == '/apps/integration_giphy/gif/wave') {
        return http.Response.bytes(
          _animatedGif,
          200,
          headers: const <String, String>{'content-type': 'image/gif'},
        );
      }
      if (request.url.path.endsWith('/ocs/v2.php/references/resolve')) {
        return http.Response(
          _giphyReferenceResponse(Uri.parse('https://giphy.com/gifs/wave')),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }
      if (request.url.path.endsWith(
        '/index.php/apps/integration_giphy/gif/proxy',
      )) {
        return http.Response.bytes(
          _animatedGif,
          200,
          headers: const <String, String>{'content-type': 'image/gif'},
        );
      }
      if (request.url.path ==
          '/apps/integration_giphy/img/powered-by-giphy.gif') {
        return http.Response.bytes(
          base64Decode('R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=='),
          200,
          headers: const <String, String>{'content-type': 'image/gif'},
        );
      }
      return http.Response('', 404);
    }),
  );
}

Map<String, Object?> _attachmentCapabilities(bool voice) {
  final result = capabilitiesJson(
    talkFeatures: <String>[
      if (voice) 'voice-message-sharing',
      'conversation-v4',
      'chat-v2',
      'chat-reference-id',
      'chat-replies',
      'geo-location-sharing',
    ],
  );
  final ocs = result['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final capabilities = data['capabilities']! as Map<String, Object?>;
  final spreed = capabilities['spreed']! as Map<String, Object?>;
  final config = spreed['config']! as Map<String, Object?>;
  config['attachments'] = <String, Object?>{
    'allowed': true,
    'conversation-subfolders': true,
  };
  return result;
}

List<int> _attachmentProbeSuccess() => utf8.encode(
  jsonEncode(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'folder': 'Talk/Fixture/Draft',
        'renames': <Object?>[],
      },
    },
  }),
);

List<int> _attachmentFinalizeSuccess(String fileName) => utf8.encode(
  jsonEncode(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'renames': <Object?>[
          <String, Object?>{fileName: fileName},
        ],
      },
    },
  }),
);

String _giphyReferenceResponse(Uri resourceUrl) => jsonEncode(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': <String, Object?>{
      'references': <String, Object?>{
        resourceUrl.toString(): <String, Object?>{
          'richObjectType': 'integration_giphy_gif',
          'richObject': <String, Object?>{
            'id': 'fixture-wave',
            'proxied_url':
                'https://cloud.example.invalid/index.php/apps/'
                'integration_giphy/gif/proxy',
            'images': <String, Object?>{
              'fixed_width': <String, Object?>{'width': '1', 'height': '1'},
            },
          },
        },
      },
    },
  },
});

final _animatedGif = base64Decode(
  'R0lGODlhAQABAIAAAAAAAP///yH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwA'
  'AAAAAQABAAACAkQBACH5BAAKAAAALAAAAAABAAEAAAICTAEAOw==',
);

String _giphyResponse() => jsonEncode(<String, Object?>{
  'ocs': <String, Object?>{
    'meta': <String, Object?>{
      'status': 'ok',
      'statuscode': 200,
      'message': 'OK',
    },
    'data': <String, Object?>{
      'entries': <Object?>[
        <String, Object?>{
          'thumbnailUrl':
              'https://cloud.example.invalid/apps/integration_giphy/gif/wave',
          'title': 'Wave',
          'subline': 'Fixture author',
          'resourceUrl': 'https://giphy.com/gifs/wave',
        },
      ],
      'cursor': 1,
    },
  },
});

/// The harness vault behind the gates a test may close on admission.
final class _GatedVault implements CredentialVault {
  _GatedVault(this._harness);

  final _ComposerHarness _harness;

  @override
  Future<String?> readAppPassword(String accountId) async {
    if (_harness.admissionHold.isNotEmpty) {
      await _harness.admissionHold.first.future;
    }
    return _harness.admissionRefused
        ? null
        : _harness.vault.readAppPassword(accountId);
  }

  @override
  Future<void> writeAppPassword(String accountId, String appPassword) =>
      _harness.vault.writeAppPassword(accountId, appPassword);

  @override
  Future<void> deleteAppPassword(String accountId) =>
      _harness.vault.deleteAppPassword(accountId);
}

final class _ControlledGiphyClient extends http.BaseClient {
  final requestStarted = Completer<void>();
  final _response = Completer<http.StreamedResponse>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!requestStarted.isCompleted) {
      requestStarted.complete();
    }
    return _response.future;
  }

  void complete(String body) {
    if (_response.isCompleted) {
      return;
    }
    _response.complete(
      http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode(body)),
        200,
        headers: const <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      ),
    );
  }

  @override
  void close() {
    if (closed) {
      return;
    }
    closed = true;
    if (!_response.isCompleted) {
      _response.completeError(
        http.ClientException('fixture connection cancelled'),
      );
    }
    super.close();
  }
}

Map<String, Object?> _conversationRoomJson() {
  final root =
      readFixtureJson(
            'conversation-list/fixtures/conversations-full.response.json',
          )!
          as Map<String, Object?>;
  final ocs = root['ocs']! as Map<String, Object?>;
  final rooms = ocs['data']! as List<Object?>;
  final room = Map<String, Object?>.from(rooms.first! as Map<String, Object?>);
  final lastMessage = Map<String, Object?>.from(
    room['lastMessage']! as Map<String, Object?>,
  );
  lastMessage['id'] = 109;
  room['lastMessage'] = lastMessage;
  return room;
}

Map<String, Object?> _sendResponse({
  required String referenceId,
  required String message,
}) {
  final response =
      readFixtureJson('chat-messages/fixtures/send-success.response.json')!
          as Map<String, Object?>;
  final ocs = response['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  data['referenceId'] = referenceId;
  data['message'] = message;
  return response;
}
