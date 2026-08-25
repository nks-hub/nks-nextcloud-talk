import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../../network/attachment_transport.dart';
import 'giphy.dart';

typedef LoadGiphyReference =
    Future<GiphyReferenceMedia> Function(
      Uri resourceUrl, {
      Future<void>? abortTrigger,
    });

final class GiphyAttachmentPayload {
  GiphyAttachmentPayload({
    required Uint8List body,
    required this.mimeType,
    required this.displayName,
  }) : body = Uint8List.fromList(body);

  final Uint8List body;
  final String mimeType;
  final String displayName;
}

final class GiphyAttachmentLoader {
  const GiphyAttachmentLoader(this._loadReference);

  final LoadGiphyReference _loadReference;

  Future<GiphyAttachmentPayload> load(
    GiphyEntry entry, {
    AttachmentCancellationSignal? cancellationSignal,
  }) async {
    final abort = cancellationSignal == null ? null : Completer<void>.sync();
    final registration = cancellationSignal?.register(() {
      if (!abort!.isCompleted) {
        abort.complete();
      }
    });
    try {
      final media = await _loadReference(
        entry.resourceUrl,
        abortTrigger: abort?.future,
      );
      if (cancellationSignal?.isCancelled ?? false) {
        throw const GiphyException(GiphyError.cancelled);
      }
      if (media.resourceUrl != entry.resourceUrl ||
          media.contentType != 'image/gif' ||
          !_hasGifHeader(media.body)) {
        throw const GiphyException(GiphyError.invalidResponse);
      }
      final digest = sha256.convert(media.body).toString();
      return GiphyAttachmentPayload(
        body: media.body,
        mimeType: media.contentType,
        displayName: 'giphy-${digest.substring(0, 16)}.gif',
      );
    } finally {
      registration?.detach();
    }
  }
}

bool _hasGifHeader(Uint8List body) {
  if (body.length < 10) {
    return false;
  }
  final gif87a =
      body[0] == 0x47 &&
      body[1] == 0x49 &&
      body[2] == 0x46 &&
      body[3] == 0x38 &&
      body[4] == 0x37 &&
      body[5] == 0x61;
  final gif89a =
      body[0] == 0x47 &&
      body[1] == 0x49 &&
      body[2] == 0x46 &&
      body[3] == 0x38 &&
      body[4] == 0x39 &&
      body[5] == 0x61;
  if (!gif87a && !gif89a) {
    return false;
  }
  final width = body[6] | (body[7] << 8);
  final height = body[8] | (body[9] << 8);
  return width > 0 && height > 0;
}
