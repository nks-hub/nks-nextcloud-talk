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
    final viewport = LocationMapViewport.around(
      latitude: widget.location.latitude,
      longitude: widget.location.longitude,
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
                    painter: LocationSchematicPainter(
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
              label: locationMapAttribution,
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
    final viewport = LocationMapViewport.around(
      latitude: widget.location.latitude,
      longitude: widget.location.longitude,
      width: width,
      height: _previewHeight,
      zoom: _zoom,
    );
    final loaded = await LocationTileLoader(client).load(viewport.tiles);
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
