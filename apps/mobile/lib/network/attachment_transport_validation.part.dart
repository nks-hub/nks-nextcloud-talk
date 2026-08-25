part of 'attachment_transport.dart';

AttachmentTransportException _normalizePreDispatchFailure(
  Object error,
  AttachmentRequestStep step,
  AttachmentTransportStage stage,
) => error is AttachmentTransportException
    ? error
    : _transportFailure(
        AttachmentTransportError.sourceUnavailable,
        step,
        stage,
      );

AttachmentTransportException _normalizePostDispatchFailure(
  Object error,
  AttachmentRequestStep step,
  AttachmentTransportStage stage, {
  int? statusCode,
}) => error is AttachmentTransportException
    ? error
    : _transportFailure(
        AttachmentTransportError.network,
        step,
        stage,
        statusCode: statusCode,
        requestMayHaveReachedServer: true,
      );

AttachmentTransportException _transportFailure(
  AttachmentTransportError code,
  AttachmentRequestStep step,
  AttachmentTransportStage stage, {
  int? statusCode,
  TalkProtocolErrorCode? protocolCode,
  bool requestMayHaveReachedServer = false,
}) => AttachmentTransportException(
  code,
  step: step,
  stage: stage,
  statusCode: statusCode,
  protocolCode: protocolCode,
  requestMayHaveReachedServer: requestMayHaveReachedServer,
);

void _validateOrigin(AttachmentRequest request) {
  final uri = request.uri;
  if (!request.server.hasSameOrigin(uri) ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw _transportFailure(
      AttachmentTransportError.invalidOrigin,
      request.step,
      AttachmentTransportStage.authorization,
    );
  }
  if (request is! AttachmentDavRequest ||
      request.step != AttachmentRequestStep.chunkMove) {
    return;
  }
  final rawDestination = request.headers['Destination'];
  final destination = rawDestination == null
      ? null
      : Uri.tryParse(rawDestination);
  if (destination == null ||
      !request.server.hasSameOrigin(destination) ||
      destination.userInfo.isNotEmpty ||
      destination.query.isNotEmpty ||
      destination.fragment.isNotEmpty) {
    throw _transportFailure(
      AttachmentTransportError.invalidOrigin,
      request.step,
      AttachmentTransportStage.authorization,
    );
  }
}

void _validateSourceChunk(
  List<int> chunk,
  AttachmentRequestStep step, {
  required AttachmentTransportStage stage,
  required bool requestMayHaveReachedServer,
}) {
  if (chunk.any((value) => value < 0 || value > 255)) {
    throw _transportFailure(
      AttachmentTransportError.sourceChanged,
      step,
      stage,
      requestMayHaveReachedServer: requestMayHaveReachedServer,
    );
  }
}

String _methodName(AttachmentHttpMethod method) => switch (method) {
  AttachmentHttpMethod.post => 'POST',
  AttachmentHttpMethod.put => 'PUT',
  AttachmentHttpMethod.mkcol => 'MKCOL',
  AttachmentHttpMethod.propfind => 'PROPFIND',
  AttachmentHttpMethod.move => 'MOVE',
  AttachmentHttpMethod.delete => 'DELETE',
};

String _basicAuthorization(AttachmentTransportAuthorization authorization) =>
    'Basic ${base64Encode(utf8.encode('${authorization.loginName}:'
    '${authorization.appPassword}'))}';

final class _Sha256Digest {
  static const int _mask = 0xffffffff;
  static const List<int> _roundConstants = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];

  final List<int> _state = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  final Uint8List _block = Uint8List(64);
  int _blockLength = 0;
  int _messageLength = 0;
  bool _closed = false;

  void add(List<int> bytes) {
    if (_closed) {
      throw StateError('Digest is already closed.');
    }
    for (final byte in bytes) {
      _block[_blockLength++] = byte;
      _messageLength++;
      if (_blockLength == 64) {
        _compress();
        _blockLength = 0;
      }
    }
  }

  String close() {
    if (_closed) {
      throw StateError('Digest is already closed.');
    }
    _closed = true;
    final bitLength = _messageLength * 8;
    _block[_blockLength++] = 0x80;
    if (_blockLength > 56) {
      while (_blockLength < 64) {
        _block[_blockLength++] = 0;
      }
      _compress();
      _blockLength = 0;
    }
    while (_blockLength < 56) {
      _block[_blockLength++] = 0;
    }
    for (var shift = 56; shift >= 0; shift -= 8) {
      _block[_blockLength++] = (bitLength >> shift) & 0xff;
    }
    _compress();
    return _state
        .map((value) => value.toRadixString(16).padLeft(8, '0'))
        .join();
  }

  void _compress() {
    final words = Uint32List(64);
    for (var index = 0; index < 16; index++) {
      final offset = index * 4;
      words[index] =
          (_block[offset] << 24) |
          (_block[offset + 1] << 16) |
          (_block[offset + 2] << 8) |
          _block[offset + 3];
    }
    for (var index = 16; index < 64; index++) {
      final left = words[index - 15];
      final right = words[index - 2];
      final sigma0 =
          _rotateRight(left, 7) ^ _rotateRight(left, 18) ^ (left >>> 3);
      final sigma1 =
          _rotateRight(right, 17) ^ _rotateRight(right, 19) ^ (right >>> 10);
      words[index] =
          (words[index - 16] + sigma0 + words[index - 7] + sigma1) & _mask;
    }

    var a = _state[0];
    var b = _state[1];
    var c = _state[2];
    var d = _state[3];
    var e = _state[4];
    var f = _state[5];
    var g = _state[6];
    var h = _state[7];
    for (var index = 0; index < 64; index++) {
      final sum1 =
          _rotateRight(e, 6) ^ _rotateRight(e, 11) ^ _rotateRight(e, 25);
      final choose = (e & f) ^ ((~e) & g);
      final temporary1 =
          (h + sum1 + choose + _roundConstants[index] + words[index]) & _mask;
      final sum0 =
          _rotateRight(a, 2) ^ _rotateRight(a, 13) ^ _rotateRight(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final temporary2 = (sum0 + majority) & _mask;
      h = g;
      g = f;
      f = e;
      e = (d + temporary1) & _mask;
      d = c;
      c = b;
      b = a;
      a = (temporary1 + temporary2) & _mask;
    }

    _state[0] = (_state[0] + a) & _mask;
    _state[1] = (_state[1] + b) & _mask;
    _state[2] = (_state[2] + c) & _mask;
    _state[3] = (_state[3] + d) & _mask;
    _state[4] = (_state[4] + e) & _mask;
    _state[5] = (_state[5] + f) & _mask;
    _state[6] = (_state[6] + g) & _mask;
    _state[7] = (_state[7] + h) & _mask;
  }

  int _rotateRight(int value, int count) =>
      ((value >>> count) | (value << (32 - count))) & _mask;
}
