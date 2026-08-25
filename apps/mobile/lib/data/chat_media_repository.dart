import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:talk_protocol/talk_protocol.dart';

import 'app_database.dart';
import 'credential_vault.dart';

enum ChatMediaRepositoryError {
  credentialMissing,
  invalidUri,
  invalidResponse,
  responseTooLarge,
  unavailable,
}

final class ChatMediaRepositoryException implements Exception {
  const ChatMediaRepositoryException(this.code);

  final ChatMediaRepositoryError code;

  @override
  String toString() => 'ChatMediaRepositoryException(${code.name})';
}

final class ChatVoiceFile {
  const ChatVoiceFile({required this.path, required this.contentType});

  final String path;
  final String contentType;
}

final class ChatMediaImage {
  ChatMediaImage({required Uint8List body, required this.contentType})
    : body = Uint8List.fromList(body);

  final Uint8List body;
  final String contentType;
}

final class ChatMediaRepository {
  ChatMediaRepository(
    this._credentials, {
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  static const int _maximumPreviewBytes = 8 * 1024 * 1024;
  static const int _maximumVoiceBytes = 32 * 1024 * 1024;

  final CredentialVault _credentials;
  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;

  /// Materialises a voice message inside [directory] so a platform player can
  /// open it. The bytes never leave the account origin and the response is
  /// bounded, because a chat peer controls the file.
  Future<ChatVoiceFile> loadVoiceFile({
    required StoredAccount account,
    required Uri uri,
    required Directory directory,
    required String cacheKey,
  }) async {
    final server = ServerBase.parse(account.serverUrl);
    if (!server.hasSameOrigin(uri) ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.invalidUri,
      );
    }
    final appPassword = await _credentials.readAppPassword(account.id);
    if (appPassword == null) {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.credentialMissing,
      );
    }
    final credentials = base64Encode(
      utf8.encode('${account.loginName}:$appPassword'),
    );
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers.addAll({
        'Accept': 'audio/*',
        'OCS-APIRequest': 'true',
        'Authorization': 'Basic $credentials',
      });
    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(requestTimeout);
    } on Object {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.unavailable,
      );
    }
    if (response.statusCode != 200) {
      await _discard(response);
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.unavailable,
      );
    }
    if ((response.contentLength ?? 0) > _maximumVoiceBytes) {
      await _discard(response);
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.responseTooLarge,
      );
    }
    final contentType = response.headers['content-type']
        ?.split(';')
        .first
        .trim()
        .toLowerCase();
    if (contentType == null || !contentType.startsWith('audio/')) {
      await _discard(response);
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.invalidResponse,
      );
    }

    final builder = BytesBuilder(copy: false);
    var length = 0;
    final iterator = StreamIterator<List<int>>(response.stream);
    try {
      await (() async {
        while (await iterator.moveNext()) {
          length += iterator.current.length;
          if (length > _maximumVoiceBytes) {
            throw const ChatMediaRepositoryException(
              ChatMediaRepositoryError.responseTooLarge,
            );
          }
          builder.add(iterator.current);
        }
      })().timeout(requestTimeout);
    } on ChatMediaRepositoryException {
      rethrow;
    } on Object {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.unavailable,
      );
    } finally {
      try {
        await iterator.cancel().timeout(requestTimeout);
      } on Object {
        // The response is already complete or unusable.
      }
    }
    final body = builder.takeBytes();
    if (body.isEmpty) {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.invalidResponse,
      );
    }
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}$cacheKey',
    );
    await file.writeAsBytes(body, flush: true);
    return ChatVoiceFile(path: file.path, contentType: contentType);
  }

  Future<ChatMediaImage?> loadPreview({
    required StoredAccount account,
    required Uri uri,
  }) async {
    final server = ServerBase.parse(account.serverUrl);
    if (!_isAllowedPreviewUri(server, uri)) {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.invalidUri,
      );
    }
    final appPassword = await _credentials.readAppPassword(account.id);
    if (appPassword == null) {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.credentialMissing,
      );
    }

    final credentials = base64Encode(
      utf8.encode('${account.loginName}:$appPassword'),
    );
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers.addAll({
        'Accept': 'image/png,image/jpeg,image/webp,image/gif',
        'OCS-APIRequest': 'true',
        'Authorization': 'Basic $credentials',
      });
    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(requestTimeout);
    } on Object {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.unavailable,
      );
    }
    if (response.statusCode == 404) {
      await _discard(response);
      return null;
    }
    if (response.statusCode != 200) {
      await _discard(response);
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.unavailable,
      );
    }
    if ((response.contentLength ?? 0) > _maximumPreviewBytes) {
      await _discard(response);
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.responseTooLarge,
      );
    }

    final builder = BytesBuilder(copy: false);
    var length = 0;
    final iterator = StreamIterator<List<int>>(response.stream);
    try {
      await (() async {
        while (await iterator.moveNext()) {
          final chunk = iterator.current;
          length += chunk.length;
          if (length > _maximumPreviewBytes) {
            throw const ChatMediaRepositoryException(
              ChatMediaRepositoryError.responseTooLarge,
            );
          }
          builder.add(chunk);
        }
      })().timeout(requestTimeout);
    } on ChatMediaRepositoryException {
      rethrow;
    } on Object {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.unavailable,
      );
    } finally {
      try {
        await iterator.cancel().timeout(requestTimeout);
      } on Object {
        // The response is already complete or unusable. Cancellation is only
        // a bounded best effort to release the connection promptly.
      }
    }
    final body = builder.takeBytes();
    final contentType = response.headers['content-type']
        ?.split(';')
        .first
        .trim()
        .toLowerCase();
    if (contentType == null ||
        body.isEmpty ||
        !_matchesImageSignature(contentType, body)) {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.invalidResponse,
      );
    }
    return ChatMediaImage(body: body, contentType: contentType);
  }

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }

  Future<void> _discard(http.StreamedResponse response) async {
    try {
      await response.stream.drain<void>().timeout(requestTimeout);
    } on Object {
      // The response is already unusable. The bounded drain only gives the
      // client a chance to reuse its connection without delaying the UI.
    }
  }
}

bool _isAllowedPreviewUri(ServerBase server, Uri uri) {
  if (!server.hasSameOrigin(uri) ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    return false;
  }
  final expectedPath = <String>[
    ...server.uri.pathSegments,
    'index.php',
    'core',
    'preview',
  ];
  if (uri.pathSegments.length != expectedPath.length) {
    return false;
  }
  for (var index = 0; index < expectedPath.length; index++) {
    if (uri.pathSegments[index] != expectedPath[index]) {
      return false;
    }
  }
  const allowedKeys = {'fileId', 'x', 'y', 'a'};
  if (uri.queryParametersAll.keys.any((key) => !allowedKeys.contains(key)) ||
      uri.queryParametersAll.values.any((values) => values.length != 1)) {
    return false;
  }
  final fileId = int.tryParse(uri.queryParameters['fileId'] ?? '');
  final width = int.tryParse(uri.queryParameters['x'] ?? '');
  final height = int.tryParse(uri.queryParameters['y'] ?? '');
  final crop = uri.queryParameters['a'];
  return fileId != null &&
      fileId > 0 &&
      width != null &&
      width >= 1 &&
      width <= 2048 &&
      height != null &&
      height >= 1 &&
      height <= 2048 &&
      (crop == '0' || crop == '1');
}

bool _matchesImageSignature(String contentType, Uint8List body) {
  bool startsWith(List<int> signature) {
    if (body.length < signature.length) {
      return false;
    }
    for (var index = 0; index < signature.length; index++) {
      if (body[index] != signature[index]) {
        return false;
      }
    }
    return true;
  }

  return switch (contentType) {
    'image/png' => startsWith(const [
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
    ]),
    'image/jpeg' => startsWith(const [0xff, 0xd8, 0xff]),
    'image/gif' =>
      startsWith(ascii.encode('GIF87a')) || startsWith(ascii.encode('GIF89a')),
    'image/webp' =>
      body.length >= 12 &&
          startsWith(ascii.encode('RIFF')) &&
          ascii.decode(body.sublist(8, 12), allowInvalid: true) == 'WEBP',
    _ => false,
  };
}
