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
  });

  factory ResolvedReference.validated({
    required Uri reference,
    required String title,
    required String? description,
    required String richObjectType,
  }) => ResolvedReference._(
    reference: reference,
    title: title,
    description: description,
    richObjectType: richObjectType,
  );

  final Uri reference;
  final String title;
  final String? description;
  final String richObjectType;

  @override
  String toString() =>
      'ResolvedReference(type: $richObjectType, content: <redacted>)';
}
