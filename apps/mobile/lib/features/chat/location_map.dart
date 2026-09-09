import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Builds the HTTP client the map tiles are fetched with, per account.
typedef LocationTileClientFactory = http.Client Function(String accountId);

/// Identifies this client to the OpenStreetMap infrastructure, which requires
/// a User-Agent naming the application.
const String locationMapUserAgent = 'NKS Talk/0.1 (com.nkshub.nextcloudtalk)';

/// Shown wherever OpenStreetMap data reaches the screen, as ODbL requires.
const String locationMapAttribution = '© OpenStreetMap contributors';

/// The most tiles any one map view may request.
///
/// Four covers a viewport of up to 256 x 256 logical pixels, which is what
/// both the message preview and the picker draw. It is also the budget the
/// OpenStreetMap tile usage policy expects from a client like this one: a
/// larger map would multiply requests on every pan.
const int locationMapMaximumTiles = 4;

const double _tileSize = 256;

/// A square of the web Mercator projection, positioned in a map view.
final class LocationMapTile {
  const LocationMapTile({
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

/// The tiles covering a map view centred on one point, and the projection
/// needed to read a coordinate back out of a tap.
final class LocationMapViewport {
  const LocationMapViewport._(
    this.tiles,
    this.zoom,
    this._originX,
    this._originY,
    this._worldSize,
  );

  factory LocationMapViewport.around({
    required double latitude,
    required double longitude,
    required double width,
    required double height,
    required int zoom,
  }) {
    final tileCount = 1 << zoom;
    final worldSize = tileCount * _tileSize;
    final clampedLatitude = latitude.clamp(-85.05112878, 85.05112878);
    final latitudeRadians = clampedLatitude * math.pi / 180;
    final worldX = (longitude + 180) / 360 * worldSize;
    final worldY =
        (1 -
            math.log(
                  math.tan(latitudeRadians) + 1 / math.cos(latitudeRadians),
                ) /
                math.pi) /
        2 *
        worldSize;
    final originX = worldX - width / 2;
    final originY = worldY - height / 2;
    final firstX = (originX / _tileSize).floor();
    final lastX = ((originX + width - 0.001) / _tileSize).floor();
    final firstY = (originY / _tileSize).floor();
    final lastY = ((originY + height - 0.001) / _tileSize).floor();
    final tiles = <LocationMapTile>[];
    tileRows:
    for (var worldTileY = firstY; worldTileY <= lastY; worldTileY++) {
      if (worldTileY < 0 || worldTileY >= tileCount) {
        continue;
      }
      for (var worldTileX = firstX; worldTileX <= lastX; worldTileX++) {
        if (tiles.length == locationMapMaximumTiles) {
          break tileRows;
        }
        final tileX = ((worldTileX % tileCount) + tileCount) % tileCount;
        tiles.add(
          LocationMapTile(
            x: tileX,
            y: worldTileY,
            left: worldTileX * _tileSize - originX,
            top: worldTileY * _tileSize - originY,
            uri: Uri.https(
              'tile.openstreetmap.org',
              '/$zoom/$tileX/$worldTileY.png',
            ),
          ),
        );
      }
    }
    return LocationMapViewport._(
      List.unmodifiable(tiles),
      zoom,
      originX,
      originY,
      worldSize,
    );
  }

  final List<LocationMapTile> tiles;
  final int zoom;
  final double _originX;
  final double _originY;
  final double _worldSize;

  /// The longitude drawn at [dx] logical pixels from the view's left edge.
  double longitudeAt(double dx) {
    final world = (_originX + dx) % _worldSize;
    return world / _worldSize * 360 - 180;
  }

  /// The latitude drawn at [dy] logical pixels from the view's top edge.
  double latitudeAt(double dy) {
    final world = (_originY + dy).clamp(0.0, _worldSize);
    final n = math.pi - 2 * math.pi * world / _worldSize;
    return 180 / math.pi * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
  }
}

/// Fetches map tiles, bounded in count, size and time.
final class LocationTileLoader {
  const LocationTileLoader(this.client);

  static const maximumTileBytes = 256 * 1024;
  static const timeout = Duration(seconds: 8);
  static const maximumConcurrentRequests = 2;
  final http.Client client;

  Future<Map<String, Uint8List>> load(List<LocationMapTile> tiles) async {
    final boundedTiles = tiles
        .take(locationMapMaximumTiles)
        .toList(growable: false);
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

  Future<Uint8List?> _loadTile(LocationMapTile tile) async {
    if (!_isTrustedTileUri(tile.uri)) {
      return null;
    }
    try {
      final request = http.Request('GET', tile.uri)
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers['User-Agent'] = locationMapUserAgent;
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

/// Stands in for a map while no tiles have been fetched, so a location still
/// reads as a place rather than as an empty box.
final class LocationSchematicPainter extends CustomPainter {
  const LocationSchematicPainter({
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
  bool shouldRepaint(LocationSchematicPainter oldDelegate) =>
      background != oldDelegate.background || street != oldDelegate.street;
}
