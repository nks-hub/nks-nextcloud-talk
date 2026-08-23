import 'dart:convert';
import 'dart:typed_data';

import '../protocol_exception.dart';

final RegExp _pemBodyPattern = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');
const List<int> _rsaEncryptionAlgorithm = <int>[
  0x06,
  0x09,
  0x2a,
  0x86,
  0x48,
  0x86,
  0xf7,
  0x0d,
  0x01,
  0x01,
  0x01,
  0x05,
  0x00,
];

/// A validated RSA-2048 SubjectPublicKeyInfo value safe to send to Nextcloud.
final class PushRsaPublicKey {
  PushRsaPublicKey._({
    required this.pem,
    required this.modulusBits,
    required this.exponent,
    required this._der,
  });

  factory PushRsaPublicKey.parse(String source) {
    if (source.isEmpty || source.length > 4096 || source.contains('\u0000')) {
      _cryptoFailure(r'$.publicKey');
    }
    final normalized = source.replaceAll('\r\n', '\n');
    if (normalized.contains('\r')) {
      _cryptoFailure(r'$.publicKey');
    }
    final lines = normalized.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    if (lines.length < 3 ||
        lines.first != '-----BEGIN PUBLIC KEY-----' ||
        lines.last != '-----END PUBLIC KEY-----') {
      _cryptoFailure(r'$.publicKey');
    }
    final bodyLines = lines.sublist(1, lines.length - 1);
    if (bodyLines.isEmpty ||
        bodyLines.any(
          (line) =>
              line.isEmpty ||
              line.length > 64 ||
              !_pemBodyPattern.hasMatch(line),
        )) {
      _cryptoFailure(r'$.publicKey');
    }
    final body = bodyLines.join();
    Uint8List der;
    try {
      der = base64Decode(body);
      if (base64Encode(der) != body) {
        _cryptoFailure(r'$.publicKey');
      }
    } on FormatException {
      _cryptoFailure(r'$.publicKey');
    }

    final parsed = _parseRsaSubjectPublicKeyInfo(der);
    if (parsed.modulusBits != 2048) {
      _cryptoFailure(r'$.publicKey.modulus');
    }
    final canonicalBody = base64Encode(der);
    final canonicalLines = <String>[];
    for (var offset = 0; offset < canonicalBody.length; offset += 64) {
      final end = offset + 64 < canonicalBody.length
          ? offset + 64
          : canonicalBody.length;
      canonicalLines.add(canonicalBody.substring(offset, end));
    }
    final pem =
        '-----BEGIN PUBLIC KEY-----\n'
        '${canonicalLines.join('\n')}\n'
        '-----END PUBLIC KEY-----\n';
    return PushRsaPublicKey._(
      pem: pem,
      modulusBits: parsed.modulusBits,
      exponent: parsed.exponent,
      der: Uint8List.fromList(der),
    );
  }

  final String pem;
  final int modulusBits;
  final int exponent;
  final Uint8List _der;

  @override
  bool operator ==(Object other) =>
      other is PushRsaPublicKey && _constantListEquals(_der, other._der);

  @override
  int get hashCode => Object.hashAll(_der);

  @override
  String toString() => 'PushRsaPublicKey(rsa2048, material: <redacted>)';
}

_ParsedRsaKey _parseRsaSubjectPublicKeyInfo(Uint8List der) {
  final outer = _DerReader(der);
  final root = outer.readConstructed(0x30);
  outer.requireFinished();
  final algorithm = root.readConstructed(0x30);
  final algorithmBody = algorithm.readRemaining();
  if (!_constantListEquals(algorithmBody, _rsaEncryptionAlgorithm)) {
    _cryptoFailure(r'$.publicKey.algorithm');
  }
  final bitString = root.readValue(0x03);
  root.requireFinished();
  if (bitString.isEmpty || bitString.first != 0) {
    _cryptoFailure(r'$.publicKey.bitString');
  }

  final bitStringReader = _DerReader(Uint8List.sublistView(bitString, 1));
  final keyReader = bitStringReader.readConstructed(0x30);
  bitStringReader.requireFinished();
  final modulus = keyReader.readValue(0x02);
  final exponentBytes = keyReader.readValue(0x02);
  keyReader.requireFinished();
  _validatePositiveInteger(modulus, r'$.publicKey.modulus');
  _validatePositiveInteger(exponentBytes, r'$.publicKey.exponent');

  final meaningfulModulus = modulus.first == 0
      ? Uint8List.sublistView(modulus, 1)
      : modulus;
  if (meaningfulModulus.isEmpty || meaningfulModulus.first < 0x80) {
    _cryptoFailure(r'$.publicKey.modulus');
  }
  final modulusBits =
      (meaningfulModulus.length - 1) * 8 +
      _unsignedBitLength(meaningfulModulus.first);

  if (exponentBytes.length > 4) {
    _cryptoFailure(r'$.publicKey.exponent');
  }
  var exponent = 0;
  for (final byte in exponentBytes) {
    exponent = (exponent << 8) | byte;
  }
  if (exponent < 3 || exponent.isEven) {
    _cryptoFailure(r'$.publicKey.exponent');
  }
  return _ParsedRsaKey(modulusBits, exponent);
}

void _validatePositiveInteger(Uint8List value, String path) {
  if (value.isEmpty || (value.first & 0x80) != 0) {
    _cryptoFailure(path);
  }
  if (value.length > 1 && value.first == 0 && (value[1] & 0x80) == 0) {
    _cryptoFailure(path);
  }
}

int _unsignedBitLength(int value) {
  var bits = 0;
  var current = value;
  while (current != 0) {
    bits++;
    current >>= 1;
  }
  return bits;
}

bool _constantListEquals(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

final class _DerReader {
  _DerReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  _DerReader readConstructed(int tag) => _DerReader(readValue(tag));

  Uint8List readValue(int expectedTag) {
    if (_offset >= _bytes.length || _bytes[_offset++] != expectedTag) {
      _cryptoFailure(r'$.publicKey.der');
    }
    final length = _readLength();
    if (length < 0 || _offset + length > _bytes.length) {
      _cryptoFailure(r'$.publicKey.der');
    }
    final value = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return value;
  }

  int _readLength() {
    if (_offset >= _bytes.length) {
      _cryptoFailure(r'$.publicKey.der');
    }
    final first = _bytes[_offset++];
    if ((first & 0x80) == 0) {
      return first;
    }
    final count = first & 0x7f;
    if (count == 0 || count > 4 || _offset + count > _bytes.length) {
      _cryptoFailure(r'$.publicKey.der');
    }
    if (_bytes[_offset] == 0) {
      _cryptoFailure(r'$.publicKey.der');
    }
    var length = 0;
    for (var index = 0; index < count; index++) {
      length = (length << 8) | _bytes[_offset++];
    }
    if (length < 128) {
      _cryptoFailure(r'$.publicKey.der');
    }
    return length;
  }

  Uint8List readRemaining() {
    final value = Uint8List.sublistView(_bytes, _offset);
    _offset = _bytes.length;
    return value;
  }

  void requireFinished() {
    if (_offset != _bytes.length) {
      _cryptoFailure(r'$.publicKey.der');
    }
  }
}

final class _ParsedRsaKey {
  const _ParsedRsaKey(this.modulusBits, this.exponent);

  final int modulusBits;
  final int exponent;
}

Never _cryptoFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidPushCryptoMaterial, path);
