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

/// Whether a reference thumbnail may be fetched for [server].
///
/// Nextcloud hands out its own proxy address for an OpenGraph image:
/// `LinkReferenceProvider` sets it to the absolute `core.Reference.preview`
/// route, whose path is `/core/references/preview/{referenceId}` and whose id
/// is an md5. Accepting exactly that shape, and only on the account's own
/// origin, means the reader never contacts the linked site — so opening a
/// conversation cannot leak their address to it.
bool isSafeReferenceThumbnail({
  required ServerBase server,
  required Uri? thumbnail,
}) {
  if (thumbnail == null ||
      !server.hasSameOrigin(thumbnail) ||
      thumbnail.userInfo.isNotEmpty ||
      thumbnail.hasQuery ||
      thumbnail.hasFragment) {
    return false;
  }
  final segments = thumbnail.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList();
  final base = server.uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (segments.length < base.length) {
    return false;
  }
  for (var index = 0; index < base.length; index++) {
    if (segments[index] != base[index]) {
      return false;
    }
  }
  var rest = segments.sublist(base.length);
  // Pretty URLs drop the front controller, so both shapes have to pass.
  if (rest.isNotEmpty && rest.first == 'index.php') {
    rest = rest.sublist(1);
  }
  if (rest.length != 4 ||
      rest[0] != 'core' ||
      rest[1] != 'references' ||
      rest[2] != 'preview') {
    return false;
  }
  return _referenceIdPattern.hasMatch(rest[3]);
}

final RegExp _referenceIdPattern = RegExp(r'^[0-9a-f]{32}$');
