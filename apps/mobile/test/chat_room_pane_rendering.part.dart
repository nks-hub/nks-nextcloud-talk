part of 'chat_room_pane_test.dart';

void _registerChatRoomPaneRenderingTests() {
  testWidgets('phone screen and expanded pane share the same cached chat UI', (
    tester,
  ) async {
    await tester.pumpWidget(app(home: roomScreen()));
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
            'path': 'Talk/pixel.gif',
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
          home: roomScreen(),
          overrides: [
            mediaOverride,
            chatMediaRepositoryProvider.overrideWithValue(viewerRepository),
          ],
        ),
      );
      await tester.pump();
      await tester.pump();
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('chat-image-loading-20-0')).evaluate().isEmpty,
      );

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
      expect(find.byKey(const Key('chat-open-attachment-20-0')), findsNothing);
      expect(
        tester.getSize(find.byKey(const Key('chat-attachment-20-0'))).height,
        lessThanOrEqualTo(64),
      );
      await tester.ensureVisible(openImage);
      await tester.tap(openImage);
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
      // `a=1` keeps the aspect ratio; `a=0` makes Nextcloud crop the photo to
      // the requested box instead of fitting the whole image inside it.
      expect(openedPreview.queryParameters['a'], '1');
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

  testWidgets('image attachment uses one surface while thumbnail is loading', (
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
    expect(find.byKey(const Key('chat-open-attachment-30-0')), findsNothing);
    thumbnail.complete(
      ChatMediaImage(
        body: base64Decode(_onePixelGif),
        contentType: 'image/gif',
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('chat-image-loading-30-0')), findsOneWidget);
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-image-loading-30-0')).evaluate().isEmpty,
    );

    expect(find.byKey(const Key('chat-image-loading-30-0')), findsNothing);
    final openImage = find.byKey(const Key('chat-open-image-30-0'));
    expect(openImage, findsOneWidget);
    await tester.tap(openImage);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const Key('authenticated-image-viewer')), findsOneWidget);
    expect(openedPreview.queryParameters['fileId'], '88');
    expect(openedPreview.queryParameters['x'], '2048');
    expect(openedPreview.queryParameters['y'], '2048');
    expect(openedPreview.queryParameters['a'], '1');
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
    expect(find.byKey(const Key('chat-open-attachment-31-0')), findsNothing);

    await tester.tap(find.byKey(const Key('chat-image-retry-31-0')));
    await tester.pump();
    await tester.pump();

    expect(thumbnailAttempts, 2);
    expect(find.byKey(const Key('chat-image-31-0')), findsOneWidget);
    expect(find.byKey(const Key('chat-open-attachment-31-0')), findsNothing);
    final openImage = find.byKey(const Key('chat-open-image-31-0'));
    expect(openImage, findsOneWidget);
    await tester.tap(openImage);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('authenticated-image-viewer')), findsOneWidget);
  });

  testWidgets('generic attachments download authenticated originals', (
    tester,
  ) async {
    final opener = _RecordingAttachmentOpenAction();
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
        overrides: [
          chatAttachmentOpenActionFactoryProvider.overrideWithValue(
            (_) => opener,
          ),
        ],
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

    expect(opener.uris, <Uri>[
      Uri.parse(
        'https://cloud.example.invalid/remote.php/dav/files/'
        'fixture-user/Talk/report.pdf',
      ),
      Uri.parse(
        'https://cloud.example.invalid/remote.php/dav/files/'
        'fixture-user/Talk/disabled.gif',
      ),
    ]);
    expect(opener.contentTypes, ['application/pdf', 'image/gif']);
    expect(find.byKey(const Key('authenticated-image-viewer')), findsNothing);
  });

  testWidgets('unsafe DAV paths do not expose an attachment action', (
    tester,
  ) async {
    final opener = _RecordingAttachmentOpenAction();
    final message = _attachmentMessage(
      id: 34,
      fileId: 92,
      name: 'unsafe.txt',
      mimeType: 'text/plain',
      previewAvailable: 'no',
      link: '/index.php/f/92',
      path: 'Talk/../unsafe.txt',
    );

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
          chatAttachmentOpenActionFactoryProvider.overrideWithValue(
            (_) => opener,
          ),
        ],
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('chat-open-attachment-34-0')), findsNothing);
    expect(opener.uris, isEmpty);
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
      await tester.pumpWidget(app(locale: locale, home: roomScreen()));
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

    await tester.pumpWidget(app(home: roomScreen()));
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
      silent: false,
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
        home: roomScreen(),
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

    await tester.pumpWidget(app(home: roomScreen()));
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

    await tester.pumpWidget(app(home: roomScreen()));
    await tester.pump();

    expect(find.byKey(const Key('chat-voice-50')), findsOneWidget);
    expect(find.byKey(const Key('chat-voice-toggle-50')), findsOneWidget);
    expect(find.byKey(const Key('chat-open-attachment-50-0')), findsNothing);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.play_arrow_rounded)).semanticLabel,
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
          home: roomScreen(),
          overrides: [
            chatMessageActionsProfileProvider.overrideWith(
              (ref, key) async => _capabilityProfile(reply: true),
            ),
          ],
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
      expect(find.byKey(const Key('message-action-translate')), findsNothing);

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

  testWidgets('translation capability exposes the message dialog', (
    tester,
  ) async {
    await (database.update(database.cachedChatMessages)..where(
          (row) => row.accountId.equals(account.id) & row.messageId.equals(10),
        ))
        .write(
          CachedChatMessagesCompanion(
            rawJson: Value(
              jsonEncode(
                _messageJson(
                  id: 10,
                  actorId: 'someone-else',
                  actorDisplayName: 'Other person',
                  timestamp: 1724300000,
                  message: 'Cached hello',
                ),
              ),
            ),
          ),
        );
    await tester.pumpWidget(
      app(
        home: roomScreen(),
        overrides: [
          chatMessageActionsProfileProvider.overrideWith(
            (ref, key) async => _capabilityProfile(translation: true),
          ),
          messageTranslationServiceProvider.overrideWithValue(
            const _PendingTranslationService(),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(_capabilityProfile(translation: true).translation, isTrue);

    await tester.longPress(find.byKey(const Key('chat-message-target-10')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('message-action-translate')), findsOneWidget);

    await tester.tap(find.byKey(const Key('message-action-translate')));
    await tester.pump();
    expect(find.byKey(const Key('message-translation-dialog')), findsOneWidget);
    expect(
      find.byKey(const Key('translation-languages-loading')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

final class _PendingTranslationService implements MessageTranslationService {
  const _PendingTranslationService();

  @override
  Future<TranslationLanguagesResponse> languages({
    required String accountId,
    required String roomToken,
    Future<void>? abortTrigger,
  }) => Completer<TranslationLanguagesResponse>().future;

  @override
  Future<TranslateTextResponse> translate({
    required String accountId,
    required String roomToken,
    required String text,
    required String? fromLanguage,
    required String toLanguage,
    Future<void>? abortTrigger,
  }) => throw StateError('translation is not expected while loading');
}

final class _RecordingAttachmentOpenAction implements ChatAttachmentOpenAction {
  final List<Uri> uris = [];
  final List<String> contentTypes = [];

  @override
  Future<ChatAttachmentOpenResult> open({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
  }) async {
    uris.add(uri);
    contentTypes.add(expectedContentType);
    return ChatAttachmentOpenResult.opened;
  }
}
