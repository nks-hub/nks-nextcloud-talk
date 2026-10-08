import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_cache.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';

import 'test_support.dart';

/// Measured on the reference instance on 17 September 2026: two photos shared
/// from a phone got no preview at all, and `core/preview` answered 404 for
/// every box - 256, 512, 1024 - for good. The bubble then said the image could
/// not be loaded although the file itself downloads fine, so the attachment
/// stands in for the preview the server never made.
void main() {
  test(
    'a file the server has no preview of is shown from the original',
    () async {
      final requested = <Uri>[];
      final container = _container((request) async {
        requested.add(request.url);
        if (request.url.path.endsWith('/core/preview')) {
          return http.StreamedResponse(const Stream.empty(), 404);
        }
        return http.StreamedResponse(
          Stream.value(_jpeg),
          200,
          headers: {'content-type': 'image/jpeg'},
        );
      });
      addTearDown(container.dispose);

      final image = await container.read(
        chatMediaProvider(
          ChatMediaProviderKey(
            account: _account,
            uri: _previewUri,
            originalUri: _originalUri,
            originalContentType: 'image/jpeg',
          ),
        ).future,
      );

      expect(image, isNotNull);
      expect(image!.contentType, 'image/jpeg');
      expect(image.body, _jpeg);
      expect(requested.map((uri) => uri.path), [
        '/index.php/core/preview',
        _originalUri.path,
      ]);
    },
  );

  test(
    'two sizes of the same picture never reach the server together',
    () async {
      var inFlight = 0;
      var overlaps = 0;
      final repository = _repository((request) async {
        inFlight++;
        if (inFlight > 1) overlaps++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        inFlight--;
        return http.StreamedResponse(
          Stream.value(_jpeg),
          200,
          headers: {'content-type': 'image/jpeg'},
        );
      });

      await Future.wait([
        repository.loadPreview(account: _account, uri: _previewUri),
        repository.loadPreview(account: _account, uri: _fullScreenUri),
        repository.loadPreview(account: _account, uri: _previewUri),
      ]);

      expect(overlaps, 0);
    },
  );

  test('pictures that are not the same file still load side by side', () async {
    var peak = 0;
    var inFlight = 0;
    final repository = _repository((request) async {
      inFlight++;
      peak = peak > inFlight ? peak : inFlight;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      inFlight--;
      return http.StreamedResponse(
        Stream.value(_jpeg),
        200,
        headers: {'content-type': 'image/jpeg'},
      );
    });

    await Future.wait([
      repository.loadPreview(account: _account, uri: _previewUri),
      repository.loadPreview(
        account: _account,
        uri: _previewUri.replace(
          queryParameters: <String, String>{
            ..._previewUri.queryParameters,
            'fileId': '1183331',
          },
        ),
      ),
    ]);

    expect(peak, 2, reason: 'the gate is per file, not a global queue');
  });

  test('an original over the preview budget is shrunk, not dropped', () async {
    // Measured on the reference instance on 8 October 2026: Nextcloud 34.0.3
    // lost the stored preview of a 12 MB Retina screenshot when two requests
    // generated it at once, and answered 404 for every new size afterwards.
    // The original was over the 8 MB budget, so the bubble showed no picture.
    final original = BytesBuilder(copy: false)
      ..add(await _png(3000, 1500))
      ..add(Uint8List(ChatMediaRepository.maximumPreviewFallbackBytes));
    final body = original.takeBytes();
    final container = _container((request) async {
      if (request.url.path.endsWith('/core/preview')) {
        return http.StreamedResponse(const Stream.empty(), 404);
      }
      return http.StreamedResponse(
        Stream.value(body),
        200,
        contentLength: body.length,
        headers: {'content-type': 'image/png'},
      );
    });
    addTearDown(container.dispose);

    final image = await container.read(
      chatMediaProvider(
        ChatMediaProviderKey(
          account: _account,
          uri: _previewUri,
          originalUri: _originalUri,
          originalContentType: 'image/png',
        ),
      ).future,
    );

    expect(image, isNotNull);
    expect(image!.contentType, 'image/png');
    expect(
      image.body.length,
      lessThan(ChatMediaRepository.maximumPreviewFallbackBytes),
    );
    final codec = await ui.instantiateImageCodec(image.body);
    final frame = await codec.getNextFrame();
    expect([frame.image.width, frame.image.height], [1024, 512]);
    frame.image.dispose();
    codec.dispose();
  });

  test('without an original the missing preview stays missing', () async {
    final container = _container(
      (request) async => http.StreamedResponse(const Stream.empty(), 404),
    );
    addTearDown(container.dispose);

    final image = await container.read(
      chatMediaProvider(
        ChatMediaProviderKey(account: _account, uri: _previewUri),
      ).future,
    );

    expect(image, isNull);
  });
}

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xff3366cc),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

ChatMediaRepository _repository(
  Future<http.StreamedResponse> Function(http.BaseRequest request) handler,
) {
  final vault = MemoryCredentialVault()
    ..values[_account.id] = 'fixture-app-password';
  final repository = ChatMediaRepository(
    vault,
    client: _StreamingClient(handler),
    previewRetries: const <Duration>[],
  );
  addTearDown(repository.close);
  return repository;
}

ProviderContainer _container(
  Future<http.StreamedResponse> Function(http.BaseRequest request) handler,
) {
  final vault = MemoryCredentialVault()
    ..values[_account.id] = 'fixture-app-password';
  final repository = ChatMediaRepository(
    vault,
    client: _StreamingClient(handler),
    previewRetries: const <Duration>[],
  );
  final directory = Directory.systemTemp.createTempSync('preview-fallback');
  addTearDown(() {
    repository.close();
    directory.deleteSync(recursive: true);
  });
  return ProviderContainer(
    overrides: [
      chatMediaRepositoryProvider.overrideWithValue(repository),
      chatMediaDiskCacheProvider.overrideWithValue(
        ChatMediaDiskCache(rootDirectory: () async => directory),
      ),
    ],
  );
}

final class _StreamingClient extends http.BaseClient {
  _StreamingClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);
}

final Uint8List _jpeg = Uint8List.fromList(const [
  0xff,
  0xd8,
  0xff,
  0xe0,
  0x00,
  0x10,
  0x4a,
  0x46,
  0x49,
  0x46,
]);

final Uri _previewUri = Uri.parse(
  'https://cloud.example.invalid/index.php/core/preview'
  '?fileId=1183325&x=1024&y=1024&a=1',
);

final Uri _fullScreenUri = _previewUri.replace(
  queryParameters: <String, String>{
    ..._previewUri.queryParameters,
    'x': '2048',
    'y': '2048',
  },
);

final Uri _originalUri = Uri.parse(
  'https://cloud.example.invalid/remote.php/dav/files/fixture-user'
  '/Talk/room/photo.jpg',
);

const StoredAccount _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 1767225600000,
);
