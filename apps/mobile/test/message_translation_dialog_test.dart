import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/message_translation_dialog.dart';
import 'package:nextcloudtalk/features/chat/message_translation_service.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  testWidgets('loads languages, translates rich text and copies the result', (
    tester,
  ) async {
    var translateCalled = false;
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
    final service = _FakeTranslationService(
      languagesHandler: () => _languagesResponse(),
      translateHandler: (from, to, text) {
        translateCalled = true;
        expect(from, isNull);
        expect(to, 'cs');
        expect(text, 'Hello {user}');
        return _translateResponse(text: 'Ahoj {user}', from: 'en');
      },
    );
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(service, textScaleFactor: 2));
    await tester.pumpAndSettle();

    expect(find.text('Rozpoznat jazyk'), findsOneWidget);
    expect(find.text('Čeština'), findsOneWidget);
    await tester.tap(find.byKey(const Key('translation-submit')));
    await tester.pumpAndSettle();

    expect(translateCalled, isTrue);
    expect(find.byKey(const Key('translation-result')), findsOneWidget);
    expect(
      find.text('Překlad vytvořila AI a může obsahovat chyby.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.byKey(const Key('translation-copy')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('translation-copy')));
    await tester.pumpAndSettle();
    expect(copiedTexts, ['Ahoj {user}']);
    expect(find.byKey(const Key('translation-copied')), findsOneWidget);
  });

  testWidgets('shows a recoverable language loading error', (tester) async {
    var attempts = 0;
    final service = _FakeTranslationService(
      languagesHandler: () {
        attempts++;
        if (attempts == 1) {
          throw const MessageTranslationException(
            MessageTranslationError.network,
          );
        }
        return _languagesResponse();
      },
      translateHandler: (_, _, _) => throw StateError('not expected'),
    );

    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('translation-error')), findsOneWidget);
    await tester.tap(find.text('Zkusit znovu'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.byKey(const Key('translation-target')), findsOneWidget);
  });

  testWidgets('ignores a late language response after disposal', (
    tester,
  ) async {
    final completer = Completer<TranslationLanguagesResponse>();
    Future<void>? abort;
    final service = _FakeTranslationService(
      languagesHandler: () => completer.future,
      translateHandler: (_, _, _) => throw StateError('not expected'),
      onAbort: (value) => abort = value,
    );

    await tester.pumpWidget(_app(service));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await expectLater(abort, completes);
    completer.complete(_languagesResponse());
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

Widget _app(MessageTranslationService service, {double textScaleFactor = 1}) =>
    localizedTestApp(
      locale: const Locale('cs'),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(800, 900),
          textScaler: TextScaler.linear(textScaleFactor),
        ),
        child: Scaffold(
          body: MessageTranslationDialog(
            account: _account,
            roomToken: 'rooma123',
            message: _message(),
            service: service,
          ),
        ),
      ),
    );

typedef _TranslateHandler =
    FutureOr<TranslateTextResponse> Function(
      String? fromLanguage,
      String toLanguage,
      String text,
    );

final class _FakeTranslationService implements MessageTranslationService {
  const _FakeTranslationService({
    required this.languagesHandler,
    required this.translateHandler,
    this.onAbort,
  });

  final FutureOr<TranslationLanguagesResponse> Function() languagesHandler;
  final _TranslateHandler translateHandler;
  final ValueChanged<Future<void>?>? onAbort;

  @override
  Future<TranslationLanguagesResponse> languages({
    required String accountId,
    required String roomToken,
    Future<void>? abortTrigger,
  }) async {
    onAbort?.call(abortTrigger);
    return languagesHandler();
  }

  @override
  Future<TranslateTextResponse> translate({
    required String accountId,
    required String roomToken,
    required String text,
    required String? fromLanguage,
    required String toLanguage,
    Future<void>? abortTrigger,
  }) async => translateHandler(fromLanguage, toLanguage, text);
}

TranslationLanguagesResponse _languagesResponse() {
  final request = TranslationLanguagesRequest(
    accountId: AccountId.parse('account-a'),
    requestId: ChatRequestId.parse('dialog-languages'),
    server: ServerBase.parse(_account.serverUrl),
    translationAvailable: true,
  );
  return decodeTranslationLanguagesResponse(
    request: request,
    statusCode: 200,
    json: _ocs({
      'languages': [
        {
          'from': 'en',
          'fromLabel': 'English',
          'to': 'cs',
          'toLabel': 'Čeština',
        },
        {
          'from': 'cs',
          'fromLabel': 'Čeština',
          'to': 'en',
          'toLabel': 'English',
        },
      ],
      'languageDetection': true,
    }),
  );
}

TranslateTextResponse _translateResponse({
  required String text,
  required String? from,
}) {
  final request = TranslateTextRequest(
    accountId: AccountId.parse('account-a'),
    requestId: ChatRequestId.parse('dialog-translate'),
    server: ServerBase.parse(_account.serverUrl),
    translationAvailable: true,
    text: 'Hello {user}',
    fromLanguage: null,
    toLanguage: 'cs',
  );
  return decodeTranslateTextResponse(
    request: request,
    statusCode: 200,
    json: _ocs({'text': text, 'from': from}),
  );
}

Map<String, Object?> _ocs(Object? data) => {
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
    'data': data,
  },
};

ChatMessage _message() => ChatMessage.fromJson({
  'id': 42,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'user-b',
  'actorDisplayName': 'User B',
  'timestamp': 1724300000,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': 'translation-message-42',
  'message': 'Hello {user}',
  'messageParameters': {
    'user': {'type': 'user', 'id': 'user-b', 'name': 'User B'},
  },
  'markdown': false,
  'reactions': <String, Object?>{},
});

const _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'user-a',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 1767225600000,
  lastSyncError: null,
);
