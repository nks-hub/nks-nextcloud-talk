import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_message_content.dart';
import 'package:nextcloudtalk/features/chat/chat_room_pane.dart';
import 'package:nextcloudtalk/features/chat/outgoing_message_status.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;
  late StoredAccount account;
  late CachedConversation conversation;

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
    await database
        .into(database.cachedConversations)
        .insert(
          CachedConversationsCompanion.insert(
            accountId: account.id,
            token: 'rooma123',
            displayName: 'Synthetic room A',
            description: '',
            lastActivity: 1724300000,
            unreadMessages: 0,
            favorite: false,
            readOnly: const Value(0),
            roomType: const Value(2),
            roomName: const Value('synthetic-room-a'),
            objectType: const Value(''),
            avatarVersion: const Value(''),
            isCustomAvatar: const Value(false),
            rawJson: '{}',
          ),
        );
    conversation = await database
        .select(database.cachedConversations)
        .getSingle();
    await database
        .into(database.cachedChatMessages)
        .insert(
          CachedChatMessagesCompanion.insert(
            accountId: account.id,
            roomToken: conversation.token,
            messageId: 10,
            actorType: 'users',
            actorId: 'someone-else',
            actorDisplayName: 'Other person',
            timestamp: 1724300000,
            systemMessage: '',
            messageType: 'comment',
            referenceId: 'fixture-reference',
            displayText: 'Cached hello',
            deleted: false,
            rawJson: '{}',
          ),
        );
  });

  tearDown(() => database.close());

  Widget app({
    required Widget home,
    List<Override> overrides = const [],
    Locale locale = const Locale('en'),
  }) {
    return ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        // This suite covers cached rendering, threads and outbox state, not
        // attachment transport. Resolving the dependency as unavailable keeps
        // the media buttons in a settled state instead of an endless spinner.
        chatAttachmentDependenciesProvider.overrideWith(
          (ref, key) => Future<ChatAttachmentDependencies>.error(
            StateError('attachment dependencies are not wired in this suite'),
            StackTrace.empty,
          ),
        ),
        ...overrides,
      ],
      child: localizedTestApp(
        home: Builder(
          builder: (context) => Localizations.override(
            context: context,
            locale: locale,
            child: home,
          ),
        ),
      ),
    );
  }

  testWidgets('phone screen and expanded pane share the same cached chat UI', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('chat-room-screen')), findsOneWidget);
    expect(find.byKey(const Key('chat-room-pane')), findsOneWidget);
    expect(find.text('Cached hello'), findsOneWidget);
    expect(find.byKey(const Key('chat-composer')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'renders rich grouped timeline and opens an isolated thread pane',
    (tester) async {
      final semantics = tester.ensureSemantics();
      const firstTimestamp = 1724300000;
      final groupedMessage = _messageJson(
        id: 11,
        actorId: 'someone-else',
        actorDisplayName: 'Other person',
        timestamp: firstTimestamp + 60,
        message: 'Grouped follow-up',
      );
      final rootMessage = _messageJson(
        id: 20,
        actorId: 'rich-author',
        actorDisplayName: 'Rich author',
        timestamp: firstTimestamp + (2 * Duration.secondsPerDay),
        message:
            '**Rich text** {file} '
            '[Open docs](https://cloud.example.invalid/docs)',
        markdown: true,
        threadId: 20,
        isThread: true,
        threadReplies: 1,
        messageParameters: const {
          'file': {
            'type': 'file',
            'id': '77',
            'name': 'pixel.gif',
            'link': '/index.php/f/77',
            'mimetype': 'image/gif',
            'preview-available': 'yes',
          },
        },
        reactions: const {'👍': 2},
        reactionsSelf: const ['👍'],
      );
      final replyMessage = _messageJson(
        id: 21,
        actorId: 'reply-author',
        actorDisplayName: 'Reply author',
        timestamp: firstTimestamp + (2 * Duration.secondsPerDay) + 60,
        message: 'Thread reply',
        threadId: 20,
        parent: rootMessage,
      );
      final nestedReplyMessage = _messageJson(
        id: 22,
        actorId: 'nested-reply-author',
        actorDisplayName: 'Nested reply author',
        timestamp: firstTimestamp + (2 * Duration.secondsPerDay) + 120,
        message: 'Nested reply',
        threadId: 20,
        parent: _messageJson(
          id: 21,
          actorId: 'reply-author',
          actorDisplayName: 'Reply author',
          timestamp: firstTimestamp + (2 * Duration.secondsPerDay) + 60,
          message: 'Thread reply',
          threadId: 20,
        ),
      );
      await _insertCachedMessage(
        database,
        groupedMessage,
        displayText: 'Grouped follow-up',
      );
      await _insertCachedMessage(
        database,
        rootMessage,
        displayText: 'Rich text pixel.gif Open docs',
      );
      await _insertCachedMessage(
        database,
        replyMessage,
        displayText: 'Thread reply',
      );
      await _insertCachedMessage(
        database,
        nestedReplyMessage,
        displayText: 'Nested reply',
      );

      final mediaOverride = chatMediaProvider.overrideWith((ref, key) async {
        return ChatMediaImage(
          body: base64Decode(
            'R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==',
          ),
          contentType: 'image/gif',
        );
      });
      late Uri openedPreview;
      final viewerVault = MemoryCredentialVault()
        ..values[account.id] = 'fixture-viewer-password';
      final viewerRepository = ChatMediaRepository(
        viewerVault,
        client: MockClient((request) async {
          openedPreview = request.url;
          return http.Response.bytes(
            base64Decode('R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=='),
            200,
            headers: const <String, String>{'content-type': 'image/gif'},
          );
        }),
      );
      addTearDown(viewerRepository.close);
      await tester.pumpWidget(
        app(
          home: ChatRoomScreen(account: account, conversation: conversation),
          overrides: [
            mediaOverride,
            chatMediaRepositoryProvider.overrideWithValue(viewerRepository),
          ],
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('chat-rich-content-20')), findsOneWidget);
      expect(
        find.textContaining('Rich text', findRichText: true),
        findsWidgets,
      );
      expect(find.byKey(const Key('chat-image-20-0')), findsOneWidget);
      final openImage = find.byKey(const Key('chat-open-image-20-0'));
      expect(openImage, findsOneWidget);
      final openImageSemantics = tester
          .getSemantics(openImage)
          .getSemanticsData();
      expect(openImageSemantics.flagsCollection.isImage, isTrue);
      expect(openImageSemantics.flagsCollection.isButton, isTrue);
      expect(openImageSemantics.hasAction(ui.SemanticsAction.tap), isTrue);
      expect(tester.getSize(openImage).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(openImage).height, greaterThanOrEqualTo(48));
      final openAttachment = find.byKey(const Key('chat-open-attachment-20-0'));
      expect(openAttachment, findsOneWidget);
      expect(
        find.descendant(
          of: openAttachment,
          matching: find.byIcon(Icons.open_in_new_rounded),
        ),
        findsNothing,
      );
      await tester.ensureVisible(openAttachment);
      await tester.tap(openAttachment);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const Key('authenticated-image-viewer')),
        findsOneWidget,
      );
      expect(openedPreview.queryParameters['fileId'], '77');
      expect(openedPreview.queryParameters['x'], '2048');
      expect(openedPreview.queryParameters['y'], '2048');
      await tester.tap(find.byKey(const Key('authenticated-image-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-reaction-20-0')), findsOneWidget);
      expect(find.byKey(_dayKey(firstTimestamp)), findsOneWidget);
      expect(
        find.byKey(_dayKey(firstTimestamp + (2 * Duration.secondsPerDay))),
        findsOneWidget,
      );
      expect(find.byKey(const Key('chat-avatar-10')), findsNothing);
      expect(find.byKey(const Key('chat-avatar-11')), findsOneWidget);

      final openThread = find.byKey(const Key('chat-open-thread-20'));
      final linkNodes = find.semantics
          .byPredicate((node) {
            final data = node.getSemanticsData();
            return data.flagsCollection.isLink && data.label == 'Open docs';
          })
          .evaluate()
          .toList();
      expect(linkNodes, hasLength(1));
      expect(
        linkNodes.single.getSemanticsData().hasAction(ui.SemanticsAction.tap),
        isTrue,
      );
      final threadSemantics = tester.getSemantics(openThread);
      expect(
        threadSemantics.getSemanticsData().flagsCollection.isButton,
        isTrue,
      );
      expect(
        threadSemantics.getSemanticsData().hasAction(ui.SemanticsAction.tap),
        isTrue,
      );
      await tester.ensureVisible(openThread);
      await tester.pump();
      await tester.tap(openThread);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('chat-thread-screen-20')), findsOneWidget);
      expect(find.text('Thread reply'), findsNWidgets(2));
      expect(find.text('Nested reply'), findsOneWidget);
      expect(find.byKey(const Key('chat-reply-preview-21')), findsNothing);
      expect(find.byKey(const Key('chat-reply-preview-22')), findsOneWidget);
      expect(find.byKey(const Key('chat-open-thread-20')), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-thread-screen-20')), findsNothing);
      expect(find.byKey(const Key('chat-room-screen')), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('image attachment row opens viewer while thumbnail is loading', (
    tester,
  ) async {
    final thumbnail = Completer<ChatMediaImage?>();
    addTearDown(() {
      if (!thumbnail.isCompleted) {
        thumbnail.complete(null);
      }
    });
    final message = _attachmentMessage(
      id: 30,
      fileId: 88,
      name: 'pending.gif',
      mimeType: 'image/gif',
      previewAvailable: 'yes',
      link: '/index.php/f/88',
    );
    final mediaOverride = chatMediaProvider.overrideWith(
      (ref, key) => thumbnail.future,
    );
    late Uri openedPreview;
    vault.values[account.id] = 'fixture-viewer-password';
    final viewerRepository = ChatMediaRepository(
      vault,
      client: MockClient((request) async {
        openedPreview = request.url;
        return http.Response.bytes(
          base64Decode(_onePixelGif),
          200,
          headers: const <String, String>{'content-type': 'image/gif'},
        );
      }),
    );
    addTearDown(viewerRepository.close);

    await tester.pumpWidget(
      app(
        home: Scaffold(
          body: ChatMessageContent(
            account: account,
            message: message,
            fallbackText: '',
            foregroundColor: Colors.black,
          ),
        ),
        overrides: [
          mediaOverride,
          chatMediaRepositoryProvider.overrideWithValue(viewerRepository),
        ],
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('chat-image-loading-30-0')), findsOneWidget);
    final row = find.byKey(const Key('chat-open-attachment-30-0'));
    expect(row, findsOneWidget);
    await tester.tap(row);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const Key('authenticated-image-viewer')), findsOneWidget);
    expect(openedPreview.queryParameters['fileId'], '88');
    expect(openedPreview.queryParameters['x'], '2048');
    expect(openedPreview.queryParameters['y'], '2048');
  });

  testWidgets('failed image thumbnail retries and keeps internal viewer', (
    tester,
  ) async {
    var thumbnailAttempts = 0;
    final message = _attachmentMessage(
      id: 31,
      fileId: 89,
      name: 'retry.gif',
      mimeType: 'image/gif',
      previewAvailable: 'yes',
      link: '/index.php/f/89',
    );
    final mediaOverride = chatMediaProvider.overrideWith((ref, key) async {
      thumbnailAttempts++;
      if (thumbnailAttempts == 1) {
        throw StateError('synthetic preview failure');
      }
      return ChatMediaImage(
        body: base64Decode(_onePixelGif),
        contentType: 'image/gif',
      );
    });
    vault.values[account.id] = 'fixture-viewer-password';
    final viewerRepository = ChatMediaRepository(
      vault,
      client: MockClient((request) async {
        return http.Response.bytes(
          base64Decode(_onePixelGif),
          200,
          headers: const <String, String>{'content-type': 'image/gif'},
        );
      }),
    );
    addTearDown(viewerRepository.close);

    await tester.pumpWidget(
      app(
        home: Scaffold(
          body: ChatMessageContent(
            account: account,
            message: message,
            fallbackText: '',
            foregroundColor: Colors.black,
          ),
        ),
        overrides: [
          mediaOverride,
          chatMediaRepositoryProvider.overrideWithValue(viewerRepository),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('chat-image-error-31-0')), findsOneWidget);
    expect(thumbnailAttempts, 1);
    final attachmentRow = find.byKey(const Key('chat-open-attachment-31-0'));
    expect(
      find.descendant(
        of: attachmentRow,
        matching: find.byIcon(Icons.open_in_new_rounded),
      ),
      findsNothing,
    );
    await tester.tap(attachmentRow);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('authenticated-image-viewer')), findsOneWidget);
    await tester.tap(find.byKey(const Key('authenticated-image-close')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('chat-image-retry-31-0')));
    await tester.pump();
    await tester.pump();

    expect(thumbnailAttempts, 2);
    expect(find.byKey(const Key('chat-image-31-0')), findsOneWidget);
    expect(
      find.descendant(
        of: attachmentRow,
        matching: find.byIcon(Icons.open_in_new_rounded),
      ),
      findsNothing,
    );
    await tester.tap(attachmentRow);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('authenticated-image-viewer')), findsOneWidget);
  });

  testWidgets('unsupported attachment previews keep external fallback', (
    tester,
  ) async {
    const launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');
    final launched = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      launcherChannel,
      (call) async {
        expect(call.method, 'launch');
        final arguments = call.arguments! as Map<Object?, Object?>;
        launched.add(arguments['url']! as String);
        return true;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        launcherChannel,
        null,
      ),
    );
    final document = _attachmentMessage(
      id: 32,
      fileId: 90,
      name: 'report.pdf',
      mimeType: 'application/pdf',
      previewAvailable: 'yes',
      link: '/remote.php/dav/files/fixture-user/report.pdf',
    );
    final previewDisabledImage = _attachmentMessage(
      id: 33,
      fileId: 91,
      name: 'disabled.gif',
      mimeType: 'image/gif',
      previewAvailable: 'no',
      link: '/index.php/f/91',
    );

    await tester.pumpWidget(
      app(
        home: Scaffold(
          body: Flex(
            direction: Axis.vertical,
            children: [
              ChatMessageContent(
                account: account,
                message: document,
                fallbackText: '',
                foregroundColor: Colors.black,
              ),
              ChatMessageContent(
                account: account,
                message: previewDisabledImage,
                fallbackText: '',
                foregroundColor: Colors.black,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    for (final messageId in const [32, 33]) {
      final row = find.byKey(Key('chat-open-attachment-$messageId-0'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.byIcon(Icons.open_in_new_rounded),
        ),
        findsOneWidget,
      );
      await tester.tap(row);
      await tester.pump();
    }
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    expect(launched, <String>[
      'https://cloud.example.invalid/remote.php/dav/files/fixture-user/report.pdf',
      'https://cloud.example.invalid/index.php/f/91',
    ]);
    expect(find.byKey(const Key('authenticated-image-viewer')), findsNothing);
  });

  testWidgets('localizes today, yesterday, and older day separators', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await database.delete(database.cachedChatMessages).go();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 12);
    final yesterday = DateTime(now.year, now.month, now.day - 1, 12);
    final older = DateTime(now.year, now.month, now.day - 7, 12);
    final days = <({int id, DateTime date, String text})>[
      (id: 101, date: older, text: 'Older message'),
      (id: 102, date: yesterday, text: 'Yesterday message'),
      (id: 103, date: today, text: 'Today message'),
    ];
    for (final day in days) {
      await _insertCachedMessage(
        database,
        _messageJson(
          id: day.id,
          actorId: 'date-author',
          actorDisplayName: 'Date author',
          timestamp: _unixSeconds(day.date),
          message: day.text,
        ),
        displayText: day.text,
      );
    }

    for (final locale in const [Locale('en'), Locale('cs')]) {
      await tester.pumpWidget(
        app(
          locale: locale,
          home: ChatRoomScreen(account: account, conversation: conversation),
        ),
      );
      await tester.pump();
      await tester.pump();

      final olderSeparator = find.byKey(_dayKey(_unixSeconds(older)));
      final olderContext = tester.element(olderSeparator);
      final expectedOlder = MaterialLocalizations.of(
        olderContext,
      ).formatMediumDate(older);
      final expectedToday = locale.languageCode == 'cs' ? 'Dnes' : 'Today';
      expect(find.text(expectedToday), findsOneWidget);
      expect(
        find.text(locale.languageCode == 'cs' ? 'Včera' : 'Yesterday'),
        findsOneWidget,
      );
      expect(find.text(expectedOlder), findsOneWidget);
      final todayHeaders = find.semantics
          .byLabel(expectedToday)
          .evaluate()
          .toList();
      expect(todayHeaders, hasLength(1));
      expect(
        todayHeaders.single.getSemanticsData().flagsCollection.isHeader,
        isTrue,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    }
    semantics.dispose();
  });

  testWidgets('opens a valid thread before it has replies', (tester) async {
    final rootMessage = _messageJson(
      id: 30,
      actorId: 'thread-author',
      actorDisplayName: 'Thread author',
      timestamp: 1724300120,
      message: 'Fresh thread root',
      threadId: 30,
      isThread: true,
    );
    await _insertCachedMessage(
      database,
      rootMessage,
      displayText: 'Fresh thread root',
    );

    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();

    final openThread = find.byKey(const Key('chat-open-thread-30'));
    await tester.ensureVisible(openThread);
    await tester.pump();
    expect(find.text('Open thread'), findsOneWidget);
    await tester.tap(openThread);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat-thread-screen-30')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a confirmed outgoing message shows its server-backed state', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final outgoing = _messageJson(
      id: 40,
      actorId: 'fixture-user',
      actorDisplayName: 'Fixture user',
      timestamp: 1724300100,
      message: 'Confirmed outgoing',
    );
    await _insertCachedMessage(
      database,
      outgoing,
      displayText: 'Confirmed outgoing',
    );
    final operation = StoredTextSendOperation(
      accountId: account.id,
      operationId: 'operation-read',
      roomToken: conversation.token,
      referenceId: 'reference-40',
      message: 'Confirmed outgoing',
      replayContractRevision: 'fixture-r1',
      enqueueSequence: 1,
      outboxState: 'completed',
      attemptCount: 1,
      messageIdsJson: '[40]',
      duplicateRiskAcknowledged: false,
      createdAtMillis: 1,
      updatedAtMillis: 1,
    );

    await tester.pumpWidget(
      app(
        overrides: [
          outgoingMessageStatusesProvider.overrideWith(
            (ref, key) => Stream.value(<OutgoingMessageStatus>[
              OutgoingMessageStatus(
                operation: operation,
                messageId: 40,
                state: OutgoingMessageDeliveryState.read,
                confirmationAmbiguous: false,
              ),
            ]),
          ),
        ],
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('chat-delivery-40')), findsOneWidget);
    expect(
      find.byIcon(Icons.done_all_rounded),
      findsOneWidget,
      reason: 'read uses the double check, sent uses the single one',
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.done_all_rounded)).semanticLabel,
      'Read',
      reason: 'the mark must not be colour-only for a screen reader',
    );
    expect(
      find.byKey(const Key('chat-delivery-10')),
      findsNothing,
      reason: 'an incoming message never carries a delivery mark',
    );

    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('an own attachment also shows its delivery state', (
    tester,
  ) async {
    final attachment = _messageJson(
      id: 60,
      actorId: 'fixture-user',
      actorDisplayName: 'Fixture user',
      timestamp: 1724300300,
      message: '{file}',
      messageParameters: const {
        'file': {
          'type': 'file',
          'id': '99',
          'name': 'shared.png',
          'link': '/index.php/f/99',
          'path': 'Talk/shared.png',
          'mimetype': 'image/png',
          'preview-available': 'no',
        },
      },
    );
    await _insertCachedMessage(database, attachment, displayText: 'shared.png');
    await database
        .into(database.chatScopes)
        .insert(
          ChatScopesCompanion.insert(
            accountId: account.id,
            roomToken: conversation.token,
            scopeKey: 'root',
            historyCursor: '60',
            futureCursor: '60',
            lastCommonRead: '60',
            lastReadMessage: 60,
            unreadMessages: 0,
            hasHistory: false,
            futureConverged: true,
            blocksJson: '[["60","60"]]',
          ),
        );

    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const Key('chat-delivery-60')),
      findsOneWidget,
      reason: 'an attachment never passes through the text outbox',
    );
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
    expect(
      find.byKey(const Key('chat-delivery-10')),
      findsNothing,
      reason: 'an incoming message never carries a delivery mark',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a voice message renders a player instead of a file chip', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final voice = _messageJson(
      id: 50,
      actorId: 'someone-else',
      actorDisplayName: 'Other person',
      timestamp: 1724300200,
      message: '{file}',
      messageParameters: const {
        'file': {
          'type': 'file',
          'id': '91',
          'name': 'voice-message.wav',
          'link': '/index.php/f/91',
          'path': 'Talk/voice-message.wav',
          'mimetype': 'audio/wav',
          'preview-available': 'no',
        },
      },
    );
    await _insertCachedMessage(
      database,
      voice,
      displayText: 'voice-message.wav',
    );

    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('chat-voice-50')), findsOneWidget);
    expect(find.byKey(const Key('chat-voice-toggle-50')), findsOneWidget);
    expect(
      tester
          .widget<Icon>(find.byIcon(Icons.play_arrow_rounded))
          .semanticLabel,
      'Play voice message',
    );

    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'long press opens the message actions menu and can start a reply',
    (tester) async {
      await tester.pumpWidget(
        app(
          home: ChatRoomScreen(account: account, conversation: conversation),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('chat-reply-banner')), findsNothing);

      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await tester.pumpAndSettle();

      // Message 10 belongs to someone else and this suite never wires a
      // message-actions capability profile, so only account-agnostic actions
      // (reply, copy) are offered.
      expect(find.byKey(const Key('message-action-reply')), findsOneWidget);
      expect(find.byKey(const Key('message-action-copy')), findsOneWidget);
      expect(find.byKey(const Key('message-action-edit')), findsNothing);
      expect(find.byKey(const Key('message-action-delete')), findsNothing);
      expect(find.byKey(const Key('message-action-react')), findsNothing);

      await tester.tap(find.byKey(const Key('message-action-reply')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('chat-reply-banner')), findsOneWidget);
      expect(find.text('Replying to Other person'), findsOneWidget);
      expect(find.text('Cached hello'), findsNWidgets(2));

      await tester.tap(find.byKey(const Key('chat-cancel-reply')));
      await tester.pump();

      expect(find.byKey(const Key('chat-reply-banner')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('composer text survives losing the pane', (tester) async {
    // A send can be refused before the outbox admits it, for example while
    // offline, so the typed text must not depend on the widget staying alive.
    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();

    await tester.enterText(
      find.byKey(const Key('chat-composer')),
      'Draft that must not be lost',
    );
    await tester.pump(const Duration(milliseconds: 600));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Draft that must not be lost'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('chat header and composer remain accessible at 200% text', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(900, 800),
            textScaler: TextScaler.linear(2),
          ),
          child: ChatRoomPane(
            account: account,
            conversation: conversation.copyWith(
              description: 'Accessible room description',
            ),
            showHeader: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.getSize(find.byKey(const Key('chat-room-header'))).height,
      greaterThan(72),
    );
    await tester.enterText(
      find.byKey(const Key('chat-composer')),
      'Draft message',
    );
    await tester.pump();
    expect(find.text('Write a message'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('composer exposes one named editable semantics node', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();

    final composer = find.byKey(const Key('chat-composer'));
    final composerNodes = find.semantics
        .byPredicate(
          (node) => node.getSemanticsData().flagsCollection.isTextField,
        )
        .evaluate()
        .toList();
    expect(composerNodes, hasLength(1));

    final namedComposerNodes = find.semantics
        .byLabel('Write a message')
        .evaluate()
        .where((node) => node.getSemanticsData().flagsCollection.isTextField)
        .toList();
    expect(namedComposerNodes, hasLength(1));
    expect(namedComposerNodes.single, same(composerNodes.single));

    final data = namedComposerNodes.single.getSemanticsData();
    expect(data.label, 'Write a message');
    expect(data.flagsCollection.isTextField, isTrue);
    expect(data.flagsCollection.isReadOnly, isFalse);
    expect(data.hasAction(ui.SemanticsAction.tap), isTrue);

    await tester.tap(composer);
    await tester.pump();
    expect(
      namedComposerNodes.single.getSemanticsData().hasAction(
        ui.SemanticsAction.setText,
      ),
      isTrue,
    );

    await tester.enterText(composer, 'Accessible draft');
    await tester.pump();
    expect(
      namedComposerNodes.single.getSemanticsData().value,
      'Accessible draft',
    );
    expect(
      find.semantics
          .byLabel('Write a message')
          .evaluate()
          .where((node) => node.getSemanticsData().flagsCollection.isTextField),
      hasLength(1),
    );

    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('incoming avatar is decorative beside its author label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();

    final avatarSemantics = tester
        .getSemantics(find.byKey(const Key('chat-avatar-10')))
        .getSemanticsData();
    expect(avatarSemantics.flagsCollection.isImage, isFalse);
    expect(avatarSemantics.label, isEmpty);
    expect(
      tester
          .getSemantics(find.byKey(const Key('chat-message-semantics-10')))
          .getSemanticsData()
          .label,
      'Other person',
    );

    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'every grouped incoming and outgoing message exposes its author',
    (tester) async {
      final semantics = tester.ensureSemantics();
      const firstTimestamp = 1724300000;
      await _insertCachedMessage(
        database,
        _messageJson(
          id: 11,
          actorId: 'someone-else',
          actorDisplayName: 'Other person',
          timestamp: firstTimestamp + 60,
          message: 'Grouped follow-up',
        ),
        displayText: 'Grouped follow-up',
      );
      await _insertCachedMessage(
        database,
        _messageJson(
          id: 12,
          actorId: account.loginName,
          actorDisplayName: 'Fixture User',
          timestamp: firstTimestamp + 120,
          message: 'Outgoing follow-up',
        ),
        displayText: 'Outgoing follow-up',
      );

      await tester.pumpWidget(
        app(
          home: ChatRoomScreen(account: account, conversation: conversation),
        ),
      );
      await tester.pump();

      expect(
        tester
            .getSemantics(find.byKey(const Key('chat-message-semantics-10')))
            .getSemanticsData()
            .label,
        'Other person',
      );
      expect(
        tester
            .getSemantics(find.byKey(const Key('chat-message-semantics-11')))
            .getSemanticsData()
            .label,
        'Other person',
      );
      expect(
        tester
            .getSemantics(find.byKey(const Key('chat-message-semantics-12')))
            .getSemanticsData()
            .label,
        'Fixture User',
      );

      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('ambiguous send requires duplicate-risk confirmation', (
    tester,
  ) async {
    await database
        .into(database.textSendOperations)
        .insert(
          TextSendOperationsCompanion.insert(
            accountId: account.id,
            operationId: 'operation-a',
            roomToken: conversation.token,
            referenceId: 'reference-a',
            message: 'Possibly $_giphyResourceUrl sent',
            replayContractRevision: 'fixture-revision',
            enqueueSequence: 1,
            outboxState: 'awaitingConfirmation',
            attemptCount: 1,
            messageIdsJson: '[]',
            duplicateRiskAcknowledged: false,
            createdAtMillis: 1,
            updatedAtMillis: 1,
          ),
        );

    await tester.pumpWidget(
      app(
        home: ChatRoomPane(account: account, conversation: conversation),
      ),
    );
    await tester.pump();
    expect(find.text('Possibly GIF sent'), findsOneWidget);
    expect(find.textContaining(_giphyResourceUrl), findsNothing);
    await tester.tap(find.byKey(const Key('chat-resend-operation-a')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('duplicate-risk-dialog')), findsOneWidget);
    expect(find.byKey(const Key('confirm-duplicate-risk')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('cancelling a queued send clears the outbox row and bubble', (
    tester,
  ) async {
    await _insertPendingOperation(
      database,
      account,
      conversation,
      operationId: 'operation-q',
      outboxState: 'queued',
      message: 'Queued fixture text',
    );

    await tester.pumpWidget(
      app(
        home: ChatRoomPane(account: account, conversation: conversation),
      ),
    );
    await tester.pump();
    expect(find.text('Queued fixture text'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-cancel-operation-q')));
    await _pumpUntil(
      tester,
      () => find.text('Queued fixture text').evaluate().isEmpty,
    );

    expect(
      await (database.select(database.textSendOperations)
            ..where((operation) => operation.operationId.equals('operation-q')))
          .getSingleOrNull(),
      isNull,
    );
    expect(find.byKey(const Key('chat-cancel-operation-q')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('cancelling an ambiguous send keeps it and says why', (
    tester,
  ) async {
    await _insertPendingOperation(
      database,
      account,
      conversation,
      operationId: 'operation-x',
      outboxState: 'awaitingConfirmation',
      message: 'Maybe sent fixture text',
      attemptCount: 1,
    );

    // The refusal is a snackbar, so this needs the screen that owns a
    // Scaffold rather than the bare pane.
    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('chat-cancel-operation-x')));
    await _pumpUntil(
      tester,
      () => find
          .text(
            'This message may already have reached the server, so it can no '
            'longer be cancelled.',
          )
          .evaluate()
          .isNotEmpty,
    );

    final row =
        await (database.select(database.textSendOperations)..where(
              (operation) => operation.operationId.equals('operation-x'),
            ))
            .getSingleOrNull();
    expect(row?.outboxState, 'awaitingConfirmation');
    expect(find.text('Maybe sent fixture text'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'the actions menu offers edit, delete and react only when both '
    'ownership and capability allow it',
    (tester) async {
      await _insertCachedMessage(
        database,
        _messageJson(
          id: 70,
          actorId: account.loginName,
          actorDisplayName: 'Fixture User',
          timestamp: 1724300400,
          message: 'My own message',
        ),
        displayText: 'My own message',
      );

      await tester.pumpWidget(
        app(
          home: ChatRoomScreen(account: account, conversation: conversation),
          overrides: [
            chatMessageActionsProfileProvider.overrideWith(
              (ref, key) async => _capabilityProfile(
                edit: true,
                delete: true,
                react: true,
              ),
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.longPress(find.byKey(const Key('chat-message-target-70')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('message-action-reply')), findsOneWidget);
      expect(find.byKey(const Key('message-action-copy')), findsOneWidget);
      expect(find.byKey(const Key('message-action-edit')), findsOneWidget);
      expect(find.byKey(const Key('message-action-delete')), findsOneWidget);
      expect(find.byKey(const Key('message-action-react')), findsOneWidget);
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();

      // Message 10 belongs to someone else: edit/delete stay hidden even
      // though this account is fully capable of both.
      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('message-action-edit')), findsNothing);
      expect(find.byKey(const Key('message-action-delete')), findsNothing);
      expect(find.byKey(const Key('message-action-react')), findsOneWidget);
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'without a resolved capability profile only reply and copy are offered',
    (tester) async {
      await tester.pumpWidget(
        app(
          home: ChatRoomScreen(account: account, conversation: conversation),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.longPress(find.byKey(const Key('chat-message-target-10')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('message-action-reply')), findsOneWidget);
      expect(find.byKey(const Key('message-action-copy')), findsOneWidget);
      expect(find.byKey(const Key('message-action-edit')), findsNothing);
      expect(find.byKey(const Key('message-action-delete')), findsNothing);
      expect(find.byKey(const Key('message-action-react')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('copy puts the message text on the clipboard', (tester) async {
    final copiedTexts = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final arguments = Map<Object?, Object?>.from(
            call.arguments as Map<Object?, Object?>,
          );
          copiedTexts.add(arguments['text'] as String?);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      app(home: ChatRoomScreen(account: account, conversation: conversation)),
    );
    await tester.pump();

    await tester.longPress(find.byKey(const Key('chat-message-target-10')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('message-action-copy')));
    await tester.pumpAndSettle();

    expect(copiedTexts, ['Cached hello']);
    expect(find.text('Copied to clipboard'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('the edit dialog survives its own closing transition', (
    tester,
  ) async {
    // Regression: the controller used to be disposed as soon as showDialog
    // returned, while the text field was still mounted for the exit
    // animation. That tripped the framework assertion `_dependents.isEmpty`
    // and crashed the running app, not just the test.
    await _insertCachedMessage(
      database,
      _messageJson(
        id: 91,
        actorId: account.loginName,
        actorDisplayName: 'Fixture User',
        timestamp: 1724300700,
        message: 'Before edit',
      ),
      displayText: 'Before edit',
    );

    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
        overrides: [
          chatMessageActionsProfileProvider.overrideWith(
            (ref, key) async => _capabilityProfile(edit: true),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.byKey(const Key('chat-message-target-91')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('message-action-edit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('edit-message-dialog')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('edit-message-field')),
      'After edit',
    );
    await tester.tap(find.byKey(const Key('confirm-edit-message')));

    // Pump the whole closing transition frame by frame; the crash happened
    // while the dialog was still on its way out.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('edit-message-dialog')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('cancelling delete leaves the message untouched', (
    tester,
  ) async {
    await _insertCachedMessage(
      database,
      _messageJson(
        id: 90,
        actorId: account.loginName,
        actorDisplayName: 'Fixture User',
        timestamp: 1724300600,
        message: 'Editable text',
      ),
      displayText: 'Editable text',
    );

    await tester.pumpWidget(
      app(
        home: ChatRoomScreen(account: account, conversation: conversation),
        overrides: [
          // Cancelling never reaches the network, so the menu only needs a
          // capability profile pinned; the default unmocked API (as used by
          // every other test in this file) is left untouched.
          chatMessageActionsProfileProvider.overrideWith(
            (ref, key) async => _capabilityProfile(delete: true),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.byKey(const Key('chat-message-target-90')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('message-action-delete')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('delete-message-dialog')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Editable text'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'shows the load-older control while history remains, and hides it '
    'once the scope reports it is exhausted',
    (tester) async {
      await database
          .into(database.chatScopes)
          .insert(
            ChatScopesCompanion.insert(
              accountId: account.id,
              roomToken: conversation.token,
              scopeKey: 'root',
              historyCursor: '10',
              futureCursor: '10',
              lastCommonRead: '10',
              lastReadMessage: 0,
              unreadMessages: 0,
              hasHistory: true,
              futureConverged: true,
              blocksJson: '[["10","10"]]',
            ),
          );

      await tester.pumpWidget(
        app(
          home: ChatRoomScreen(account: account, conversation: conversation),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('chat-load-older')), findsOneWidget);
      expect(find.text('Load older messages'), findsOneWidget);

      // A real page fetch that flips `hasHistory` to false is already
      // covered end-to-end by chat_service_integration_test.dart and the
      // talk_protocol merge fixtures; this only has to prove the pane reacts
      // to that scope change, so it writes the resulting state directly.
      await (database.update(database.chatScopes)..where(
            (scope) =>
                scope.accountId.equals(account.id) &
                scope.roomToken.equals(conversation.token) &
                scope.scopeKey.equals('root'),
          ))
          .write(const ChatScopesCompanion(hasHistory: Value(false)));
      await tester.pump();

      expect(find.byKey(const Key('chat-load-older')), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'tapping load older surfaces a retry-able error without leaving the '
    'control stuck spinning',
    (tester) async {
      await database
          .into(database.chatScopes)
          .insert(
            ChatScopesCompanion.insert(
              accountId: account.id,
              roomToken: conversation.token,
              scopeKey: 'root',
              historyCursor: '10',
              futureCursor: '10',
              lastCommonRead: '10',
              lastReadMessage: 0,
              unreadMessages: 0,
              hasHistory: true,
              futureConverged: true,
              blocksJson: '[["10","10"]]',
            ),
          );

      await tester.pumpWidget(
        app(
          home: ChatRoomScreen(account: account, conversation: conversation),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('chat-load-older')), findsOneWidget);

      // No app password is stored for this account (the vault is empty, as
      // in every other test in this file), so the real ChatService fails
      // fast with a credential error instead of reaching the network -
      // deterministic, and it exercises the exact catch/retry path a real
      // failed page fetch would take.
      await tester.tap(find.byKey(const Key('chat-load-older')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('retry-chat-sync')), findsOneWidget);
      // hasHistory was never touched by the failed attempt, so the control
      // must still be there, enabled, ready for the user to retry directly.
      final loadOlderButton = tester.widget<TextButton>(
        find.descendant(
          of: find.byKey(const Key('chat-load-older')),
          matching: find.byType(TextButton),
        ),
      );
      expect(loadOlderButton.onPressed != null, isTrue);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('retry-chat-sync')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'keeps two disjoint cached ranges visibly separated instead of '
    'gluing them into one history',
    (tester) async {
      await _insertCachedMessage(
        database,
        _messageJson(
          id: 20,
          actorId: 'someone-else',
          actorDisplayName: 'Other person',
          timestamp: 1724300100,
          message: 'Older block message',
        ),
        displayText: 'Older block message',
      );
      await _insertCachedMessage(
        database,
        _messageJson(
          id: 50,
          actorId: 'someone-else',
          actorDisplayName: 'Other person',
          timestamp: 1724300200,
          message: 'Boundary before the gap',
        ),
        displayText: 'Boundary before the gap',
      );
      // Falls inside the gap (51-69): never confirmed by a fetch, so it
      // must never render even though the row happens to be cached, for
      // example a leftover from a state the client no longer stands behind.
      await _insertCachedMessage(
        database,
        _messageJson(
          id: 60,
          actorId: 'someone-else',
          actorDisplayName: 'Other person',
          timestamp: 1724300250,
          message: 'Ghost message inside the gap',
        ),
        displayText: 'Ghost message inside the gap',
      );
      await _insertCachedMessage(
        database,
        _messageJson(
          id: 80,
          actorId: 'someone-else',
          actorDisplayName: 'Other person',
          timestamp: 1724300300,
          message: 'First message after the gap',
        ),
        displayText: 'First message after the gap',
      );
      await database
          .into(database.chatScopes)
          .insert(
            ChatScopesCompanion.insert(
              accountId: account.id,
              roomToken: conversation.token,
              scopeKey: 'root',
              historyCursor: '10',
              futureCursor: '100',
              lastCommonRead: '10',
              lastReadMessage: 0,
              unreadMessages: 0,
              hasHistory: false,
              futureConverged: true,
              blocksJson: '[["10","50"],["70","100"]]',
            ),
          );

      await tester.pumpWidget(
        app(
          home: ChatRoomScreen(account: account, conversation: conversation),
        ),
      );
      await tester.pump();

      expect(find.text('Cached hello'), findsOneWidget);
      expect(find.text('Older block message'), findsOneWidget);
      expect(find.text('Boundary before the gap'), findsOneWidget);
      expect(find.text('First message after the gap'), findsOneWidget);
      expect(find.text('Ghost message inside the gap'), findsNothing);
      expect(find.byKey(const Key('chat-history-gap')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}

const _giphyResourceUrl = 'https://giphy.com/gifs/waving-cat-fixture123';
const _onePixelGif = 'R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==';

ChatMessage _attachmentMessage({
  required int id,
  required int fileId,
  required String name,
  required String mimeType,
  required Object previewAvailable,
  required String link,
}) {
  return ChatMessage.fromJson(
    _messageJson(
      id: id,
      actorId: 'attachment-author',
      actorDisplayName: 'Attachment author',
      timestamp: 1767225600 + id,
      message: '{file}',
      markdown: true,
      messageParameters: <String, Object?>{
        'file': <String, Object?>{
          'type': 'file',
          'id': '$fileId',
          'name': name,
          'link': link,
          'mimetype': mimeType,
          'preview-available': previewAvailable,
        },
      },
    ),
  );
}

Map<String, Object?> _messageJson({
  required int id,
  required String actorId,
  required String actorDisplayName,
  required int timestamp,
  required String message,
  bool markdown = false,
  int? threadId,
  bool isThread = false,
  int threadReplies = 0,
  Map<String, Object?> messageParameters = const {},
  Map<String, Object?> reactions = const {},
  List<Object?> reactionsSelf = const [],
  Map<String, Object?>? parent,
}) {
  return <String, Object?>{
    'id': id,
    'token': 'rooma123',
    'actorType': 'users',
    'actorId': actorId,
    'actorDisplayName': actorDisplayName,
    'timestamp': timestamp,
    'systemMessage': '',
    'messageType': 'comment',
    'isReplyable': true,
    'referenceId': 'reference-$id',
    'message': message,
    'messageParameters': messageParameters,
    'markdown': markdown,
    'reactions': reactions,
    'reactionsSelf': reactionsSelf,
    'deleted': null,
    'threadId': threadId,
    'isThread': isThread,
    'threadTitle': isThread ? 'Fixture thread' : null,
    'threadReplies': threadReplies,
    'parent': ?parent,
  };
}

Future<void> _insertCachedMessage(
  AppDatabase database,
  Map<String, Object?> wire, {
  required String displayText,
}) {
  return database
      .into(database.cachedChatMessages)
      .insert(
        CachedChatMessagesCompanion.insert(
          accountId: 'account-a',
          roomToken: wire['token']! as String,
          messageId: wire['id']! as int,
          actorType: wire['actorType']! as String,
          actorId: wire['actorId']! as String,
          actorDisplayName: wire['actorDisplayName']! as String,
          timestamp: wire['timestamp']! as int,
          systemMessage: wire['systemMessage']! as String,
          messageType: wire['messageType']! as String,
          referenceId: wire['referenceId']! as String,
          displayText: displayText,
          deleted: wire['deleted'] == true,
          threadId: Value(wire['threadId'] as int?),
          rawJson: jsonEncode(wire),
        ),
      );
}

Future<void> _insertPendingOperation(
  AppDatabase database,
  StoredAccount account,
  CachedConversation conversation, {
  required String operationId,
  required String outboxState,
  required String message,
  int attemptCount = 0,
}) {
  return database
      .into(database.textSendOperations)
      .insert(
        TextSendOperationsCompanion.insert(
          accountId: account.id,
          operationId: operationId,
          roomToken: conversation.token,
          referenceId: 'reference-$operationId',
          message: message,
          replayContractRevision: 'fixture-revision',
          enqueueSequence: 1,
          outboxState: outboxState,
          attemptCount: attemptCount,
          messageIdsJson: '[]',
          duplicateRiskAcknowledged: false,
          createdAtMillis: 1,
          updatedAtMillis: 1,
        ),
      );
}

/// Pumps until [condition] holds, letting the real database work in between
/// run through [WidgetTester.runAsync]; the fake clock alone never drives it.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxAttempts = 100,
}) async {
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    if (condition()) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  fail('Condition was not reached');
}

Key _dayKey(int timestamp) {
  final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000).toLocal();
  return Key('chat-day-${date.year}-${date.month}-${date.day}');
}

int _unixSeconds(DateTime value) =>
    value.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;

RichChatCapabilityProfile _capabilityProfile({
  bool edit = false,
  bool delete = false,
  bool react = false,
}) {
  return RichChatCapabilityProfile.fromTalkFeatures(
    talkFeatures: <String>[
      'chat-v2',
      if (edit) 'edit-messages',
      if (delete) 'delete-messages',
      if (react) 'reactions',
    ],
    talkLocalFeatures: const <String>[],
    federated: false,
    moderator: false,
    participantPermissions: 0,
  );
}

