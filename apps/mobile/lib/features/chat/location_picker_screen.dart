import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../app_providers.dart';
import '../../l10n/generated/app_localizations.dart';
import 'location_map.dart';
import 'location_share_service.dart';
import 'place_search_service.dart';

/// The place the picker was closed with, ready to be shared.
final class LocationPickerResult {
  const LocationPickerResult({
    required this.latitude,
    required this.longitude,
    required this.name,
  });

  final double latitude;
  final double longitude;
  final String name;
}

/// Picks any place, named, without requiring the device's own position.
///
/// Three of the four ways in need no permission at all: drag or tap the map,
/// type coordinates, or search for a name. Only the fourth, the device's own
/// position, asks for one, so a refused or unavailable GPS leaves the rest of
/// the screen working.
///
/// The map background stays blank until it is asked for. Fetching tiles tells
/// OpenStreetMap which point is being looked at, which is the same bargain
/// the message preview offers, and the same explicit tap accepts it here.
final class LocationPickerScreen extends ConsumerStatefulWidget {
  const LocationPickerScreen({super.key, this.tileClient = http.Client.new});

  final http.Client Function() tileClient;

  @override
  ConsumerState<LocationPickerScreen> createState() =>
      _LocationPickerScreenState();
}

final class _LocationPickerScreenState
    extends ConsumerState<LocationPickerScreen> {
  /// A 256 x 200 map needs at most four tiles, whatever it is centred on, and
  /// fits every phone this app supports. Both properties are the reason the
  /// size is fixed rather than stretched to the screen.
  static const _mapWidth = 256.0;
  static const _mapHeight = 200.0;
  static const _tileSize = 256.0;
  static const _minimumZoom = 2;
  static const _maximumZoom = 18;
  static const _pointZoom = 16;

  /// Panning far enough would otherwise keep every tile it crossed.
  static const _maximumCachedTiles = 64;

  final _latitudeField = TextEditingController();
  final _longitudeField = TextEditingController();
  final _nameField = TextEditingController();
  final _searchField = TextEditingController();

  double? _latitude;
  double? _longitude;
  int _zoom = _minimumZoom;
  var _mapEnabled = false;
  var _loadingTiles = false;
  var _tilesFailed = false;
  var _tiles = const <String, Uint8List>{};
  Timer? _tileDebounce;
  var _tileGeneration = 0;
  http.Client? _client;
  var _locating = false;
  var _searching = false;
  var _results = const <PlaceSuggestion>[];
  String? _message;
  var _syncingFields = false;

  @override
  void initState() {
    super.initState();
    _latitudeField.addListener(_onCoordinateEdited);
    _longitudeField.addListener(_onCoordinateEdited);
  }

  @override
  void dispose() {
    _tileGeneration++;
    _tileDebounce?.cancel();
    _client?.close();
    _latitudeField.dispose();
    _longitudeField.dispose();
    _nameField.dispose();
    _searchField.dispose();
    super.dispose();
  }

  LocationMapViewport get _viewport => LocationMapViewport.around(
    latitude: _latitude ?? 0,
    longitude: _longitude ?? 0,
    width: _mapWidth,
    height: _mapHeight,
    zoom: _zoom,
  );

  void _onCoordinateEdited() {
    if (_syncingFields) {
      return;
    }
    final latitude = _parseCoordinate(_latitudeField.text, 90);
    final longitude = _parseCoordinate(_longitudeField.text, 180);
    setState(() {
      _latitude = latitude;
      _longitude = longitude;
      _message = null;
    });
    if (latitude != null && longitude != null) {
      _scheduleTileLoad();
    }
  }

  void _setPoint(double latitude, double longitude, {String? name, int? zoom}) {
    final boundedLatitude = latitude.clamp(-90.0, 90.0);
    final boundedLongitude = _wrapLongitude(longitude);
    _syncingFields = true;
    _latitudeField.text = _formatCoordinate(boundedLatitude);
    _longitudeField.text = _formatCoordinate(boundedLongitude);
    if (name != null) {
      _nameField.text = name;
    }
    _syncingFields = false;
    setState(() {
      _latitude = boundedLatitude;
      _longitude = boundedLongitude;
      _zoom = zoom ?? _zoom;
      _message = null;
    });
    _scheduleTileLoad();
  }

  void _zoomBy(int steps) {
    setState(() {
      _zoom = (_zoom + steps).clamp(_minimumZoom, _maximumZoom);
    });
    _scheduleTileLoad();
  }

  void _enableMap() {
    setState(() {
      _mapEnabled = true;
      _tilesFailed = false;
    });
    unawaited(_loadTiles());
  }

  void _scheduleTileLoad() {
    if (!_mapEnabled) {
      return;
    }
    _tileDebounce?.cancel();
    // A drag emits an event per frame; without this every one of them would
    // be a round of tile requests.
    _tileDebounce = Timer(
      const Duration(milliseconds: 600),
      () => unawaited(_loadTiles()),
    );
  }

  Future<void> _loadTiles() async {
    if (!_mapEnabled) {
      return;
    }
    final zoom = _zoom;
    final missing = _viewport.tiles
        .where((tile) => !_tiles.containsKey(_tileKey(zoom, tile)))
        .toList(growable: false);
    if (missing.isEmpty) {
      return;
    }
    final generation = ++_tileGeneration;
    setState(() {
      _loadingTiles = true;
      _tilesFailed = false;
    });
    final client = _client ??= widget.tileClient();
    final loaded = await LocationTileLoader(client).load(missing);
    if (!mounted || generation != _tileGeneration) {
      return;
    }
    setState(() {
      _loadingTiles = false;
      _tilesFailed = loaded.isEmpty;
      _tiles = <String, Uint8List>{
        if (_tiles.length < _maximumCachedTiles) ..._tiles,
        for (final entry in loaded.entries) '$zoom/${entry.key}': entry.value,
      };
    });
  }

  Future<void> _useCurrentLocation() async {
    if (_locating) {
      return;
    }
    final strings = AppLocalizations.of(context);
    setState(() {
      _locating = true;
      _message = null;
    });
    try {
      final position = await ref.read(currentLocationSourceProvider).current();
      if (!mounted) {
        return;
      }
      _setPoint(position.latitude, position.longitude, zoom: _pointZoom);
    } on CurrentLocationException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = switch (error.code) {
          CurrentLocationError.servicesDisabled =>
            strings.locationServicesDisabled,
          CurrentLocationError.permissionDenied =>
            strings.locationPermissionDenied,
          CurrentLocationError.permissionDeniedForever =>
            strings.locationPermissionDeniedForever,
          CurrentLocationError.unavailable => strings.locationUnavailable,
        };
      });
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() => _message = strings.locationUnavailable);
    } finally {
      if (mounted) {
        setState(() => _locating = false);
      }
    }
  }

  Future<void> _search() async {
    final query = _searchField.text.trim();
    if (_searching || query.isEmpty) {
      return;
    }
    final strings = AppLocalizations.of(context);
    setState(() {
      _searching = true;
      _message = null;
      _results = const <PlaceSuggestion>[];
    });
    try {
      final results = await ref.read(placeSearchSourceProvider).search(query);
      if (!mounted) {
        return;
      }
      setState(() => _results = results);
    } on PlaceSearchException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = switch (error.code) {
          PlaceSearchError.noResults => strings.locationSearchNoResults,
          PlaceSearchError.rateLimited => strings.locationSearchTooFast,
          PlaceSearchError.unavailable => strings.locationSearchUnavailable,
        };
      });
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() => _message = strings.locationSearchUnavailable);
    } finally {
      if (mounted) {
        setState(() => _searching = false);
      }
    }
  }

  void _confirm() {
    final strings = AppLocalizations.of(context);
    final latitude = _latitude;
    final longitude = _longitude;
    if (latitude == null || longitude == null) {
      setState(() => _message = strings.locationPickerCoordinatesInvalid);
      return;
    }
    // Null Island is what an empty form and a broken sensor both produce, so
    // it is refused rather than posted as a place someone chose.
    if (latitude == 0 && longitude == 0) {
      setState(() => _message = strings.locationPickerCoordinatesZero);
      return;
    }
    final name =
        sanitizedLocationName(_nameField.text) ??
        strings.sharedLocationDefaultName;
    Navigator.of(context).pop(
      LocationPickerResult(
        latitude: latitude,
        longitude: longitude,
        name: name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final message = _message;
    return Scaffold(
      appBar: AppBar(title: Text(strings.locationPickerTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: _map(scheme, strings)),
              const SizedBox(height: 8),
              _mapControls(strings),
              const SizedBox(height: 8),
              _searchRow(strings),
              if (_results.isNotEmpty) _searchResults(scheme),
              const SizedBox(height: 8),
              TextField(
                key: const Key('location-picker-name'),
                controller: _nameField,
                maxLength: 256,
                decoration: InputDecoration(
                  labelText: strings.locationPickerName,
                  counterText: '',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('location-picker-latitude'),
                      controller: _latitudeField,
                      keyboardType: const TextInputType.numberWithOptions(
                        signed: true,
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: strings.locationPickerLatitude,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const Key('location-picker-longitude'),
                      controller: _longitudeField,
                      keyboardType: const TextInputType.numberWithOptions(
                        signed: true,
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: strings.locationPickerLongitude,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    message,
                    key: const Key('location-picker-message'),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('location-picker-cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(strings.cancel),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    key: const Key('location-picker-confirm'),
                    onPressed: _confirm,
                    child: Text(strings.locationPickerUse),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Zoom and the current position sit under the map rather than on it: a
  /// 256 pixel map has no room for controls that also have to be tappable.
  Widget _mapControls(AppLocalizations strings) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      IconButton(
        key: const Key('location-picker-zoom-out'),
        icon: const Icon(Icons.remove),
        tooltip: strings.locationPickerZoomOut,
        onPressed: _zoom <= _minimumZoom ? null : () => _zoomBy(-1),
      ),
      IconButton(
        key: const Key('location-picker-zoom-in'),
        icon: const Icon(Icons.add),
        tooltip: strings.locationPickerZoomIn,
        onPressed: _zoom >= _maximumZoom ? null : () => _zoomBy(1),
      ),
      const SizedBox(width: 8),
      TextButton.icon(
        key: const Key('location-picker-current'),
        icon: const Icon(Icons.my_location, size: 20),
        label: Text(strings.locationPickerCurrent),
        onPressed: _locating ? null : () => unawaited(_useCurrentLocation()),
      ),
    ],
  );

  Widget _map(ColorScheme scheme, AppLocalizations strings) {
    final viewport = _viewport;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: _mapWidth,
          height: _mapHeight,
          child: Material(
            color: scheme.surfaceContainerHighest,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            clipBehavior: Clip.antiAlias,
            child: GestureDetector(
              key: const Key('location-picker-map'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => _setPoint(
                viewport.latitudeAt(details.localPosition.dy),
                viewport.longitudeAt(details.localPosition.dx),
              ),
              onPanUpdate: (details) => _setPoint(
                viewport.latitudeAt(_mapHeight / 2 - details.delta.dy),
                viewport.longitudeAt(_mapWidth / 2 - details.delta.dx),
              ),
              child: CustomPaint(
                painter: LocationSchematicPainter(
                  background: scheme.surfaceContainerHighest,
                  street: scheme.outline,
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    for (final tile in viewport.tiles)
                      if (_tiles.containsKey(_tileKey(_zoom, tile)))
                        Positioned(
                          left: tile.left,
                          top: tile.top,
                          width: _tileSize,
                          height: _tileSize,
                          child: ExcludeSemantics(
                            child: Image.memory(
                              _tiles[_tileKey(_zoom, tile)]!,
                              fit: BoxFit.fill,
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
                        key: const Key('location-picker-marker'),
                        size: 36,
                        color: scheme.error,
                        shadows: const <Shadow>[
                          Shadow(color: Colors.white, blurRadius: 3),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          width: _mapWidth,
          child: Material(
            color: scheme.surfaceContainerHigh,
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: _mapEnabled
                ? _mapFooter(scheme, strings)
                : InkWell(
                    key: const Key('location-picker-load-map'),
                    onTap: _enableMap,
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
                                strings.locationPickerLoadMap,
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
        ),
      ],
    );
  }

  Widget _mapFooter(ColorScheme scheme, AppLocalizations strings) {
    if (_loadingTiles) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
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
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Center(
        child: Text(
          _tilesFailed ? strings.imageLoadFailed : locationMapAttribution,
          key: const Key('location-picker-attribution'),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _searchRow(AppLocalizations strings) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Expanded(
        child: TextField(
          key: const Key('location-picker-search'),
          controller: _searchField,
          textInputAction: TextInputAction.search,
          // Submitting is the only thing that queries the geocoder: its usage
          // policy rules out searching while the name is still being typed.
          onSubmitted: (_) => unawaited(_search()),
          decoration: InputDecoration(labelText: strings.locationSearchHint),
        ),
      ),
      const SizedBox(width: 8),
      _searching
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : IconButton(
              key: const Key('location-picker-search-submit'),
              icon: const Icon(Icons.search),
              tooltip: strings.locationSearchSubmit,
              onPressed: () => unawaited(_search()),
            ),
    ],
  );

  Widget _searchResults(ColorScheme scheme) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var index = 0; index < _results.length; index++)
        ListTile(
          key: Key('location-picker-result-$index'),
          dense: true,
          leading: const Icon(Icons.place_outlined),
          title: Text(
            _results[index].name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () {
            final result = _results[index];
            setState(() => _results = const <PlaceSuggestion>[]);
            _setPoint(
              result.latitude,
              result.longitude,
              name: result.name,
              zoom: _pointZoom,
            );
          },
        ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          locationMapAttribution,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    ],
  );

  String _tileKey(int zoom, LocationMapTile tile) => '$zoom/${tile.cacheKey}';
}

String _formatCoordinate(double value) => value.toStringAsFixed(6);

double? _parseCoordinate(String text, double bound) {
  // A Czech keyboard offers a comma where the parser wants a point.
  final parsed = double.tryParse(text.trim().replaceAll(',', '.'));
  if (parsed == null || !parsed.isFinite || parsed.abs() > bound) {
    return null;
  }
  return parsed;
}

double _wrapLongitude(double value) {
  final wrapped = (value + 180) % 360;
  return (wrapped < 0 ? wrapped + 360 : wrapped) - 180;
}
