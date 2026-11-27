import 'dart:io';

import 'package:talk_protocol/talk_protocol.dart';

import '../../../core/giphy_reference.dart';
import 'account_collection_store.dart';
import 'giphy.dart';

String _gifId(GiphyEntry entry) {
  final resource = entry.resourceUrl;
  if (!isSupportedGiphyResource(resource)) {
    throw const FormatException('Unsupported GIF reference');
  }
  return resource.host == 'media.giphy.com'
      ? resource.pathSegments[1]
      : resource.pathSegments.last.split('-').last;
}

bool sameFavoriteGif(GiphyEntry first, GiphyEntry second) =>
    _gifId(first) == _gifId(second);

final class GifFavoritesStore extends AccountCollectionStore<GiphyEntry> {
  GifFavoritesStore({Directory? directory})
    : super('gif-favorites-v1', directory);

  Future<void> setFavorite(
    AccountId account,
    GiphyEntry entry, {
    required bool saved,
  }) => update(account, (entries) {
    final id = _gifId(entry);
    entries.removeWhere((other) => _gifId(other) == id);
    if (saved) entries.insert(0, entry);
  });

  @override
  Map<String, Object?> encode(GiphyEntry entry) => {
    'resource': entry.resourceUrl.toString(),
    'thumbnail': _thumbnail(entry.thumbnailUrl).toString(),
    'title': entry.title,
    'subline': entry.subline,
  };

  @override
  GiphyEntry decode(Map<String, Object?> json) {
    final resource = exactGiphyResource(json['resource'] as String);
    if (resource == null) throw const FormatException('Invalid saved GIF');
    return GiphyEntry(
      resourceUrl: resource,
      thumbnailUrl: _thumbnail(Uri.parse(json['thumbnail'] as String)),
      title: json['title'] as String,
      subline: json['subline'] as String,
    );
  }

  // Only rendition parameters from the Nextcloud proxy belong on disk.
  // The repository checks the current account's origin again before loading.
  Uri _thumbnail(Uri uri) {
    if ((uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException('Invalid GIF thumbnail');
    }
    if (!uri.hasQuery) return uri;
    const rendition = {'gifId', 'domainPrefix', 'fileName', 'cid', 'rid', 'ct'};
    final query = Map.of(uri.queryParameters)
      ..removeWhere((key, _) => !rendition.contains(key));
    return uri.replace(queryParameters: query);
  }
}
