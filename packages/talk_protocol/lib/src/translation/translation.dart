import 'dart:collection';

import '../chat/identifiers.dart';
import '../identifiers.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

const String translationLanguagesPath = '/ocs/v2.php/translation/languages';
const String translationTextPath = '/ocs/v2.php/translation/translate';
const String translationContractUserAgent =
    'com.nkshub.nextcloudtalk translation-contract/0.1';
const int translationMaximumTextCharacters = 1024 * 1024;
const int translationMaximumLanguagePairs = 4096;
const int translationMaximumResponseBytes = 2 * 1024 * 1024;

final RegExp _languageIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,32}$');

enum TranslationClassification {
  success,
  invalidInput,
  reauthenticationRequired,
  unavailable,
  rateLimited,
  serviceUnavailable,
}

final class TranslationLanguagePair {
  const TranslationLanguagePair._({
    required this.from,
    required this.fromLabel,
    required this.to,
    required this.toLabel,
  });

  final String from;
  final String fromLabel;
  final String to;
  final String toLabel;

  @override
  bool operator ==(Object other) =>
      other is TranslationLanguagePair && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'TranslationLanguagePair($from -> $to)';
}

sealed class TranslationRequest {
  TranslationRequest({
    required this.accountId,
    required this.requestId,
    required this.server,
    required bool translationAvailable,
    required this.userAgent,
  }) {
    if (!translationAvailable) {
      _requestFailure(r'$.capabilities.has-translation-providers');
    }
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      _requestFailure(r'$.headers.userAgent');
    }
  }

  final AccountId accountId;
  final ChatRequestId requestId;
  final ServerBase server;
  final String userAgent;

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Map<String, String> get queryParameters =>
      UnmodifiableMapView(const {'format': 'json'});

  String get path;

  Uri get uri => server.uri.replace(
    path: '${server.basePath}$path',
    queryParameters: queryParameters,
  );
}

final class TranslationLanguagesRequest extends TranslationRequest {
  TranslationLanguagesRequest({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.translationAvailable,
    super.userAgent = translationContractUserAgent,
  });

  @override
  String get path => translationLanguagesPath;

  @override
  String toString() => 'TranslationLanguagesRequest()';
}

final class TranslateTextRequest extends TranslationRequest {
  TranslateTextRequest({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.translationAvailable,
    required this.text,
    required this.fromLanguage,
    required this.toLanguage,
    super.userAgent = translationContractUserAgent,
  }) {
    if (text.trim().isEmpty || text.length > translationMaximumTextCharacters) {
      _requestFailure(r'$.body.text');
    }
    if (fromLanguage != null && !_languageIdPattern.hasMatch(fromLanguage!)) {
      _requestFailure(r'$.body.fromLanguage');
    }
    if (!_languageIdPattern.hasMatch(toLanguage) ||
        fromLanguage == toLanguage) {
      _requestFailure(r'$.body.toLanguage');
    }
  }

  final String text;
  final String? fromLanguage;
  final String toLanguage;

  Map<String, Object?> get jsonBody => UnmodifiableMapView({
    'text': text,
    'fromLanguage': fromLanguage,
    'toLanguage': toLanguage,
  });

  @override
  String get path => translationTextPath;

  @override
  String toString() =>
      'TranslateTextRequest(from: ${fromLanguage ?? 'detect'}, '
      'to: $toLanguage, text: <redacted>)';
}

final class TranslationLanguagesResponse {
  const TranslationLanguagesResponse._({
    required this.request,
    required this.classification,
    required this.languages,
    required this.languageDetection,
  });

  final TranslationLanguagesRequest request;
  final TranslationClassification classification;
  final List<TranslationLanguagePair> languages;
  final bool languageDetection;

  @override
  String toString() =>
      'TranslationLanguagesResponse(classification: '
      '${classification.name}, pairCount: ${languages.length}, '
      'languageDetection: $languageDetection)';
}

final class TranslateTextResponse {
  const TranslateTextResponse._({
    required this.request,
    required this.classification,
    required this.text,
    required this.detectedLanguage,
  });

  final TranslateTextRequest request;
  final TranslationClassification classification;
  final String? text;
  final String? detectedLanguage;

  @override
  String toString() =>
      'TranslateTextResponse(classification: ${classification.name}, '
      'hasText: ${text != null}, detectedLanguage: $detectedLanguage)';
}

TranslationLanguagesResponse decodeTranslationLanguagesResponse({
  required TranslationLanguagesRequest request,
  required int statusCode,
  required Object? json,
}) {
  final failure = _classification(statusCode);
  if (failure != null) {
    return TranslationLanguagesResponse._(
      request: request,
      classification: failure,
      languages: const [],
      languageDetection: false,
    );
  }
  if (statusCode != 200) {
    _unsupportedStatus();
  }
  final data = _successData(json);
  final rawLanguages = requireList(
    data['languages'],
    path: r'$.ocs.data.languages',
    code: TalkProtocolErrorCode.invalidTranslationResponse,
  );
  if (rawLanguages.length > translationMaximumLanguagePairs) {
    _responseFailure(r'$.ocs.data.languages');
  }
  final pairs = <TranslationLanguagePair>[];
  final unique = <String>{};
  for (var index = 0; index < rawLanguages.length; index++) {
    final path = '\$.ocs.data.languages[$index]';
    final raw = requireObject(
      rawLanguages[index],
      path: path,
      code: TalkProtocolErrorCode.invalidTranslationResponse,
    );
    final from = _languageId(raw['from'], '$path.from');
    final to = _languageId(raw['to'], '$path.to');
    if (from == to || !unique.add('$from\u0000$to')) {
      _responseFailure(path);
    }
    pairs.add(
      TranslationLanguagePair._(
        from: from,
        fromLabel: _label(raw['fromLabel'], '$path.fromLabel'),
        to: to,
        toLabel: _label(raw['toLabel'], '$path.toLabel'),
      ),
    );
  }
  final detection = requireBool(
    data['languageDetection'],
    path: r'$.ocs.data.languageDetection',
    code: TalkProtocolErrorCode.invalidTranslationResponse,
  );
  return TranslationLanguagesResponse._(
    request: request,
    classification: TranslationClassification.success,
    languages: List.unmodifiable(pairs),
    languageDetection: detection,
  );
}

TranslateTextResponse decodeTranslateTextResponse({
  required TranslateTextRequest request,
  required int statusCode,
  required Object? json,
}) {
  final failure = _classification(statusCode);
  if (failure != null) {
    return TranslateTextResponse._(
      request: request,
      classification: failure,
      text: null,
      detectedLanguage: null,
    );
  }
  if (statusCode != 200) {
    _unsupportedStatus();
  }
  final data = _successData(json);
  final translated = requireString(
    data['text'],
    path: r'$.ocs.data.text',
    code: TalkProtocolErrorCode.invalidTranslationResponse,
    minLength: 1,
    maxLength: translationMaximumTextCharacters,
  );
  final rawFrom = data['from'];
  final detected = rawFrom == null
      ? null
      : _languageId(rawFrom, r'$.ocs.data.from');
  return TranslateTextResponse._(
    request: request,
    classification: TranslationClassification.success,
    text: translated,
    detectedLanguage: detected,
  );
}

Map<String, Object?> _successData(Object? json) {
  final frozen = JsonFreezeSession(
    maximumDepth: 64,
    maximumNodes: 50000,
    errorCode: TalkProtocolErrorCode.invalidTranslationResponse,
    errorPath: r'$.body',
  ).freeze(json);
  final root = requireObject(
    frozen,
    path: r'$',
    code: TalkProtocolErrorCode.invalidTranslationResponse,
  );
  final ocs = requireObject(
    root['ocs'],
    path: r'$.ocs',
    code: TalkProtocolErrorCode.invalidTranslationResponse,
  );
  final meta = requireObject(
    ocs['meta'],
    path: r'$.ocs.meta',
    code: TalkProtocolErrorCode.invalidTranslationResponse,
  );
  final status = requireString(
    meta['status'],
    path: r'$.ocs.meta.status',
    code: TalkProtocolErrorCode.invalidTranslationResponse,
    minLength: 1,
    maxLength: 16,
  );
  final statusCode = requireInt(
    meta['statuscode'],
    path: r'$.ocs.meta.statuscode',
    code: TalkProtocolErrorCode.invalidTranslationResponse,
    minimum: 0,
  );
  requireString(
    meta['message'],
    path: r'$.ocs.meta.message',
    code: TalkProtocolErrorCode.invalidTranslationResponse,
    maxLength: 4096,
  );
  if (status != 'ok' || statusCode != 200) {
    _responseFailure(r'$.ocs.meta');
  }
  return requireObject(
    ocs['data'],
    path: r'$.ocs.data',
    code: TalkProtocolErrorCode.invalidTranslationResponse,
  );
}

String _languageId(Object? value, String path) {
  final language = requireString(
    value,
    path: path,
    code: TalkProtocolErrorCode.invalidTranslationResponse,
    minLength: 1,
    maxLength: 32,
  );
  if (!_languageIdPattern.hasMatch(language)) {
    _responseFailure(path);
  }
  return language;
}

String _label(Object? value, String path) {
  final label = requireString(
    value,
    path: path,
    code: TalkProtocolErrorCode.invalidTranslationResponse,
    minLength: 1,
    maxLength: 256,
  );
  if (label.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    _responseFailure(path);
  }
  return label;
}

TranslationClassification? _classification(int statusCode) =>
    switch (statusCode) {
      400 => TranslationClassification.invalidInput,
      401 => TranslationClassification.reauthenticationRequired,
      404 || 412 => TranslationClassification.unavailable,
      429 => TranslationClassification.rateLimited,
      500 || 503 => TranslationClassification.serviceUnavailable,
      _ => null,
    };

Never _requestFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidTranslationRequest, path);

Never _responseFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidTranslationResponse, path);

Never _unsupportedStatus() => throw const TalkProtocolException(
  TalkProtocolErrorCode.unsupportedHttpStatus,
  path: r'$.statusCode',
);
