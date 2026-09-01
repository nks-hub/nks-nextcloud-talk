import 'models.dart';
import 'request.dart';

enum ReferenceClassification {
  resolved,
  unavailable,
  unsupported,
  reauthenticationRequired,
  rateLimited,
  serviceUnavailable,
  invalidResponse,
}

final class ReferenceResolveResponse {
  const ReferenceResolveResponse._({
    required this.classification,
    required this.reference,
  });

  factory ReferenceResolveResponse.parse({
    required ReferenceResolveRequest request,
    required int statusCode,
    required Object? json,
  }) {
    final transportClassification = _httpClassification(statusCode);
    if (transportClassification != null) {
      return ReferenceResolveResponse._(
        classification: transportClassification,
        reference: null,
      );
    }
    if (statusCode != 200) {
      return const ReferenceResolveResponse._(
        classification: ReferenceClassification.invalidResponse,
        reference: null,
      );
    }

    final root = _object(json);
    final ocs = _object(root['ocs']);
    final meta = _object(ocs['meta']);
    final metaStatus = _string(meta['status'], maximum: 128);
    final metaCode = meta['statuscode'];
    _string(meta['message'], maximum: 4096, allowEmpty: true);
    if (metaCode is! int || metaCode < 0 || metaCode > 999) {
      _invalidResponse();
    }
    if (metaStatus != 'ok' || metaCode != 200) {
      final classification = _httpClassification(metaCode);
      return ReferenceResolveResponse._(
        classification:
            classification ?? ReferenceClassification.invalidResponse,
        reference: null,
      );
    }

    final data = _object(ocs['data']);
    final references = _object(data['references']);
    final expectedKey = request.reference.toString();
    if (references.length != 1 || !references.containsKey(expectedKey)) {
      _invalidResponse();
    }
    final rawReference = references[expectedKey];
    if (rawReference == null) {
      return const ReferenceResolveResponse._(
        classification: ReferenceClassification.unavailable,
        reference: null,
      );
    }

    final reference = _object(rawReference);
    final accessible = reference['accessible'];
    if (accessible is! bool) {
      _invalidResponse();
    }
    final type = _string(reference['richObjectType'], maximum: 128);
    _object(reference['richObject']);
    final openGraph = _object(reference['openGraphObject']);
    _string(openGraph['id'], maximum: referenceMaximumUriCharacters);
    final title = _string(openGraph['name'], maximum: 4096, allowEmpty: true);
    final description = _optionalString(
      openGraph['description'],
      maximum: 16384,
    );
    final rawThumb = _optionalString(
      openGraph['thumb'],
      maximum: referenceMaximumUriCharacters,
    );
    _optionalString(openGraph['link'], maximum: referenceMaximumUriCharacters);
    if (!accessible) {
      return const ReferenceResolveResponse._(
        classification: ReferenceClassification.unavailable,
        reference: null,
      );
    }
    return ReferenceResolveResponse._(
      classification: ReferenceClassification.resolved,
      reference: ResolvedReference.validated(
        reference: request.reference,
        title: title.trim(),
        description: description?.trim(),
        richObjectType: type,
        thumbnail: _absoluteHttpUri(rawThumb),
      ),
    );
  }

  final ReferenceClassification classification;
  final ResolvedReference? reference;

  @override
  String toString() =>
      'ReferenceResolveResponse(classification: ${classification.name})';
}

ReferenceClassification? _httpClassification(int statusCode) =>
    switch (statusCode) {
      401 => ReferenceClassification.reauthenticationRequired,
      404 => ReferenceClassification.unsupported,
      429 => ReferenceClassification.rateLimited,
      500 || 503 => ReferenceClassification.serviceUnavailable,
      _ => null,
    };

Map<String, Object?> _object(Object? value) {
  if (value is! Map<String, Object?> || value.length > 4096) {
    _invalidResponse();
  }
  return value;
}

String _string(Object? value, {required int maximum, bool allowEmpty = false}) {
  if (value is! String ||
      (!allowEmpty && value.isEmpty) ||
      value.runes.length > maximum) {
    _invalidResponse();
  }
  return value;
}

String? _optionalString(Object? value, {required int maximum}) =>
    value == null ? null : _string(value, maximum: maximum, allowEmpty: true);

/// The thumbnail only survives as an absolute http(s) URL without credentials
/// in it. Anything else is dropped rather than rejected: a server that sends a
/// shape we will not fetch must not cost the reader the whole card.
Uri? _absoluteHttpUri(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.isAbsolute ||
      uri.userInfo.isNotEmpty ||
      uri.host.isEmpty ||
      (uri.scheme != 'https' && uri.scheme != 'http')) {
    return null;
  }
  return uri;
}

Never _invalidResponse() => throw const ReferenceProtocolException(
  ReferenceProtocolError.invalidResponse,
);
