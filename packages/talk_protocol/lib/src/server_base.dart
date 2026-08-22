import 'package:punycoder/punycoder.dart';

import 'protocol_exception.dart';

final RegExp _schemePattern = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*$');
final RegExp _dnsLabelPattern = RegExp(
  r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$',
);
final RegExp _pathSegmentPattern = RegExp(r'^[A-Za-z0-9._~-]+$');
final RegExp _decimalPattern = RegExp(r'^[0-9]+$');
const int _maximumServerAddressLength = 4096;

/// Compile-time policy for allowing an HTTP server in a debug-only flow.
final class ServerOriginPolicy {
  const ServerOriginPolicy._({required this.allowDebugHttp});

  /// Strict policy for every production request.
  static const production = ServerOriginPolicy._(allowDebugHttp: false);

  /// Allows HTTP only while the Dart VM is neither a release nor profile VM.
  ///
  /// The VM environment values are compile-time constants, so selecting this
  /// policy cannot enable HTTP in a release or profile build.
  static const debug = ServerOriginPolicy._(
    allowDebugHttp:
        !bool.fromEnvironment('dart.vm.product') &&
        !bool.fromEnvironment('dart.vm.profile'),
  );

  final bool allowDebugHttp;
}

/// A canonical, trusted base URL for one Nextcloud account candidate.
final class ServerBase {
  const ServerBase._(this.uri);

  /// Parses and canonicalizes an untrusted server address.
  factory ServerBase.parse(
    String rawValue, {
    ServerOriginPolicy policy = ServerOriginPolicy.production,
  }) {
    return ServerBase._(_normalizeAbsoluteUri(rawValue, policy: policy));
  }

  final Uri uri;

  String get value => uri.toString();

  String get basePath => uri.path;

  Uri get statusUri => _endpoint('status.php');

  Uri get loginFlowV2Uri => _endpoint('index.php/login/v2');

  Uri get capabilitiesUri => _endpoint(
    'ocs/v2.php/cloud/capabilities',
    queryParameters: const {'format': 'json'},
  );

  bool hasSameOrigin(Uri other) {
    return uri.scheme == other.scheme &&
        uri.host == other.host &&
        uri.port == other.port;
  }

  Uri _endpoint(String relativePath, {Map<String, String>? queryParameters}) {
    final prefix = basePath.isEmpty ? '' : basePath;
    return uri.replace(
      path: '$prefix/$relativePath',
      queryParameters: queryParameters,
    );
  }

  @override
  bool operator ==(Object other) => other is ServerBase && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;

  @override
  String toString() => 'ServerBase($value)';
}

Uri _normalizeAbsoluteUri(
  String rawValue, {
  required ServerOriginPolicy policy,
}) {
  if (rawValue.length > _maximumServerAddressLength ||
      _containsControlCharacter(rawValue) ||
      rawValue.contains(r'\')) {
    protocolFailure(TalkProtocolErrorCode.invalidServerAddress, r'$.server');
  }

  var value = rawValue.trim();
  if (value.isEmpty || value.contains(' ')) {
    protocolFailure(TalkProtocolErrorCode.invalidServerAddress, r'$.server');
  }
  if (!value.contains('://')) {
    value = 'https://$value';
  }

  final separator = value.indexOf('://');
  if (separator <= 0) {
    protocolFailure(TalkProtocolErrorCode.invalidServerAddress, r'$.server');
  }
  final rawScheme = value.substring(0, separator);
  if (!_schemePattern.hasMatch(rawScheme)) {
    protocolFailure(
      TalkProtocolErrorCode.invalidServerAddress,
      r'$.server.scheme',
    );
  }
  final scheme = rawScheme.toLowerCase();
  if (scheme != 'https' && !(policy.allowDebugHttp && scheme == 'http')) {
    protocolFailure(
      TalkProtocolErrorCode.insecureServerAddress,
      r'$.server.scheme',
    );
  }

  final remainder = value.substring(separator + 3);
  if (remainder.contains('?') || remainder.contains('#')) {
    protocolFailure(TalkProtocolErrorCode.invalidServerAddress, r'$.server');
  }
  final pathStart = remainder.indexOf('/');
  final rawAuthority = pathStart < 0
      ? remainder
      : remainder.substring(0, pathStart);
  final rawPath = pathStart < 0 ? '' : remainder.substring(pathStart);
  if (rawAuthority.isEmpty ||
      rawAuthority.endsWith(':') ||
      rawAuthority.contains('@') ||
      rawAuthority.contains('%')) {
    protocolFailure(
      TalkProtocolErrorCode.invalidServerAddress,
      r'$.server.authority',
    );
  }

  final authority = _parseAuthority(rawAuthority);
  final normalizedPath = _normalizePath(rawPath);
  final defaultPort = scheme == 'https' ? 443 : 80;
  final portSuffix = authority.port == null || authority.port == defaultPort
      ? ''
      : ':${authority.port}';
  final host = authority.isIpv6
      ? '[${authority.canonicalHost}]'
      : authority.canonicalHost;
  final normalized = '$scheme://$host$portSuffix$normalizedPath';
  final result = Uri.tryParse(normalized);
  if (result == null || !result.hasAuthority || result.host.isEmpty) {
    protocolFailure(TalkProtocolErrorCode.invalidServerAddress, r'$.server');
  }
  return result;
}

_Authority _parseAuthority(String rawAuthority) {
  if (rawAuthority.startsWith('[')) {
    final closingBracket = rawAuthority.indexOf(']');
    if (closingBracket <= 1) {
      protocolFailure(
        TalkProtocolErrorCode.invalidServerHost,
        r'$.server.host',
      );
    }
    final suffix = rawAuthority.substring(closingBracket + 1);
    if (suffix.isNotEmpty && !suffix.startsWith(':')) {
      protocolFailure(
        TalkProtocolErrorCode.invalidServerAddress,
        r'$.server.authority',
      );
    }
    final port = suffix.isEmpty ? null : _parsePort(suffix.substring(1));
    final rawHost = rawAuthority.substring(1, closingBracket);
    if (rawHost.contains('%')) {
      protocolFailure(
        TalkProtocolErrorCode.invalidServerHost,
        r'$.server.host',
      );
    }
    try {
      final bytes = Uri.parseIPv6Address(rawHost);
      return _Authority(_formatIpv6(bytes), port, isIpv6: true);
    } on FormatException {
      protocolFailure(
        TalkProtocolErrorCode.invalidServerHost,
        r'$.server.host',
      );
    }
  }

  if (rawAuthority.contains('[') ||
      rawAuthority.contains(']') ||
      ':'.allMatches(rawAuthority).length > 1) {
    protocolFailure(TalkProtocolErrorCode.invalidServerHost, r'$.server.host');
  }
  final colon = rawAuthority.lastIndexOf(':');
  final rawHost = colon < 0 ? rawAuthority : rawAuthority.substring(0, colon);
  final port = colon < 0 ? null : _parsePort(rawAuthority.substring(colon + 1));
  if (rawHost.isEmpty || rawHost.endsWith('.')) {
    protocolFailure(TalkProtocolErrorCode.invalidServerHost, r'$.server.host');
  }

  String asciiHost;
  try {
    asciiHost = domainToAscii(rawHost.toLowerCase());
  } on Object {
    protocolFailure(TalkProtocolErrorCode.invalidServerHost, r'$.server.host');
  }
  if (asciiHost.isEmpty || asciiHost.length > 253 || asciiHost.contains('%')) {
    protocolFailure(TalkProtocolErrorCode.invalidServerHost, r'$.server.host');
  }

  final labels = asciiHost.split('.');
  if (labels.length == 4 && labels.every(_decimalPattern.hasMatch)) {
    final canonical = <String>[];
    for (final label in labels) {
      final value = int.tryParse(label);
      if (value == null || value > 255 || label != value.toString()) {
        protocolFailure(
          TalkProtocolErrorCode.invalidServerHost,
          r'$.server.host',
        );
      }
      canonical.add(value.toString());
    }
    return _Authority(canonical.join('.'), port, isIpv6: false);
  }
  if (labels.any((label) => !_dnsLabelPattern.hasMatch(label))) {
    protocolFailure(TalkProtocolErrorCode.invalidServerHost, r'$.server.host');
  }
  return _Authority(asciiHost, port, isIpv6: false);
}

int _parsePort(String rawPort) {
  if (!_decimalPattern.hasMatch(rawPort)) {
    protocolFailure(
      TalkProtocolErrorCode.invalidServerAddress,
      r'$.server.port',
    );
  }
  final port = int.tryParse(rawPort);
  if (port == null || port < 1 || port > 65535) {
    protocolFailure(
      TalkProtocolErrorCode.invalidServerAddress,
      r'$.server.port',
    );
  }
  return port;
}

String _normalizePath(String rawPath) {
  if (rawPath.isEmpty || rawPath == '/') {
    return '';
  }
  var path = rawPath;
  if (!path.startsWith('/')) {
    protocolFailure(TalkProtocolErrorCode.invalidServerPath, r'$.server.path');
  }
  if (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final segments = path.substring(1).split('/');
  if (segments.any(
    (segment) =>
        segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        !_pathSegmentPattern.hasMatch(segment),
  )) {
    protocolFailure(TalkProtocolErrorCode.invalidServerPath, r'$.server.path');
  }
  return path;
}

bool _containsControlCharacter(String value) {
  return value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
}

String _formatIpv6(List<int> bytes) {
  final words = <int>[
    for (var index = 0; index < bytes.length; index += 2)
      (bytes[index] << 8) | bytes[index + 1],
  ];
  var bestStart = -1;
  var bestLength = 0;
  for (var index = 0; index < words.length;) {
    if (words[index] != 0) {
      index++;
      continue;
    }
    final start = index;
    while (index < words.length && words[index] == 0) {
      index++;
    }
    final length = index - start;
    if (length > bestLength && length >= 2) {
      bestStart = start;
      bestLength = length;
    }
  }

  final buffer = StringBuffer();
  for (var index = 0; index < words.length;) {
    if (index == bestStart) {
      buffer.write('::');
      index += bestLength;
      continue;
    }
    if (buffer.isNotEmpty && !buffer.toString().endsWith(':')) {
      buffer.write(':');
    }
    buffer.write(words[index].toRadixString(16));
    index++;
  }
  return buffer.isEmpty ? '::' : buffer.toString();
}

final class _Authority {
  const _Authority(this.canonicalHost, this.port, {required this.isIpv6});

  final String canonicalHost;
  final int? port;
  final bool isIpv6;
}
