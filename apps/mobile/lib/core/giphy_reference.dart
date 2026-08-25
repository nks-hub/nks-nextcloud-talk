const giphyPreviewLabel = 'GIF';

final _urlCandidatePattern = RegExp(
  r'''https://[^\s<>"'()\[\]{}]+''',
  caseSensitive: false,
);
const _trailingUrlPunctuation = '.,!;:';

bool isSupportedGiphyResource(Uri uri) {
  final host = uri.host.toLowerCase();
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      uri.query.isNotEmpty) {
    return false;
  }
  if (host == 'giphy.com' || host == 'www.giphy.com') {
    return uri.pathSegments.length == 2 &&
        uri.pathSegments.first == 'gifs' &&
        uri.pathSegments.last.isNotEmpty;
  }
  return host == 'media.giphy.com' &&
      uri.pathSegments.length == 3 &&
      uri.pathSegments.first == 'media' &&
      uri.pathSegments[1].isNotEmpty &&
      uri.pathSegments.last == 'giphy.gif';
}

Uri? exactGiphyResource(String text) {
  final candidate = text.trim();
  if (candidate.isEmpty || candidate.length > 4096) {
    return null;
  }
  final uri = Uri.tryParse(candidate);
  if (uri == null ||
      uri.toString() != candidate ||
      !isSupportedGiphyResource(uri)) {
    return null;
  }
  return uri;
}

String normalizeGiphyReferencePreview(String text) {
  if (text.isEmpty) {
    return text;
  }
  final output = StringBuffer();
  var cursor = 0;
  var changed = false;
  for (final match in _urlCandidatePattern.allMatches(text)) {
    final matchedText = match.group(0)!;
    var candidateEnd = matchedText.length;
    while (candidateEnd > 0 &&
        _trailingUrlPunctuation.contains(matchedText[candidateEnd - 1])) {
      candidateEnd--;
    }
    final candidate = matchedText.substring(0, candidateEnd);
    final resource = Uri.tryParse(candidate);
    if (resource == null || !isSupportedGiphyResource(resource)) {
      continue;
    }
    output
      ..write(text.substring(cursor, match.start))
      ..write(giphyPreviewLabel)
      ..write(matchedText.substring(candidateEnd));
    cursor = match.end;
    changed = true;
  }
  if (!changed) {
    return text;
  }
  output.write(text.substring(cursor));
  return output.toString();
}
