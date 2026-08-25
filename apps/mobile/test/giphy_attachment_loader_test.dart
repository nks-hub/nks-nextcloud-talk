import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/giphy.dart';
import 'package:nextcloudtalk/features/chat/composer/giphy_attachment.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';

void main() {
  const gifBytes = <int>[
    0x47,
    0x49,
    0x46,
    0x38,
    0x39,
    0x61,
    0x01,
    0x00,
    0x01,
    0x00,
  ];
  final entry = GiphyEntry(
    thumbnailUrl: Uri.parse(
      'https://cloud.example.invalid/apps/integration_giphy/gif/wave',
    ),
    title: 'Wave',
    subline: 'Fixture author',
    resourceUrl: Uri.parse('https://giphy.com/gifs/wave'),
  );

  test(
    'loads the resolved GIF as a deterministic attachment payload',
    () async {
      Uri? requestedResource;
      final loader = GiphyAttachmentLoader((resourceUrl, {abortTrigger}) async {
        requestedResource = resourceUrl;
        return GiphyReferenceMedia(
          resourceUrl: resourceUrl,
          body: Uint8List.fromList(gifBytes),
          contentType: 'image/gif',
          aspectRatio: 1,
        );
      });

      final payload = await loader.load(entry);

      expect(requestedResource, entry.resourceUrl);
      expect(payload.body, gifBytes);
      expect(payload.mimeType, 'image/gif');
      expect(
        payload.displayName,
        matches(RegExp(r'^giphy-[0-9a-f]{16}\.gif$')),
      );

      final repeated = await loader.load(entry);
      expect(repeated.displayName, payload.displayName);
    },
  );

  test('forwards attachment cancellation to the reference request', () async {
    final requestAborted = Completer<void>();
    final requestStarted = Completer<void>();
    final loader = GiphyAttachmentLoader((resourceUrl, {abortTrigger}) async {
      requestStarted.complete();
      await abortTrigger;
      requestAborted.complete();
      throw const GiphyException(GiphyError.cancelled);
    });
    final cancellation = AttachmentCancellationController();

    final loading = loader.load(entry, cancellationSignal: cancellation.signal);
    final cancellationExpectation = expectLater(
      loading,
      throwsA(
        isA<GiphyException>().having(
          (error) => error.error,
          'error',
          GiphyError.cancelled,
        ),
      ),
    );
    await requestStarted.future;
    cancellation.cancel();

    await cancellationExpectation;
    await requestAborted.future;
  });

  test('rejects a resolved response for a different resource', () async {
    final loader = GiphyAttachmentLoader((resourceUrl, {abortTrigger}) async {
      return GiphyReferenceMedia(
        resourceUrl: Uri.parse('https://giphy.com/gifs/different'),
        body: Uint8List.fromList(gifBytes),
        contentType: 'image/gif',
        aspectRatio: 1,
      );
    });

    await expectLater(
      loader.load(entry),
      throwsA(
        isA<GiphyException>().having(
          (error) => error.error,
          'error',
          GiphyError.invalidResponse,
        ),
      ),
    );
  });
}
