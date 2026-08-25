import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:nextcloudtalk/features/chat/media/authenticated_image_viewer.dart';

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
}) {
  return localizedTestApp(
    home: MediaQuery(
      data: MediaQueryData(size: const Size(320, 640), textScaler: textScaler),
      child: _ViewerLauncher(repository: repository),
    ),
  );
}

final class _ViewerLauncher extends StatelessWidget {
  const _ViewerLauncher({required this.repository});

  final ChatMediaRepository repository;

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
            imageName: 'Synthetic image',
            repository: repository,
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
