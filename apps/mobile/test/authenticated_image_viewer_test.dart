import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:nextcloudtalk/features/chat/media/authenticated_image_viewer.dart';
import 'package:nextcloudtalk/features/chat/media/chat_image_exporter.dart';

import 'test_support.dart';

void main() {
  testWidgets('opens an authorized 2048 preview with accessible zoom controls', (
    tester,
  ) async {
    late http.BaseRequest captured;
    final repository = _repository((request) async {
      captured = request;
      return _imageResponse();
    });

    await tester.pumpWidget(
      _app(repository: repository, textScaler: const TextScaler.linear(2)),
    );
    await tester.tap(find.byKey(const Key('open-synthetic-image')));
    await _pumpRouteAndFuture(tester);

    expect(find.byKey(const Key('authenticated-image-viewer')), findsOneWidget);
    expect(
      find.byKey(const Key('authenticated-image-fullscreen')),
      findsOneWidget,
    );
    expect(captured.url, _previewUri);
    expect(
      captured.headers['Authorization'],
      'Basic ${base64Encode(utf8.encode('fixture-user:fixture-app-password'))}',
    );

    for (final key in <String>[
      'authenticated-image-close',
      'authenticated-image-zoom-out',
      'authenticated-image-reset-zoom',
      'authenticated-image-zoom-in',
    ]) {
      final size = tester.getSize(find.byKey(Key(key)));
      expect(size.width, greaterThanOrEqualTo(48), reason: key);
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
    }

    await tester.tap(find.byKey(const Key('authenticated-image-zoom-in')));
    await tester.pump();
    final zoomOut = tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(const Key('authenticated-image-zoom-out')),
        matching: find.byType(IconButton),
      ),
    );
    expect(zoomOut.onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('authenticated-image-reset-zoom')));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('authenticated-image-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('authenticated-image-viewer')), findsNothing);
  });

  testWidgets('button zoom keeps the picture centred in the viewport', (
    tester,
  ) async {
    final repository = _repository((request) async => _imageResponse());
    await tester.pumpWidget(_app(repository: repository));
    await tester.tap(find.byKey(const Key('open-synthetic-image')));
    await _pumpRouteAndFuture(tester);

    final viewer = find.byKey(
      const Key('authenticated-image-interactive-viewer'),
    );
    final centreBefore = tester.getCenter(
      find.byKey(const Key('authenticated-image-fullscreen')),
    );
    final viewportCentre = tester.getCenter(viewer);
    expect(
      (centreBefore - viewportCentre).distance,
      lessThan(1),
      reason: 'the unzoomed picture starts centred',
    );

    await tester.tap(find.byKey(const Key('authenticated-image-zoom-in')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('authenticated-image-zoom-in')));
    await tester.pump();

    final centreAfter = tester.getCenter(
      find.byKey(const Key('authenticated-image-fullscreen')),
    );
    expect(
      (centreAfter - viewportCentre).distance,
      lessThan(1),
      reason: 'zooming around the child origin walks the picture off screen',
    );
  });

  testWidgets('replaces a failed load with the image after retry', (
    tester,
  ) async {
    var requestCount = 0;
    final repository = _repository((_) async {
      requestCount++;
      if (requestCount == 1) {
        return http.StreamedResponse(const Stream<List<int>>.empty(), 503);
      }
      return _imageResponse();
    });

    await tester.pumpWidget(_app(repository: repository));
    await tester.tap(find.byKey(const Key('open-synthetic-image')));
    await _pumpRouteAndFuture(tester);

    expect(find.byKey(const Key('authenticated-image-retry')), findsOneWidget);
    await tester.tap(find.byKey(const Key('authenticated-image-retry')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(requestCount, 2);
    expect(
      find.byKey(const Key('authenticated-image-fullscreen')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('saving downloads and exports the original instead of preview', (
    tester,
  ) async {
    final exporter = _RecordingExporter();
    await tester.pumpWidget(
      _app(
        repository: _repository(_previewAndOriginalResponse),
        exporter: exporter,
        imageName: 'holiday photo (1).JPG',
      ),
    );
    await tester.tap(find.byKey(const Key('open-synthetic-image')));
    await _pumpRouteAndFuture(tester);

    await tester.tap(find.byKey(const Key('authenticated-image-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(exporter.saved, hasLength(1));
    expect(exporter.saved.single.contentType, 'image/png');
    expect(exporter.saved.single.bytes, _originalPng.length);
    expect(
      exporter.saved.single.fileName,
      'holiday_photo__1_',
      reason: 'a peer-supplied name is never passed through as a path',
    );
    expect(find.text('Image saved to your gallery.'), findsOneWidget);
  });

  testWidgets('a refused gallery permission is spoken out, not swallowed', (
    tester,
  ) async {
    final exporter = _RecordingExporter(
      saveResult: ChatImageSaveResult.permissionDenied,
    );
    await tester.pumpWidget(
      _app(
        repository: _repository((_) async => _imageResponse()),
        exporter: exporter,
      ),
    );
    await tester.tap(find.byKey(const Key('open-synthetic-image')));
    await _pumpRouteAndFuture(tester);

    await tester.tap(find.byKey(const Key('authenticated-image-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      find.textContaining('Grant it in the system settings'),
      findsOneWidget,
    );
  });

  testWidgets('sharing downloads and offers the original bytes', (
    tester,
  ) async {
    final exporter = _RecordingExporter();
    await tester.pumpWidget(
      _app(
        repository: _repository(_previewAndOriginalResponse),
        exporter: exporter,
      ),
    );
    await tester.tap(find.byKey(const Key('open-synthetic-image')));
    await _pumpRouteAndFuture(tester);

    await tester.tap(find.byKey(const Key('authenticated-image-share')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(exporter.shared, hasLength(1));
    expect(exporter.shared.single.contentType, 'image/png');
    expect(exporter.shared.single.bytes, _originalPng.length);
    expect(
      find.byType(SnackBar),
      findsNothing,
      reason: 'a dismissed sheet is not an error',
    );
  });

  testWidgets('an unavailable share sheet is reported', (tester) async {
    await tester.pumpWidget(
      _app(
        repository: _repository((_) async => _imageResponse()),
        exporter: _RecordingExporter(shareOffered: false),
      ),
    );
    await tester.tap(find.byKey(const Key('open-synthetic-image')));
    await _pumpRouteAndFuture(tester);

    await tester.tap(find.byKey(const Key('authenticated-image-share')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('The image could not be shared.'), findsOneWidget);
  });

  testWidgets('a failed original download never exports preview bytes', (
    tester,
  ) async {
    final exporter = _RecordingExporter();
    await tester.pumpWidget(
      _app(
        repository: _repository((request) async {
          if (request.url == _originalUri) {
            return http.StreamedResponse(
              Stream<List<int>>.value(const <int>[1, 2, 3]),
              503,
            );
          }
          return _imageResponse();
        }),
        exporter: exporter,
      ),
    );
    await tester.tap(find.byKey(const Key('open-synthetic-image')));
    await _pumpRouteAndFuture(tester);

    await tester.tap(find.byKey(const Key('authenticated-image-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(exporter.saved, isEmpty);
    expect(find.text('The image could not be saved.'), findsOneWidget);
  });

  testWidgets('save and share stay disabled while there is nothing to export', (
    tester,
  ) async {
    final exporter = _RecordingExporter();
    await tester.pumpWidget(
      _app(
        repository: _repository(
          (_) async =>
              http.StreamedResponse(const Stream<List<int>>.empty(), 503),
        ),
        exporter: exporter,
      ),
    );
    await tester.tap(find.byKey(const Key('open-synthetic-image')));
    await _pumpRouteAndFuture(tester);

    expect(find.byKey(const Key('authenticated-image-retry')), findsOneWidget);
    for (final key in <String>[
      'authenticated-image-save',
      'authenticated-image-share',
    ]) {
      final button = tester.widget<IconButton>(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull, reason: key);
    }
    expect(exporter.saved, isEmpty);
    expect(exporter.shared, isEmpty);
  });

  group('chatImageBaseName', () {
    test('keeps a plain name and drops the extension', () {
      expect(chatImageBaseName('sunset.jpeg'), 'sunset');
    });

    test('never lets a peer name escape into a path', () {
      expect(chatImageBaseName('../../etc/passwd'), 'passwd');
      expect(chatImageBaseName(r'C:\Windows\system.ini'), 'system');
      expect(chatImageBaseName('a/b\\c.png'), 'c');
    });

    test('falls back when nothing usable is left', () {
      expect(chatImageBaseName(''), 'image');
      expect(chatImageBaseName('...'), 'image');
      expect(chatImageBaseName('/'), 'image');
    });

    test('bounds the length', () {
      expect(chatImageBaseName('a' * 200).length, 64);
    });
  });

  test('the share file name carries the extension for the content type', () {
    expect(
      chatImageFileName(fileName: 'sunset', contentType: 'image/jpeg'),
      'sunset.jpg',
    );
    expect(
      chatImageFileName(fileName: 'sunset', contentType: 'image/png'),
      'sunset.png',
    );
    expect(
      chatImageFileName(fileName: 'sunset', contentType: 'application/x-none'),
      'sunset.img',
    );
  });
}

Future<void> _pumpRouteAndFuture(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 50));
}

Widget _app({
  required ChatMediaRepository repository,
  TextScaler textScaler = TextScaler.noScaling,
  ChatImageExporter? exporter,
  String imageName = 'Synthetic image',
}) {
  return localizedTestApp(
    home: MediaQuery(
      data: MediaQueryData(size: const Size(320, 640), textScaler: textScaler),
      child: _ViewerLauncher(
        repository: repository,
        exporter: exporter ?? _RecordingExporter(),
        imageName: imageName,
      ),
    ),
  );
}

final class _ViewerLauncher extends StatelessWidget {
  const _ViewerLauncher({
    required this.repository,
    required this.exporter,
    required this.imageName,
  });

  final ChatMediaRepository repository;
  final ChatImageExporter exporter;
  final String imageName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: InkWell(
          key: const Key('open-synthetic-image'),
          onTap: () => showAuthenticatedImageViewer(
            context,
            account: _account,
            previewUri: _previewUri,
            originalUri: _originalUri,
            originalContentType: 'image/png',
            imageName: imageName,
            repository: repository,
            exporter: exporter,
          ),
          child: const SizedBox.square(
            dimension: 96,
            child: Icon(Icons.image_outlined),
          ),
        ),
      ),
    );
  }
}

final class _RecordingExporter implements ChatImageExporter {
  _RecordingExporter({
    this.saveResult = ChatImageSaveResult.saved,
    this.shareOffered = true,
  });

  final ChatImageSaveResult saveResult;
  final bool shareOffered;
  final List<({String fileName, String contentType, int bytes})> saved = [];
  final List<({String fileName, String contentType, int bytes})> shared = [];

  @override
  Future<ChatImageSaveResult> saveToGallery({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    saved.add((
      fileName: fileName,
      contentType: contentType,
      bytes: bytes.lengthInBytes,
    ));
    return saveResult;
  }

  @override
  Future<bool> share({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    shared.add((
      fileName: fileName,
      contentType: contentType,
      bytes: bytes.lengthInBytes,
    ));
    return shareOffered;
  }
}

ChatMediaRepository _repository(
  Future<http.StreamedResponse> Function(http.BaseRequest request) handler,
) {
  final vault = MemoryCredentialVault()
    ..values[_account.id] = 'fixture-app-password';
  return ChatMediaRepository(vault, client: _StreamingClient(handler));
}

http.StreamedResponse _imageResponse() => http.StreamedResponse(
  Stream<List<int>>.value(base64Decode(_onePixelPngBase64)),
  200,
  headers: const <String, String>{'content-type': 'image/png'},
);

Future<http.StreamedResponse> _previewAndOriginalResponse(
  http.BaseRequest request,
) async => request.url == _originalUri
    ? http.StreamedResponse(
        Stream<List<int>>.value(_originalPng),
        200,
        headers: const <String, String>{'content-type': 'image/png'},
      )
    : _imageResponse();

const _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGP6zwAAAgcB'
    'ApocMXEAAAAASUVORK5CYII=';

final class _StreamingClient extends http.BaseClient {
  _StreamingClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);
}

const StoredAccount _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 1767225600000,
);

final Uri _previewUri = Uri.parse(
  'https://cloud.example.invalid/index.php/core/preview'
  '?fileId=42&x=2048&y=2048&a=0',
);

final Uri _originalUri = Uri.parse(
  'https://cloud.example.invalid/remote.php/dav/files/'
  'fixture-user/Talk/original.png',
);

final Uint8List _originalPng = Uint8List.fromList(<int>[
  ...base64Decode(_onePixelPngBase64),
  1,
  2,
  3,
  4,
]);
