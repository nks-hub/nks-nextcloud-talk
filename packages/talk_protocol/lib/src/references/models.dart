enum ReferenceProtocolError { invalidRequest, invalidResponse }

final class ReferenceProtocolException implements Exception {
  const ReferenceProtocolException(this.error);

  final ReferenceProtocolError error;

  @override
  String toString() => 'ReferenceProtocolException(${error.name})';
}

final class ResolvedReference {
  const ResolvedReference._({
    required this.reference,
    required this.title,
    required this.description,
    required this.richObjectType,
    required this.thumbnail,
  });

  factory ResolvedReference.validated({
    required Uri reference,
    required String title,
    required String? description,
    required String richObjectType,
    Uri? thumbnail,
  }) => ResolvedReference._(
    reference: reference,
    title: title,
    description: description,
    richObjectType: richObjectType,
    thumbnail: thumbnail,
  );

  final Uri reference;
  final String title;
  final String? description;
  final String richObjectType;

  /// `openGraphObject.thumb` as the server sent it, absolute and http(s) only.
  ///
  /// Whether it is safe to fetch is not decided here: the caller has to check
  /// it against the account it is bound to before touching the network.
  final Uri? thumbnail;

  @override
  String toString() =>
      'ResolvedReference(type: $richObjectType, content: <redacted>)';
}
