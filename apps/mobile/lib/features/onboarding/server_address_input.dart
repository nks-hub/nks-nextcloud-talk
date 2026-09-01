/// Nextcloud routes a pasted browser address ends in. Everything before the
/// first of these is the server base, so an install under a subdirectory keeps
/// its prefix while `.../index.php/apps/spreed` collapses back to the host.
const _nextcloudRouteSegments = <String>[
  'index.php',
  'apps',
  'settings',
  'login',
  'logout',
  'remote.php',
  'ocs',
  's',
  'f',
  'call',
];

/// Characters a copy carries along from a chat message, a mail client or a
/// markdown link, none of which can appear in a server address.
const _wrappingCharacters = '<>()[]{}"\'`,;';

/// Turns whatever the user typed or pasted into a server address candidate.
///
/// The rules stay deliberately narrow: strip the noise a clipboard adds, drop
/// the query and fragment a browser URL carries, and cut a known Nextcloud
/// route off the end. An unrecognised path is left alone, because a server can
/// legitimately live under one and guessing would break that install.
String normalizeServerAddressInput(String raw) {
  var value = raw.trim();
  while (value.isNotEmpty && _wrappingCharacters.contains(value[0])) {
    value = value.substring(1);
  }
  while (value.isNotEmpty &&
      _wrappingCharacters.contains(value[value.length - 1])) {
    value = value.substring(0, value.length - 1);
  }
  value = value.trim();
  if (value.isEmpty) {
    return '';
  }

  // The field starts at `https://`, so pasting a full address doubles the
  // scheme. Keep the one the user pasted rather than rejecting the input.
  var schemeEnd = value.indexOf('://');
  while (schemeEnd > 0) {
    final rest = value.substring(schemeEnd + 3);
    final nested = rest.indexOf('://');
    if (nested <= 0 || rest.substring(0, nested).contains('/')) {
      break;
    }
    value = rest;
    schemeEnd = nested;
  }

  final scheme = schemeEnd <= 0 ? '' : value.substring(0, schemeEnd + 3);
  var remainder = schemeEnd <= 0 ? value : value.substring(schemeEnd + 3);

  for (final terminator in const ['#', '?']) {
    final index = remainder.indexOf(terminator);
    if (index >= 0) {
      remainder = remainder.substring(0, index);
    }
  }

  final pathStart = remainder.indexOf('/');
  if (pathStart < 0) {
    return '$scheme$remainder';
  }
  final authority = remainder.substring(0, pathStart);
  final segments = remainder
      .substring(pathStart)
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList();

  final cut = segments.indexWhere(
    (segment) => _nextcloudRouteSegments.contains(segment.toLowerCase()),
  );
  final kept = cut < 0 ? segments : segments.sublist(0, cut);
  final path = kept.isEmpty ? '' : '/${kept.join('/')}';
  return '$scheme$authority$path';
}
