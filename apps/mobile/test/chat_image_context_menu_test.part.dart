part of 'chat_room_pane_test.dart';

/// Right click over a picture, across incoming and outgoing bubbles, with and
/// without a caption, as a single picture and inside an album.
void _registerImageContextMenuMatrixTests() {
  for (final outgoing in [false, true]) {
    for (final caption in [false, true]) {
      final who = outgoing ? 'outgoing' : 'incoming';
      final text = caption ? 'with caption' : 'without caption';
      for (final album in [false, true]) {
        testWidgets(
          'right click on a ${album ? 'album' : 'single'} picture in an '
          '$who bubble $text opens the picture menu',
          (tester) async {
            final preview = await _solidPreview(tester, 120, 80);
            final ids = album ? [100, 101, 102, 103] : [100];
            for (final id in ids) {
              final wire = album ? _albumWire(id - 100) : _layoutImageWire(id);
              if (outgoing) wire['actorId'] = account.loginName;
              if (caption && id == ids.first) wire['message'] = 'Nice photo';
              await _insertCachedMessage(
                database,
                wire,
                displayText: caption && id == ids.first
                    ? 'Nice photo'
                    : 'Photo',
              );
            }
            final fakes = _PictureMenuFakes(preview.body);
            await tester.pumpWidget(
              app(
                home: roomScreen(),
                overrides: [
                  chatMediaProvider.overrideWith((ref, key) async => preview),
                  ...fakes.overrides,
                ],
              ),
            );
            final target = album ? 102 : 100;
            final image = find.byKey(Key('chat-image-$target-0'));
            await _pumpUntil(
              tester,
              () =>
                  image.hitTestable().evaluate().isNotEmpty &&
                  find
                      .byKey(Key('chat-image-loading-$target-0'))
                      .evaluate()
                      .isEmpty,
            );

            await _quickRightClick(tester, tester.getCenter(image));

            expect(find.byType(BottomSheet), findsNothing);
            for (final name in [
              'save-image',
              'open-image',
              'open-file',
              'forward',
            ]) {
              expect(
                find.byKey(Key('message-action-$name')),
                findsOneWidget,
                reason: name,
              );
            }
            expect(find.byType(PopupMenuDivider), findsOneWidget);

            await tester.tap(find.byKey(const Key('message-action-save-image')));
            await tester.pumpAndSettle();
            expect(fakes.files.saved, ['image.png']);

            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(milliseconds: 1));
          },
          variant: TargetPlatformVariant.desktop(),
        );
      }
    }
  }
}

/// Right click inside the opened viewer or gallery, reached from a bubble.
void _registerOpenedViewerMenuTests() {
  testWidgets('right click in the opened picture offers its commands', (
    tester,
  ) async {
    final preview = await _solidPreview(tester, 120, 80);
    await _insertCachedMessage(
      database,
      _layoutImageWire(100),
      displayText: 'Photo',
    );
    final fakes = _PictureMenuFakes(preview.body);
    await tester.pumpWidget(
      app(
        home: roomScreen(),
        overrides: [
          chatMediaProvider.overrideWith((ref, key) async => preview),
          ...fakes.overrides,
        ],
      ),
    );
    final image = find.byKey(const Key('chat-image-100-0'));
    await _pumpUntil(
      tester,
      () =>
          image.hitTestable().evaluate().isNotEmpty &&
          find.byKey(const Key('chat-image-loading-100-0')).evaluate().isEmpty,
    );
    await tester.tap(image);
    final viewer = find.byKey(const Key('authenticated-image-fullscreen'));
    await _pumpUntil(tester, () => viewer.evaluate().isNotEmpty);
    await tester.pumpAndSettle();

    Finder action(String name) => find.byKey(Key('message-action-$name'));
    await _rightClick(tester, tester.getCenter(viewer));
    for (final name in ['save-image', 'open-file', 'forward']) {
      expect(action(name), findsOneWidget, reason: name);
    }
    await tester.tap(action('open-file'));
    await tester.pumpAndSettle();
    expect(fakes.opener.uris.single.path, endsWith('/Talk/image.png'));

    await _rightClick(tester, tester.getCenter(viewer));
    await tester.tap(action('forward'));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-forward-sheet')).evaluate().isNotEmpty,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('right click in the opened album acts on the picture shown', (
    tester,
  ) async {
    final preview = await _solidPreview(tester, 120, 80);
    for (var index = 0; index < 4; index++) {
      final wire = _albumWire(index);
      ((wire['messageParameters']! as Map)['file']! as Map)
        ..['name'] = 'photo-$index.png'
        ..['path'] = 'Talk/photo-$index.png';
      await _insertCachedMessage(database, wire, displayText: 'Photo');
    }
    final fakes = _PictureMenuFakes(preview.body);
    await tester.pumpWidget(
      app(
        home: roomScreen(),
        overrides: [
          chatMediaProvider.overrideWith((ref, key) async => preview),
          ...fakes.overrides,
        ],
      ),
    );
    final image = find.byKey(const Key('chat-image-101-0'));
    await _pumpUntil(
      tester,
      () =>
          image.hitTestable().evaluate().isNotEmpty &&
          find.byKey(const Key('chat-image-loading-101-0')).evaluate().isEmpty,
    );
    await tester.tap(image);
    await _pumpUntil(
      tester,
      () => find.byType(AuthenticatedImageGallery).evaluate().isNotEmpty,
    );
    final viewer = find.byKey(const Key('authenticated-image-fullscreen'));
    await _pumpUntil(tester, () => viewer.evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('chat-gallery-pages')),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('3 / 4'), findsOneWidget);
    await _pumpUntil(tester, () => viewer.evaluate().isNotEmpty);
    await tester.pumpAndSettle();

    Finder action(String name) => find.byKey(Key('message-action-$name'));
    await _rightClick(tester, tester.getCenter(viewer));
    await tester.tap(action('open-file'));
    await tester.pumpAndSettle();
    expect(fakes.opener.uris.single.path, endsWith('/Talk/photo-2.png'));

    await _rightClick(tester, tester.getCenter(viewer));
    await tester.tap(action('forward'));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('chat-forward-sheet')).evaluate().isNotEmpty,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }, variant: TargetPlatformVariant.desktop());
}

/// Windows hands a pen, a touch screen and a remote session's pointer to the
/// app as touch or stylus while the right button is still pressed.
void _registerSecondaryButtonKindTests() {
  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.stylus]) {
    testWidgets(
      'the secondary button of a ${kind.name} opens the picture menu',
      (tester) async {
        final preview = await _solidPreview(tester, 120, 80);
        await _insertCachedMessage(
          database,
          _layoutImageWire(100),
          displayText: 'Photo',
        );
        final fakes = _PictureMenuFakes(preview.body);
        await tester.pumpWidget(
          app(
            home: roomScreen(),
            overrides: [
              chatMediaProvider.overrideWith((ref, key) async => preview),
              ...fakes.overrides,
            ],
          ),
        );
        final image = find.byKey(const Key('chat-image-100-0'));
        await _pumpUntil(
          tester,
          () =>
              image.hitTestable().evaluate().isNotEmpty &&
              find.byKey(const Key('chat-image-loading-100-0')).evaluate().isEmpty,
        );

        final gesture = await tester.startGesture(
          tester.getCenter(image),
          kind: kind,
          buttons: kSecondaryButton,
        );
        await tester.pump(const Duration(milliseconds: 30));
        await gesture.up();
        await tester.pumpAndSettle();

        expect(find.byType(BottomSheet), findsNothing);
        expect(find.byKey(const Key('message-action-save-image')), findsOneWidget);
        expect(find.byKey(const Key('message-action-open-image')), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}

/// A right click as a real mouse makes it: the pointer has been over the
/// picture a moment, so the bubble is hovered, and the button is released
/// within the same frame, long before the tap deadline.
Future<void> _quickRightClick(WidgetTester tester, Offset position) async {
  final mouse = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(position);
  await tester.pump(const Duration(milliseconds: 100));
  await mouse.down(position);
  await tester.pump(const Duration(milliseconds: 30));
  await mouse.up();
  await tester.pumpAndSettle();
}
