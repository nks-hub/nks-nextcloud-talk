import 'dart:convert';
import 'dart:io';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  final accountId = AccountId.parse('account-a');
  final server = ServerBase.parse('https://cloud.example.invalid/nextcloud');

  test('capability snapshot validates the translation provider flag', () {
    final json = _capabilities(translation: true);
    final snapshot = CapabilitySnapshot.fromJson(
      json,
      context: CapabilityContext.authenticated,
    );
    expect(snapshot.chatTranslationAvailable, isTrue);

    final spreed =
        (json['ocs']! as Map<String, Object?>)['data']! as Map<String, Object?>;
    final capabilities = spreed['capabilities']! as Map<String, Object?>;
    final talk = capabilities['spreed']! as Map<String, Object?>;
    final config = talk['config']! as Map<String, Object?>;
    final chat = config['chat']! as Map<String, Object?>;
    chat['has-translation-providers'] = 1;
    expect(
      () => CapabilitySnapshot.fromJson(
        json,
        context: CapabilityContext.authenticated,
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('builds bounded languages and translate requests', () {
    final languages = TranslationLanguagesRequest(
      accountId: accountId,
      requestId: ChatRequestId.parse('translation-languages-1'),
      server: server,
      translationAvailable: true,
    );
    expect(
      languages.uri.toString(),
      'https://cloud.example.invalid/nextcloud/ocs/v2.php/translation/'
      'languages?format=json',
    );
    expect(languages.headers['OCS-APIRequest'], 'true');

    final translate = TranslateTextRequest(
      accountId: accountId,
      requestId: ChatRequestId.parse('translation-text-1'),
      server: server,
      translationAvailable: true,
      text: 'Hello {user}',
      fromLanguage: null,
      toLanguage: 'cs',
    );
    expect(translate.jsonBody, {
      'text': 'Hello {user}',
      'fromLanguage': null,
      'toLanguage': 'cs',
    });
    expect(translate.toString(), isNot(contains('Hello')));
  });

  test(
    'rejects unavailable, empty, oversized and invalid language requests',
    () {
      expect(
        () => TranslationLanguagesRequest(
          accountId: accountId,
          requestId: ChatRequestId.parse('translation-unavailable'),
          server: server,
          translationAvailable: false,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      for (final request in <TranslateTextRequest Function()>[
        () => TranslateTextRequest(
          accountId: accountId,
          requestId: ChatRequestId.parse('translation-empty'),
          server: server,
          translationAvailable: true,
          text: ' ',
          fromLanguage: 'en',
          toLanguage: 'cs',
        ),
        () => TranslateTextRequest(
          accountId: accountId,
          requestId: ChatRequestId.parse('translation-oversized'),
          server: server,
          translationAvailable: true,
          text: 'a' * (translationMaximumTextCharacters + 1),
          fromLanguage: 'en',
          toLanguage: 'cs',
        ),
        () => TranslateTextRequest(
          accountId: accountId,
          requestId: ChatRequestId.parse('translation-language'),
          server: server,
          translationAvailable: true,
          text: 'Hello',
          fromLanguage: 'en!',
          toLanguage: 'cs',
        ),
      ]) {
        expect(request, throwsA(isA<TalkProtocolException>()));
      }
    },
  );

  test('decodes immutable language pairs and language detection', () {
    final request = TranslationLanguagesRequest(
      accountId: accountId,
      requestId: ChatRequestId.parse('translation-languages-response'),
      server: server,
      translationAvailable: true,
    );
    final response = decodeTranslationLanguagesResponse(
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
            'from': 'de',
            'fromLabel': 'Deutsch',
            'to': 'cs',
            'toLabel': 'Čeština',
          },
        ],
        'languageDetection': true,
      }),
    );

    expect(response.classification, TranslationClassification.success);
    expect(response.languages, hasLength(2));
    expect(response.languages.first.from, 'en');
    expect(response.languages.first.toLabel, 'Čeština');
    expect(response.languageDetection, isTrue);
    expect(response.languages.clear, throwsUnsupportedError);
  });

  test('rejects duplicate pairs and control characters in labels', () {
    final request = TranslationLanguagesRequest(
      accountId: accountId,
      requestId: ChatRequestId.parse('translation-invalid-response'),
      server: server,
      translationAvailable: true,
    );
    final pair = {
      'from': 'en',
      'fromLabel': 'English',
      'to': 'cs',
      'toLabel': 'Čeština',
    };
    expect(
      () => decodeTranslationLanguagesResponse(
        request: request,
        statusCode: 200,
        json: _ocs({
          'languages': [pair, pair],
          'languageDetection': false,
        }),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(
      () => decodeTranslationLanguagesResponse(
        request: request,
        statusCode: 200,
        json: _ocs({
          'languages': [
            {...pair, 'fromLabel': 'English\nspoof'},
          ],
          'languageDetection': false,
        }),
      ),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test('decodes translated text and detected source without logging text', () {
    final request = TranslateTextRequest(
      accountId: accountId,
      requestId: ChatRequestId.parse('translation-text-response'),
      server: server,
      translationAvailable: true,
      text: 'Hello',
      fromLanguage: null,
      toLanguage: 'cs',
    );
    final response = decodeTranslateTextResponse(
      request: request,
      statusCode: 200,
      json: _ocs({'text': 'Ahoj', 'from': 'en'}),
    );

    expect(response.text, 'Ahoj');
    expect(response.detectedLanguage, 'en');
    expect(response.toString(), isNot(contains('Ahoj')));
  });

  for (final entry in const {
    400: TranslationClassification.invalidInput,
    401: TranslationClassification.reauthenticationRequired,
    404: TranslationClassification.unavailable,
    412: TranslationClassification.unavailable,
    429: TranslationClassification.rateLimited,
    500: TranslationClassification.serviceUnavailable,
    503: TranslationClassification.serviceUnavailable,
  }.entries) {
    test('classifies HTTP ${entry.key} without requiring a body', () {
      final request = TranslationLanguagesRequest(
        accountId: accountId,
        requestId: ChatRequestId.parse('translation-http-${entry.key}'),
        server: server,
        translationAvailable: true,
      );
      final response = decodeTranslationLanguagesResponse(
        request: request,
        statusCode: entry.key,
        json: null,
      );
      expect(response.classification, entry.value);
    });
  }
}

Map<String, Object?> _capabilities({required bool translation}) {
  final json =
      jsonDecode(
            File(
              '../../contracts/client-bootstrap/fixtures/'
              'capabilities-authenticated.response.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final ocs = json['ocs']! as Map<String, Object?>;
  final data = ocs['data']! as Map<String, Object?>;
  final capabilities = data['capabilities']! as Map<String, Object?>;
  final spreed = capabilities['spreed']! as Map<String, Object?>;
  final config =
      spreed.putIfAbsent('config', () => <String, Object?>{})!
          as Map<String, Object?>;
  final chat =
      config.putIfAbsent('chat', () => <String, Object?>{})!
          as Map<String, Object?>;
  chat['has-translation-providers'] = translation;
  return json;
}

Map<String, Object?> _ocs(Object? data) => {
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
    'data': data,
  },
};
