import '../server_base.dart';
import 'models.dart';

const int referenceMaximumUriCharacters = 8192;

final class ReferenceResolveRequest {
  ReferenceResolveRequest({required this.server, required this.reference}) {
    if (!isSafeReferenceUri(reference)) {
      throw const ReferenceProtocolException(
        ReferenceProtocolError.invalidRequest,
      );
    }
  }

  final ServerBase server;
  final Uri reference;

  Uri get uri => server.uri.replace(
    path: '${server.basePath}/ocs/v2.php/references/resolve',
    queryParameters: <String, String>{
      'reference': reference.toString(),
      'format': 'json',
    },
  );

  @override
  String toString() => 'ReferenceResolveRequest(<redacted>)';
}

bool isSafeReferenceUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty &&
    uri.toString().runes.length <= referenceMaximumUriCharacters;
