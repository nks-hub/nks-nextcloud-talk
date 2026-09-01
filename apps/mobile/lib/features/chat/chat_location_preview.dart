part of 'chat_message_content.dart';

final class _LocationTileScope extends InheritedWidget {
  const _LocationTileScope({
    required this.accountId,
    required this.clientFactory,
    required super.child,
  });

  final String accountId;
  final LocationTileClientFactory clientFactory;

  static _LocationTileScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LocationTileScope>();

  @override
  bool updateShouldNotify(_LocationTileScope oldWidget) =>
      accountId != oldWidget.accountId ||
      !identical(clientFactory, oldWidget.clientFactory);
}

final class _LocationTileLoader {
  const _LocationTileLoader(this.client);

  static const maximumTileBytes = 256 * 1024;
  static const timeout = Duration(seconds: 8);
  static const maximumConcurrentRequests = 2;
  final http.Client client;

  Future<Map<String, Uint8List>> load(List<_LocationMapTile> tiles) async {
    final boundedTiles = tiles.take(4).toList(growable: false);
    final results = <String, Uint8List>{};
    var nextIndex = 0;

    Future<void> worker() async {
      while (nextIndex < boundedTiles.length) {
        final tile = boundedTiles[nextIndex++];
        final bytes = await _loadTile(tile);
        if (bytes != null) {
          results[tile.cacheKey] = bytes;
        }
      }
    }

    await Future.wait<void>([
      for (
        var index = 0;
        index < math.min(maximumConcurrentRequests, boundedTiles.length);
        index++
      )
        worker(),
    ]);
    return Map.unmodifiable(results);
  }

  Future<Uint8List?> _loadTile(_LocationMapTile tile) async {
    if (!_isTrustedTileUri(tile.uri)) {
      return null;
    }
    try {
      final request = http.Request('GET', tile.uri)
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers['User-Agent'] = 'NKS Talk/0.1 (com.nkshub.nextcloudtalk)';
      final response = await client.send(request).timeout(timeout);
      if (response.statusCode != 200 ||
          response.headers['content-type']?.split(';').first.trim() !=
              'image/png' ||
          (response.contentLength ?? 0) > maximumTileBytes) {
        return null;
      }
      final body = await _readBounded(response);
      if (body == null) {
        return null;
      }
      if (body.length < 8 ||
          body[0] != 0x89 ||
          body[1] != 0x50 ||
          body[2] != 0x4e ||
          body[3] != 0x47 ||
          body[4] != 0x0d ||
          body[5] != 0x0a ||
          body[6] != 0x1a ||
          body[7] != 0x0a) {
        return null;
      }
      return body;
    } on Object {
      return null;
    }
  }

  Future<Uint8List?> _readBounded(http.StreamedResponse response) async {
    final bytes = BytesBuilder(copy: false);
    final completion = Completer<Uint8List?>();
    late final StreamSubscription<List<int>> subscription;
    var length = 0;
    subscription = response.stream.listen(
      (chunk) {
        length += chunk.length;
        if (length > maximumTileBytes) {
          unawaited(subscription.cancel());
          if (!completion.isCompleted) {
            completion.complete(null);
          }
          return;
        }
        bytes.add(chunk);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completion.isCompleted) {
          completion.complete(null);
        }
      },
      onDone: () {
        if (!completion.isCompleted) {
          completion.complete(bytes.takeBytes());
        }
      },
      cancelOnError: true,
    );
    final timer = Timer(timeout, () {
      unawaited(subscription.cancel());
      if (!completion.isCompleted) {
        completion.complete(null);
      }
    });
    try {
      return await completion.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }

  bool _isTrustedTileUri(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'tile.openstreetmap.org' &&
      !uri.hasPort &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      uri.userInfo.isEmpty;
}

final class _LocationSchematicPainter extends CustomPainter {
  const _LocationSchematicPainter({
    required this.background,
    required this.street,
  });

  final Color background;
  final Color street;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(background, BlendMode.src);
    final thin = Paint()
      ..color = street.withValues(alpha: 0.45)
      ..strokeWidth = 1.5;
    for (var part = 1; part < 4; part++) {
      final x = size.width * part / 4;
      final y = size.height * part / 4;
      canvas
        ..drawLine(Offset(x, 0), Offset(x, size.height), thin)
        ..drawLine(Offset(0, y), Offset(size.width, y), thin);
    }
    final road = Paint()
      ..color = street
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;
    canvas
      ..drawLine(
        Offset(-8, size.height * 0.82),
        Offset(size.width + 8, size.height * 0.18),
        road,
      )
      ..drawLine(
        Offset(size.width * 0.18, -8),
        Offset(size.width * 0.76, size.height + 8),
        road,
      );
  }

  @override
  bool shouldRepaint(_LocationSchematicPainter oldDelegate) =>
      background != oldDelegate.background || street != oldDelegate.street;
}

final class _LocationPreviewStrings {
  const _LocationPreviewStrings(this.loadOnlineMap);

  factory _LocationPreviewStrings.of(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'cs'
      ? const _LocationPreviewStrings(
          'Načíst online mapu OpenStreetMap (odešle souřadnice)',
        )
      : const _LocationPreviewStrings(
          'Load online OpenStreetMap (shares coordinates)',
        );

  final String loadOnlineMap;
}

final class _LocationMapViewport {
  const _LocationMapViewport(this.tiles);

  factory _LocationMapViewport.fromLocation(
    ChatGeoLocation location, {
    required double width,
    required double height,
    required int zoom,
  }) {
    final tileCount = 1 << zoom;
    final latitude = location.latitude.clamp(-85.05112878, 85.05112878);
    final latitudeRadians = latitude * math.pi / 180;
    final worldX = (location.longitude + 180) / 360 * tileCount * 256;
    final worldY =
        (1 -
            math.log(
                  math.tan(latitudeRadians) + 1 / math.cos(latitudeRadians),
                ) /
                math.pi) /
        2 *
        tileCount *
        256;
    final firstX = ((worldX - width / 2) / 256).floor();
    final lastX = ((worldX + width / 2 - 0.001) / 256).floor();
    final firstY = ((worldY - height / 2) / 256).floor();
    final lastY = ((worldY + height / 2 - 0.001) / 256).floor();
    final tiles = <_LocationMapTile>[];
    tileRows:
    for (var worldTileY = firstY; worldTileY <= lastY; worldTileY++) {
      if (worldTileY < 0 || worldTileY >= tileCount) {
        continue;
      }
      for (var worldTileX = firstX; worldTileX <= lastX; worldTileX++) {
        if (tiles.length == 4) {
          break tileRows;
        }
        final tileX = ((worldTileX % tileCount) + tileCount) % tileCount;
        tiles.add(
          _LocationMapTile(
            x: tileX,
            y: worldTileY,
            left: worldTileX * 256 - (worldX - width / 2),
            top: worldTileY * 256 - (worldY - height / 2),
            uri: Uri.https(
              'tile.openstreetmap.org',
              '/$zoom/$tileX/$worldTileY.png',
            ),
          ),
        );
      }
    }
    return _LocationMapViewport(List.unmodifiable(tiles));
  }

  final List<_LocationMapTile> tiles;
}

final class _LocationMapTile {
  const _LocationMapTile({
    required this.x,
    required this.y,
    required this.left,
    required this.top,
    required this.uri,
  });

  final int x;
  final int y;
  final double left;
  final double top;
  final Uri uri;

  String get cacheKey => '$x/$y';
}

final class _ChatLocationPreview extends StatefulWidget {
  const _ChatLocationPreview({required this.location});

  final ChatGeoLocation location;

  @override
  State<_ChatLocationPreview> createState() => _ChatLocationPreviewState();
}

final class _ChatLocationPreviewState extends State<_ChatLocationPreview> {
  static const _previewWidth = 240.0;
  static const _previewHeight = 120.0;
  static const _tileSize = 256.0;
  static const _zoom = 16;
  static const _attribution = '© OpenStreetMap contributors';
  static final _copyrightUri = Uri.https('www.openstreetmap.org', '/copyright');

  String? _accountId;
  LocationTileClientFactory? _clientFactory;
  http.Client? _client;
  Map<String, Uint8List> _tiles = const <String, Uint8List>{};
  var _generation = 0;
  var _loading = false;
  var _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = _LocationTileScope.maybeOf(context);
    if (_accountId == scope?.accountId &&
        identical(_clientFactory, scope?.clientFactory)) {
      return;
    }
    _generation++;
    _client?.close();
    _client = null;
    _tiles = const <String, Uint8List>{};
    _loading = false;
    _failed = false;
    _accountId = scope?.accountId;
    _clientFactory = scope?.clientFactory;
  }

  @override
  void dispose() {
    _generation++;
    _client?.close();
    _client = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final previewStrings = _LocationPreviewStrings.of(context);
    final scheme = Theme.of(context).colorScheme;
    final width = math
        .min(
          _previewWidth,
          math.max(48.0, MediaQuery.sizeOf(context).width - 64),
        )
        .toDouble();
    final viewport = _LocationMapViewport.fromLocation(
      widget.location,
      width: width,
      height: _previewHeight,
      zoom: _zoom,
    );

    void openLocation() {
      unawaited(
        launchUrl(
          widget.location.openStreetMapUri,
          mode: LaunchMode.externalApplication,
        ),
      );
    }

    void openAttribution() {
      unawaited(launchUrl(_copyrightUri, mode: LaunchMode.externalApplication));
    }

    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            container: true,
            link: true,
            label: strings.openLocation(widget.location.label),
            onTap: openLocation,
            excludeSemantics: true,
            child: Material(
              color: scheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(10),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: const Key('chat-location-map-preview'),
                onTap: openLocation,
                child: SizedBox(
                  height: _previewHeight,
                  child: CustomPaint(
                    painter: _LocationSchematicPainter(
                      background: scheme.surfaceContainerHighest,
                      street: scheme.outline,
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        for (final tile in viewport.tiles)
                          if (_tiles.containsKey(tile.cacheKey))
                            Positioned(
                              left: tile.left,
                              top: tile.top,
                              width: _tileSize,
                              height: _tileSize,
                              child: ExcludeSemantics(
                                child: Image.memory(
                                  _tiles[tile.cacheKey]!,
                                  key: Key(
                                    'chat-location-tile-${tile.x}-${tile.y}',
                                  ),
                                  fit: BoxFit.fill,
                                  // A redrawn tile keeps the one already on
                                  // screen instead of blanking for a frame.
                                  gaplessPlayback: true,
                                  cacheWidth: 256,
                                  cacheHeight: 256,
                                  filterQuality: FilterQuality.low,
                                  errorBuilder: (context, error, stackTrace) =>
                                      const SizedBox.shrink(),
                                ),
                              ),
                            ),
                        Center(
                          child: Icon(
                            Icons.location_on,
                            key: const Key('chat-location-map-marker'),
                            size: 36,
                            color: scheme.error,
                            shadows: const <Shadow>[
                              Shadow(color: Colors.white, blurRadius: 3),
                            ],
                          ),
                        ),
                        Positioned(
                          left: 8,
                          right: 8,
                          bottom: 8,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: scheme.surface.withValues(alpha: 0.88),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              child: Text(
                                widget.location.label,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(color: scheme.onSurface),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_tiles.isNotEmpty)
            _locationFooterLink(
              scheme: scheme,
              label: _attribution,
              key: const Key('chat-location-map-attribution'),
              onTap: openAttribution,
              link: true,
            )
          else
            _onlineMapControl(scheme, strings, previewStrings),
        ],
      ),
    );
  }

  Widget _onlineMapControl(
    ColorScheme scheme,
    AppLocalizations strings,
    _LocationPreviewStrings previewStrings,
  ) {
    if (_loading) {
      return _locationFooter(
        scheme: scheme,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Flexible(child: Text(strings.loadingImage)),
          ],
        ),
      );
    }
    return _locationFooter(
      scheme: scheme,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_failed)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Text(strings.imageLoadFailed, textAlign: TextAlign.center),
            ),
          Semantics(
            button: true,
            label: previewStrings.loadOnlineMap,
            excludeSemantics: true,
            child: InkWell(
              key: const Key('chat-location-online-opt-in'),
              onTap: _accountId == null ? null : _loadOnlineMap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.public, size: 20),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          previewStrings.loadOnlineMap,
                          textAlign: TextAlign.center,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _locationFooter({
    required ColorScheme scheme,
    required Widget child,
  }) => Material(
    color: scheme.surfaceContainerHigh,
    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
    clipBehavior: Clip.antiAlias,
    child: child,
  );

  Widget _locationFooterLink({
    required ColorScheme scheme,
    required String label,
    required Key key,
    required VoidCallback onTap,
    required bool link,
  }) => Semantics(
    container: true,
    link: link,
    label: label,
    onTap: onTap,
    excludeSemantics: true,
    child: _locationFooter(
      scheme: scheme,
      child: InkWell(
        key: key,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Center(
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> _loadOnlineMap() async {
    final accountId = _accountId;
    final clientFactory = _clientFactory;
    if (_loading || accountId == null || clientFactory == null) {
      return;
    }
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failed = false;
    });
    late final http.Client client;
    try {
      client = clientFactory(accountId);
    } on Object {
      if (_owns(generation, accountId)) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
      return;
    }
    _client = client;
    final width = math
        .min(
          _previewWidth,
          math.max(48.0, MediaQuery.sizeOf(context).width - 64),
        )
        .toDouble();
    final viewport = _LocationMapViewport.fromLocation(
      widget.location,
      width: width,
      height: _previewHeight,
      zoom: _zoom,
    );
    final loaded = await _LocationTileLoader(client).load(viewport.tiles);
    client.close();
    if (!_owns(generation, accountId)) {
      return;
    }
    _client = null;
    setState(() {
      _loading = false;
      _tiles = loaded;
      _failed = loaded.isEmpty;
    });
  }

  bool _owns(int generation, String accountId) =>
      mounted && generation == _generation && accountId == _accountId;
}
