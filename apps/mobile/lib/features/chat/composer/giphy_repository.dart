part of 'giphy.dart';

final class HttpGiphyRepository implements GiphyRepository {
  static const _maximumCachedThumbnails = 32;
  static const _maximumThumbnailCacheBytes = 16 * 1024 * 1024;

  HttpGiphyRepository({
    required this.server,
    required this.authorization,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 20),
    this.maximumResponseBytes = 2 * 1024 * 1024,
    this.maximumThumbnailBytes = 8 * 1024 * 1024,
    this.maximumReferenceBytes = 16 * 1024 * 1024,
    this.maximumAttributionBytes = 256 * 1024,
  }) : _client = client ?? http.Client() {
    _requirePositive(maximumResponseBytes, 'maximumResponseBytes');
    _requirePositive(maximumThumbnailBytes, 'maximumThumbnailBytes');
    _requirePositive(maximumReferenceBytes, 'maximumReferenceBytes');
    _requirePositive(maximumAttributionBytes, 'maximumAttributionBytes');
  }

  final ServerBase server;
  final GiphyAuthorization authorization;
  final Duration requestTimeout;
  final int maximumResponseBytes;
  final int maximumThumbnailBytes;
  final int maximumReferenceBytes;
  final int maximumAttributionBytes;
  final http.Client _client;
  ({int cursor, int limit, GiphyPage page})? _prefetchedTrending;
  final LinkedHashMap<Uri, GiphyThumbnail> _thumbnailCache =
      LinkedHashMap<Uri, GiphyThumbnail>();
  final Map<Uri, Future<GiphyThumbnail>> _thumbnailLoads = {};
  var _thumbnailCacheBytes = 0;
  bool _closed = false;

  @override
  Future<GiphyPage> trending({
    required int cursor,
    required int limit,
    Future<void>? abortTrigger,
  }) {
    if (_closed || cursor < 0 || limit < 1 || limit > 50) {
      return Future<GiphyPage>.error(
        const GiphyException(GiphyError.invalidResponse),
      );
    }
    final prefetched = _prefetchedTrending;
    if (prefetched != null &&
        prefetched.cursor == cursor &&
        prefetched.limit == limit) {
      _prefetchedTrending = null;
      return Future<GiphyPage>.value(prefetched.page);
    }
    return _fetch(
      endpoint: 'gifs/trending',
      cursor: cursor,
      limit: limit,
      abortTrigger: abortTrigger,
    );
  }

  Future<void> probeAvailability({int cursor = 0, int limit = 20}) async {
    final page = await _fetch(
      endpoint: 'gifs/trending',
      cursor: cursor,
      limit: limit,
    );
    _prefetchedTrending = (cursor: cursor, limit: limit, page: page);
  }

  @override
  Future<GiphyAttributionAsset> loadAttributionAsset({
    Future<void>? abortTrigger,
  }) async {
    if (_closed) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    final uri = server.uri.replace(
      path:
          '${server.basePath}/apps/integration_giphy/img/'
          'powered-by-giphy.gif',
    );
    final deadline = DateTime.now().add(requestTimeout);
    final requestAbort = _RequestAbortSignal(
      deadline: deadline,
      callerTrigger: abortTrigger,
    );
    _ResponseBodyReader? bodyReader;
    try {
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: requestAbort.trigger)
            ..headers.addAll(<String, String>{
              ...authorization.requestHeaders,
              'Accept': 'image/gif',
            })
            ..followRedirects = false
            ..maxRedirects = 0;
      final response = await _sendWithDeadline(
        _client.send(request),
        deadline: deadline,
        requestAbort: requestAbort,
      );
      bodyReader = _ResponseBodyReader(response.stream);
      if (response.statusCode != 200) {
        var discarded = 0;
        while (await bodyReader.moveNext(deadline)) {
          discarded += bodyReader.current.length;
          if (discarded > maximumAttributionBytes) {
            break;
          }
        }
        throw switch (response.statusCode) {
          401 || 404 => const GiphyException(GiphyError.integrationUnavailable),
          429 => const GiphyException(GiphyError.rateLimited, statusCode: 429),
          _ => GiphyException(
            GiphyError.unexpectedStatus,
            statusCode: response.statusCode,
          ),
        };
      }
      final contentLength = response.contentLength;
      if (contentLength != null && contentLength > maximumAttributionBytes) {
        throw const GiphyException(GiphyError.responseTooLarge);
      }
      final bytes = BytesBuilder(copy: false);
      var received = 0;
      while (await bodyReader.moveNext(deadline)) {
        final chunk = bodyReader.current;
        received += chunk.length;
        if (received > maximumAttributionBytes) {
          throw const GiphyException(GiphyError.responseTooLarge);
        }
        bytes.add(chunk);
      }
      final body = bytes.takeBytes();
      final contentType = response.headers['content-type']
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      if (contentType != 'image/gif' ||
          body.isEmpty ||
          !_matchesThumbnailSignature(contentType!, body)) {
        throw const GiphyException(GiphyError.invalidResponse);
      }
      return GiphyAttributionAsset(body: body, contentType: contentType);
    } on GiphyException {
      rethrow;
    } on http.RequestAbortedException {
      throw GiphyException(requestAbort.error);
    } on TimeoutException {
      requestAbort.abortForDeadline();
      throw GiphyException(requestAbort.error);
    } on http.ClientException {
      throw const GiphyException(GiphyError.network);
    } finally {
      if (bodyReader != null) {
        await bodyReader.cancel(deadline);
      }
      requestAbort.dispose();
    }
  }

  @override
  Future<GiphyPage> search({
    required String term,
    required int cursor,
    required int limit,
    Future<void>? abortTrigger,
  }) {
    final normalized = term.trim();
    if (normalized.isEmpty || normalized.length > 200) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    return _fetch(
      endpoint: 'gifs/search',
      cursor: cursor,
      limit: limit,
      term: normalized,
      abortTrigger: abortTrigger,
    );
  }

  Future<GiphyReferenceMedia> loadReference(
    Uri resourceUrl, {
    Future<void>? abortTrigger,
  }) async {
    if (_closed || !isSupportedGiphyResource(resourceUrl)) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    final reference = await _resolveReference(
      resourceUrl,
      abortTrigger: abortTrigger,
    );
    final image = await _loadImage(
      reference.proxiedUrl,
      maximumBytes: maximumReferenceBytes,
      abortTrigger: abortTrigger,
    );
    if (image.contentType != 'image/gif') {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    return GiphyReferenceMedia(
      resourceUrl: resourceUrl,
      body: image.body,
      contentType: image.contentType,
      aspectRatio: _gifAspectRatio(image.body) ?? reference.aspectRatio,
    );
  }

  Future<GiphyThumbnail> loadThumbnail(
    GiphyEntry entry, {
    Future<void>? abortTrigger,
  }) async {
    if (_closed) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    final cached = _takeCachedThumbnail(entry.thumbnailUrl);
    if (cached != null) {
      return _copyThumbnail(cached);
    }

    if (abortTrigger != null) {
      final loaded = await _loadImage(
        entry.thumbnailUrl,
        maximumBytes: maximumThumbnailBytes,
        abortTrigger: abortTrigger,
      );
      _cacheThumbnail(entry.thumbnailUrl, loaded);
      return _copyThumbnail(loaded);
    }

    var load = _thumbnailLoads[entry.thumbnailUrl];
    if (load == null) {
      late final Future<GiphyThumbnail> started;
      started =
          _loadImage(entry.thumbnailUrl, maximumBytes: maximumThumbnailBytes)
              .then((thumbnail) {
                _cacheThumbnail(entry.thumbnailUrl, thumbnail);
                return thumbnail;
              })
              .whenComplete(() {
                if (identical(_thumbnailLoads[entry.thumbnailUrl], started)) {
                  _thumbnailLoads.remove(entry.thumbnailUrl);
                }
              });
      _thumbnailLoads[entry.thumbnailUrl] = started;
      load = started;
    }
    return _copyThumbnail(await load);
  }

  GiphyThumbnail? _takeCachedThumbnail(Uri uri) {
    final cached = _thumbnailCache.remove(uri);
    if (cached != null) {
      _thumbnailCache[uri] = cached;
    }
    return cached;
  }

  void _cacheThumbnail(Uri uri, GiphyThumbnail thumbnail) {
    if (_closed || thumbnail.body.lengthInBytes > _maximumThumbnailCacheBytes) {
      return;
    }
    final replaced = _thumbnailCache.remove(uri);
    if (replaced != null) {
      _thumbnailCacheBytes -= replaced.body.lengthInBytes;
    }
    while (_thumbnailCache.isNotEmpty &&
        (_thumbnailCache.length >= _maximumCachedThumbnails ||
            _thumbnailCacheBytes + thumbnail.body.lengthInBytes >
                _maximumThumbnailCacheBytes)) {
      final oldest = _thumbnailCache.keys.first;
      final removed = _thumbnailCache.remove(oldest)!;
      _thumbnailCacheBytes -= removed.body.lengthInBytes;
    }
    _thumbnailCache[uri] = thumbnail;
    _thumbnailCacheBytes += thumbnail.body.lengthInBytes;
  }

  GiphyThumbnail _copyThumbnail(GiphyThumbnail thumbnail) =>
      GiphyThumbnail(body: thumbnail.body, contentType: thumbnail.contentType);

  Future<GiphyThumbnail> _loadImage(
    Uri imageUrl, {
    required int maximumBytes,
    Future<void>? abortTrigger,
  }) async {
    if (_closed || !_isSafeThumbnail(server, imageUrl)) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    final deadline = DateTime.now().add(requestTimeout);
    final requestAbort = _RequestAbortSignal(
      deadline: deadline,
      callerTrigger: abortTrigger,
    );
    _ResponseBodyReader? bodyReader;
    try {
      final request =
          http.AbortableRequest(
              'GET',
              imageUrl,
              abortTrigger: requestAbort.trigger,
            )
            ..headers.addAll(<String, String>{
              ...authorization.requestHeaders,
              'Accept': 'image/gif,image/webp,image/png,image/jpeg',
            })
            ..followRedirects = false
            ..maxRedirects = 0;
      final response = await _sendWithDeadline(
        _client.send(request),
        deadline: deadline,
        requestAbort: requestAbort,
      );
      bodyReader = _ResponseBodyReader(response.stream);
      if (response.statusCode != 200) {
        var discarded = 0;
        while (await bodyReader.moveNext(deadline)) {
          discarded += bodyReader.current.length;
          if (discarded > maximumBytes) {
            break;
          }
        }
        throw switch (response.statusCode) {
          401 => const GiphyException(GiphyError.integrationUnavailable),
          429 => const GiphyException(GiphyError.rateLimited, statusCode: 429),
          _ => GiphyException(
            GiphyError.unexpectedStatus,
            statusCode: response.statusCode,
          ),
        };
      }
      final contentLength = response.contentLength;
      if (contentLength != null && contentLength > maximumBytes) {
        throw const GiphyException(GiphyError.responseTooLarge);
      }
      final bytes = BytesBuilder(copy: false);
      var received = 0;
      while (await bodyReader.moveNext(deadline)) {
        final chunk = bodyReader.current;
        received += chunk.length;
        if (received > maximumBytes) {
          throw const GiphyException(GiphyError.responseTooLarge);
        }
        bytes.add(chunk);
      }
      final body = bytes.takeBytes();
      final contentType = response.headers['content-type']
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      if (contentType == null ||
          body.isEmpty ||
          !_matchesThumbnailSignature(contentType, body)) {
        throw const GiphyException(GiphyError.invalidResponse);
      }
      return GiphyThumbnail(body: body, contentType: contentType);
    } on GiphyException {
      rethrow;
    } on http.RequestAbortedException {
      throw GiphyException(requestAbort.error);
    } on TimeoutException {
      requestAbort.abortForDeadline();
      throw GiphyException(requestAbort.error);
    } on http.ClientException {
      throw const GiphyException(GiphyError.network);
    } finally {
      if (bodyReader != null) {
        await bodyReader.cancel(deadline);
      }
      requestAbort.dispose();
    }
  }

  Future<GiphyPage> _fetch({
    required String endpoint,
    required int cursor,
    required int limit,
    String? term,
    Future<void>? abortTrigger,
  }) async {
    if (_closed || cursor < 0 || limit < 1 || limit > 50) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    final pathPrefix = server.basePath;
    final uri = server.uri.replace(
      path: '$pathPrefix/ocs/v2.php/apps/integration_giphy/api/v1/$endpoint',
      queryParameters: <String, String>{
        'term': ?term,
        'cursor': '$cursor',
        'limit': '$limit',
        'format': 'json',
      },
    );
    final deadline = DateTime.now().add(requestTimeout);
    final requestAbort = _RequestAbortSignal(
      deadline: deadline,
      callerTrigger: abortTrigger,
    );
    _ResponseBodyReader? bodyReader;
    try {
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: requestAbort.trigger)
            ..headers.addAll(authorization.requestHeaders)
            ..followRedirects = false
            ..maxRedirects = 0;
      final response = await _sendWithDeadline(
        _client.send(request),
        deadline: deadline,
        requestAbort: requestAbort,
      );
      bodyReader = _ResponseBodyReader(response.stream);
      if (response.statusCode != 200) {
        var discarded = 0;
        while (await bodyReader.moveNext(deadline)) {
          discarded += bodyReader.current.length;
          if (discarded > maximumResponseBytes) {
            break;
          }
        }
        throw switch (response.statusCode) {
          401 || 404 => const GiphyException(GiphyError.integrationUnavailable),
          429 => const GiphyException(GiphyError.rateLimited, statusCode: 429),
          _ => GiphyException(
            GiphyError.unexpectedStatus,
            statusCode: response.statusCode,
          ),
        };
      }
      final contentLength = response.contentLength;
      if (contentLength != null && contentLength > maximumResponseBytes) {
        throw const GiphyException(GiphyError.responseTooLarge);
      }
      final bytes = BytesBuilder(copy: false);
      var received = 0;
      while (await bodyReader.moveNext(deadline)) {
        final chunk = bodyReader.current;
        received += chunk.length;
        if (received > maximumResponseBytes) {
          throw const GiphyException(GiphyError.responseTooLarge);
        }
        bytes.add(chunk);
      }
      return _decodePage(bytes.takeBytes());
    } on GiphyException {
      rethrow;
    } on http.RequestAbortedException {
      throw GiphyException(requestAbort.error);
    } on TimeoutException {
      requestAbort.abortForDeadline();
      throw GiphyException(requestAbort.error);
    } on http.ClientException {
      throw const GiphyException(GiphyError.network);
    } on FormatException {
      throw const GiphyException(GiphyError.invalidResponse);
    } finally {
      if (bodyReader != null) {
        await bodyReader.cancel(deadline);
      }
      requestAbort.dispose();
    }
  }

  Future<({Uri proxiedUrl, double? aspectRatio})> _resolveReference(
    Uri resourceUrl, {
    Future<void>? abortTrigger,
  }) async {
    final uri = server.uri.replace(
      path: '${server.basePath}/ocs/v2.php/references/resolve',
      queryParameters: <String, String>{
        'reference': resourceUrl.toString(),
        'format': 'json',
      },
    );
    final deadline = DateTime.now().add(requestTimeout);
    final requestAbort = _RequestAbortSignal(
      deadline: deadline,
      callerTrigger: abortTrigger,
    );
    _ResponseBodyReader? bodyReader;
    try {
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: requestAbort.trigger)
            ..headers.addAll(authorization.requestHeaders)
            ..followRedirects = false
            ..maxRedirects = 0;
      final response = await _sendWithDeadline(
        _client.send(request),
        deadline: deadline,
        requestAbort: requestAbort,
      );
      bodyReader = _ResponseBodyReader(response.stream);
      if (response.statusCode != 200) {
        var discarded = 0;
        while (await bodyReader.moveNext(deadline)) {
          discarded += bodyReader.current.length;
          if (discarded > maximumResponseBytes) {
            break;
          }
        }
        throw switch (response.statusCode) {
          401 || 404 => const GiphyException(GiphyError.integrationUnavailable),
          429 => const GiphyException(GiphyError.rateLimited, statusCode: 429),
          _ => GiphyException(
            GiphyError.unexpectedStatus,
            statusCode: response.statusCode,
          ),
        };
      }
      final contentLength = response.contentLength;
      if (contentLength != null && contentLength > maximumResponseBytes) {
        throw const GiphyException(GiphyError.responseTooLarge);
      }
      final bytes = BytesBuilder(copy: false);
      var received = 0;
      while (await bodyReader.moveNext(deadline)) {
        final chunk = bodyReader.current;
        received += chunk.length;
        if (received > maximumResponseBytes) {
          throw const GiphyException(GiphyError.responseTooLarge);
        }
        bytes.add(chunk);
      }
      return _decodeReference(bytes.takeBytes(), resourceUrl);
    } on GiphyException {
      rethrow;
    } on http.RequestAbortedException {
      throw GiphyException(requestAbort.error);
    } on TimeoutException {
      requestAbort.abortForDeadline();
      throw GiphyException(requestAbort.error);
    } on http.ClientException {
      throw const GiphyException(GiphyError.network);
    } on FormatException {
      throw const GiphyException(GiphyError.invalidResponse);
    } finally {
      if (bodyReader != null) {
        await bodyReader.cancel(deadline);
      }
      requestAbort.dispose();
    }
  }

  GiphyPage _decodePage(Uint8List bytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    final root = _object(decoded);
    final ocs = _object(root['ocs']);
    final meta = _object(ocs['meta']);
    if (meta['status'] != 'ok' || meta['statuscode'] != 200) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    final data = _object(ocs['data']);
    final rawEntries = data['entries'];
    final cursor = data['cursor'];
    if (rawEntries is! List<Object?> ||
        rawEntries.length > 50 ||
        cursor is! int ||
        cursor < 0) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    return GiphyPage(entries: rawEntries.map(_decodeEntry), cursor: cursor);
  }

  ({Uri proxiedUrl, double? aspectRatio}) _decodeReference(
    Uint8List bytes,
    Uri resourceUrl,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    final root = _object(decoded);
    final ocs = _object(root['ocs']);
    final meta = _object(ocs['meta']);
    if (meta['status'] != 'ok' || meta['statuscode'] != 200) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    final data = _object(ocs['data']);
    final references = _object(data['references']);
    final reference = _object(references[resourceUrl.toString()]);
    if (reference['richObjectType'] != 'integration_giphy_gif') {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    final richObject = _object(reference['richObject']);
    final proxiedUrl = _uri(richObject['proxied_url']);
    if (!_isSafeThumbnail(server, proxiedUrl)) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    return (
      proxiedUrl: proxiedUrl,
      aspectRatio: _referenceAspectRatio(richObject['images']),
    );
  }

  GiphyEntry _decodeEntry(Object? raw) {
    final entry = _object(raw);
    final thumbnailUrl = _uri(entry['thumbnailUrl']);
    final resourceUrl = _uri(entry['resourceUrl']);
    final title = _boundedString(entry['title'], maximumLength: 4096);
    final subline = _boundedString(entry['subline'], maximumLength: 4096);
    if (!server.hasSameOrigin(thumbnailUrl) ||
        thumbnailUrl.userInfo.isNotEmpty ||
        thumbnailUrl.fragment.isNotEmpty ||
        thumbnailUrl.path.isEmpty ||
        !isSupportedGiphyResource(resourceUrl)) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    return GiphyEntry(
      thumbnailUrl: thumbnailUrl,
      title: title,
      subline: subline,
      resourceUrl: resourceUrl,
    );
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _prefetchedTrending = null;
    _thumbnailCache.clear();
    _thumbnailLoads.clear();
    _thumbnailCacheBytes = 0;
    _client.close();
  }
}
