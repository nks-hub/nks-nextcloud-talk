import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/newconversation/conversation_creation_dialog.dart';
import 'package:nextcloudtalk/features/newconversation/new_conversation_service.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'accessibility_probe.dart';
import 'conversation_creation_test_support.dart';
import 'test_support.dart';

void main() {
  late _CreationService service;
  late Completer<void> ownerAbort;
  var current = true;
  ConversationCreationResult? created;

  setUp(() {
    service = _CreationService();
    current = true;
    created = null;
  });

  Future<void> open(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    double textScale = 1,
    StandaloneConversationType type = StandaloneConversationType.group,
  }) async {
    ownerAbort = Completer<void>();
    await tester.pumpWidget(
      localizedTestApp(
        locale: locale,
        textScale: textScale,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                created = await showDialog<ConversationCreationResult>(
                  context: context,
                  builder: (_) => ConversationCreationDialog(
                    service: service,
                    accountId: 'account-a',
                    initialType: type,
                    isCurrent: () => current,
                    abortTrigger: ownerAbort.future,
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> preset(WidgetTester tester, String name) async {
    await tester.ensureVisible(find.byKey(const Key('creation-preset')));
    await tester.tap(find.byKey(const Key('creation-preset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'webinar selection applies public type and forced readable settings',
    (tester) async {
      await open(tester);
      await preset(tester, 'Webinar');
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('creation-public')))
            .value,
        isTrue,
      );
      expect(
        find.text(
          'Participant permissions (set by the server): Send messages',
        ),
        findsOneWidget,
      );
      expect(find.text('Recording consent: Required'), findsOneWidget);
      expect(find.text('389'), findsNothing);
      await preset(tester, 'Presentation');
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('creation-public')))
            .value,
        isFalse,
      );
      expect(find.text('Lobby: Everyone can take part'), findsOneWidget);
      expect(find.byKey(const Key('creation-password')), findsNothing);
    },
  );

  testWidgets(
    'explicit type choice overrides a preset while forced type stays locked',
    (tester) async {
      await open(tester);
      await preset(tester, 'Webinar');
      await tester.ensureVisible(find.byKey(const Key('creation-public')));
      await tester.tap(find.byKey(const Key('creation-public')));
      await tester.pumpAndSettle();
      await preset(tester, 'Presentation');
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('creation-public')))
            .value,
        isFalse,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      final data = creationPresets();
      (data.last['parameters'] as Map)['roomType'] = 3;
      service.options = ConversationCreationOptions(
        accountId: 'account-a',
        catalog: RoomPresetCatalog.fromJson(data),
        supportsPassword: true,
        forcePasswords: false,
        supportsExtendedFields: true,
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('creation-public')),
      );
      expect(toggle.value, isTrue);
      expect(toggle.onChanged, isNull);
    },
  );

  testWidgets(
    'required password validates without dispatch and preserves its spaces',
    (tester) async {
      service.options = ConversationCreationOptions(
        accountId: 'account-a',
        catalog: creationCatalog(),
        supportsPassword: true,
        forcePasswords: true,
        supportsExtendedFields: true,
      );
      await open(tester, type: StandaloneConversationType.public);
      await tester.enterText(
        find.byKey(const Key('creation-name')),
        'Town hall',
      );
      await tester.tap(find.byKey(const Key('creation-submit')));
      await tester.pumpAndSettle();
      expect(service.creates, 0);
      expect(
        find.text('Enter a password for this public conversation.'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('creation-password')),
        '  private value  ',
      );
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('creation-password')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.obscureText, isTrue);
      expect(field.enableSuggestions, isFalse);
      await tester.tap(find.byKey(const Key('creation-submit')));
      await tester.pumpAndSettle();
      expect(service.password, '  private value  ');
      expect(service.creates, 1);
      expect(created?.roomToken.value, 'newroom1');
    },
  );

  testWidgets(
    'definitive password policy error keeps editable input and hint',
    (tester) async {
      service.create = () async => throw const NewConversationException(
        NewConversationError.passwordRequired,
        safeMessage: 'Use more characters.',
      );
      await open(tester, type: StandaloneConversationType.public);
      await tester.enterText(
        find.byKey(const Key('creation-name')),
        'Town hall',
      );
      await tester.enterText(
        find.byKey(const Key('creation-password')),
        'short',
      );
      await tester.tap(find.byKey(const Key('creation-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Use more characters.'), findsOneWidget);
      expect(find.byKey(const Key('creation-password')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('creation-submit')))
            .onPressed,
        isNotNull,
      );
      expect(created, isNull);
    },
  );

  testWidgets(
    'server-wide recording policy overrides the visible preset setting',
    (tester) async {
      service.options = ConversationCreationOptions(
        accountId: 'account-a',
        catalog: creationCatalog(),
        supportsPassword: true,
        forcePasswords: false,
        supportsExtendedFields: true,
        recordingConsentPolicy: 0,
      );
      await open(tester);
      await preset(tester, 'Webinar');
      expect(
        find.text('Recording consent (set by the server): Not required'),
        findsOneWidget,
      );
      expect(find.text('Recording consent: Required'), findsNothing);
    },
  );

  testWidgets('uncertain creation offers no repeat submit', (tester) async {
    service.create = () async =>
        throw const NewConversationException(NewConversationError.ambiguous);
    await open(tester);
    await tester.enterText(find.byKey(const Key('creation-name')), 'Room');
    await tester.tap(find.byKey(const Key('creation-submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Check the conversation list'), findsOneWidget);
    expect(find.byKey(const Key('creation-submit')), findsNothing);
    expect(service.creates, 1);
    expect(created, isNull);
  });

  testWidgets(
    'double tap while creating sends once and cancellation cannot hide it',
    (tester) async {
      final pending = Completer<ConversationCreationResult>();
      service.create = () => pending.future;
      await open(tester);
      await tester.enterText(find.byKey(const Key('creation-name')), 'Room');
      await tester.tap(find.byKey(const Key('creation-submit')));
      await tester.tap(find.byKey(const Key('creation-submit')));
      await tester.pump();
      expect(service.creates, 1);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .onPressed,
        isNull,
      );
      pending.complete(_result());
      await tester.pumpAndSettle();
      expect(created?.roomToken.value, 'newroom1');
    },
  );

  testWidgets(
    'owner invalidation suppresses a late success and clears password',
    (tester) async {
      final pending = Completer<ConversationCreationResult>();
      service.create = () => pending.future;
      await open(tester, type: StandaloneConversationType.public);
      await tester.enterText(find.byKey(const Key('creation-name')), 'Room');
      await tester.enterText(
        find.byKey(const Key('creation-password')),
        'private',
      );
      await tester.tap(find.byKey(const Key('creation-submit')));
      await tester.pump();
      current = false;
      ownerAbort.complete();
      await tester.pump();
      pending.complete(_result());
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(created, isNull);
      expect(find.byKey(const Key('creation-password')), findsNothing);
      expect(find.byKey(const Key('creation-submit')), findsNothing);
      expect(service.lastCurrent?.call(), isFalse);
    },
  );

  testWidgets(
    'changed policy requires reload and another explicit confirmation',
    (tester) async {
      service.create = () async => throw const NewConversationException(
        NewConversationError.contextChanged,
      );
      await open(tester);
      await tester.enterText(find.byKey(const Key('creation-name')), 'Room');
      await tester.tap(find.byKey(const Key('creation-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('creation-submit')), findsNothing);
      expect(find.byKey(const Key('creation-reload')), findsOneWidget);
      await tester.tap(find.byKey(const Key('creation-reload')));
      await tester.pumpAndSettle();
      expect(service.prepares, 2);
      expect(service.creates, 1);
      expect(find.byKey(const Key('creation-submit')), findsOneWidget);
    },
  );

  for (final locale in const [Locale('en'), Locale('cs')]) {
    testWidgets(
      'preset form remains usable with large text and keyboard in ${locale.languageCode}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 640);
        tester.view.viewInsets = const FakeViewPadding(bottom: 180);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetViewInsets);
        final overflows = await overflowsWhile(() async {
          await open(
            tester,
            locale: locale,
            textScale: 2,
            type: StandaloneConversationType.public,
          );
          await tester.ensureVisible(
            find.byKey(const Key('creation-password')),
          );
          await tester.enterText(
            find.byKey(const Key('creation-password')),
            'secret',
          );
          await tester.pumpAndSettle();
        });
        expect(overflows, isEmpty);
        expect(
          tester.getRect(find.byKey(const Key('creation-submit'))).bottom,
          lessThanOrEqualTo(460),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

ConversationCreationResult _result() => ConversationCreationResult(
  roomToken: ConversationToken.parse('newroom1', path: r'$.token'),
);

class _CreationService implements NewConversationService {
  ConversationCreationOptions options = ConversationCreationOptions(
    accountId: 'account-a',
    catalog: creationCatalog(),
    supportsPassword: true,
    forcePasswords: false,
    supportsExtendedFields: true,
  );
  Future<ConversationCreationResult> Function() create = () async => _result();
  int creates = 0;
  int prepares = 0;
  String? password;
  bool Function()? lastCurrent;

  @override
  Future<ConversationCreationOptions> prepareCreation({
    required String accountId,
    Future<void>? abortTrigger,
    bool Function()? isCurrent,
  }) async {
    prepares++;
    return options;
  }

  @override
  Future<ConversationCreationResult> createPreparedConversation({
    required ConversationCreationOptions options,
    required String roomName,
    String? presetIdentifier,
    Map<String, int> userParameters = const {},
    String password = '',
    ConversationRecipient? groupRecipient,
    Future<void>? abortTrigger,
    bool Function()? isCurrent,
  }) async {
    creates++;
    this.password = password;
    lastCurrent = isCurrent;
    return create();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
