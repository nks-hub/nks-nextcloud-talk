import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:talk_protocol/talk_protocol.dart';

import 'app_database.dart';
import 'credential_vault.dart';

part 'chat_media_repository_download.dart';

/// Bytes received so far and, when the server declared one, the total length.
/// A null total means the caller can only show that something is moving.
typedef ChatDownloadProgress = void Function(int received, int? total);

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
  ({int width, int height})? _decodedDimensions;

  ({int width, int height})? get decodedDimensions => _decodedDimensions;

  void rememberDecodedDimensions({required int width, required int height}) {
    assert(width > 0 && height > 0);
    _decodedDimensions ??= (width: width, height: height);
  }
}

final class ChatMediaFile {
  ChatMediaFile({required Uint8List body, required this.contentType})
    : body = Uint8List.fromList(body);

  final Uint8List body;
  final String contentType;
}

final class ChatMediaRepository {
  ChatMediaRepository(
    this._credentials, {
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 20),
    this.previewRetries = const [
      Duration(seconds: 1),
      Duration(seconds: 3),
      Duration(seconds: 6),
    ],
    Future<void> Function(Duration)? wait,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _wait = wait ?? Future<void>.delayed;

  static const int _maximumPreviewBytes = 8 * 1024 * 1024;

  /// Ceiling for an original stood in for a preview the server does not have.
  /// The bytes are decoded into a chat bubble, so this is the preview budget,
  /// not the export one.
  static const int maximumPreviewFallbackBytes = _maximumPreviewBytes;
  static const int _maximumVoiceBytes = 32 * 1024 * 1024;
  static const int _maximumOriginalBytes = 64 * 1024 * 1024;

  /// Ceiling for an attachment streamed to disk. Only a sanity bound: what
  /// really limits this is the free space the write runs into.
  static const int _maximumStoredFileBytes = 2 * 1024 * 1024 * 1024;

  final CredentialVault _credentials;
  final http.Client _client;
  final bool _ownsClient;
  final _suspendedAccounts = <String>{};
  final _requests = <String, Set<_MediaRequest>>{};
  bool _closed = false;

  bool isAccountActive(String accountId) =>
      !_closed && !_suspendedAccounts.contains(accountId);

  /// Stops this account's IO before its files and credentials are removed.
  Future<void> suspendAccount(String accountId) async {
    _suspendedAccounts.add(accountId);
    final pending = _requests[accountId]?.toList() ?? <_MediaRequest>[];
    for (final request in pending) {
      request.cancel();
    }
    await Future.wait(pending.map((request) => request.done.future));
  }

  Future<T> _runForAccount<T>(
    String accountId,
    Future<T> Function(_MediaRequest request) action,
  ) async {
    if (!isAccountActive(accountId)) {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.credentialMissing,
      );
    }
    final request = _MediaRequest();
    (_requests[accountId] ??= {}).add(request);
    try {
      final result = await action(request);
      request.checkActive();
      return result;
    } finally {
      request.finishTransport();
      final requests = _requests[accountId];
      requests?.remove(request);
      if (requests?.isEmpty == true) _requests.remove(accountId);
      request.done.complete();
    }
  }

  /// One preview request per file at a time, keyed by account and file id.
  ///
  /// Measured against Nextcloud 34.0.3 on 18 September 2026: two preview
  /// requests for the same freshly uploaded picture, arriving in the same
  /// second, make the server answer one of them 500 — and sometimes leave the
  /// file permanently broken, because the crashing request deletes the shared
  /// maximum-size preview while the database row for it stays behind. Every
  /// size other than the one that survived then answers 404 for good, which is
  /// exactly what two photos in a conversation ran into.
  ///
  /// The collision is the server's bug, but this client used to supply it: the
  /// bubble asks for 1024, the opened picture for 2048, and a 500 is retried a
  /// second later while the first attempt may still be generating. Asking for
  /// one size at a time removes our half of it.
  final Map<String, Future<void>> _previewGates = <String, Future<void>>{};
  final Duration requestTimeout;

  /// How long to wait before asking again for a preview the server has not
  /// produced yet. One entry per extra attempt.
  final List<Duration> previewRetries;
  final Future<void> Function(Duration) _wait;

  /// Materialises a voice message inside [directory] so a platform player can
  /// open it. The bytes never leave the account origin and the response is
  /// bounded, because a chat peer controls the file.
  Future<ChatVoiceFile> loadVoiceFile({
    required StoredAccount account,
    required Uri uri,
    required Directory directory,
    required String cacheKey,
  }) => _runForAccount(account.id, (operation) async {
    final server = ServerBase.parse(account.serverUrl);
    if (!server.hasSameOrigin(uri) ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.invalidUri,
      );
    }
    final appPassword = await operation.wait(
      _credentials.readAppPassword(account.id),
    );
    operation.checkActive();
    if (appPassword == null) {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.credentialMissing,
      );
    }
    final credentials = base64Encode(
      utf8.encode('${account.loginName}:$appPassword'),
    );
    final request =
        http.AbortableRequest('GET', uri, abortTrigger: operation.aborted)
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers.addAll({
            'Accept': 'audio/*',
            'OCS-APIRequest': 'true',
            'Authorization': 'Basic $credentials',
          });
    final http.StreamedResponse response;
    try {
      response = await operation.wait(
        _client.send(request).timeout(requestTimeout),
      );
    } on Object {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.unavailable,
      );
    }
    if (response.statusCode != 200) {
      await _discard(response, operation);
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.unavailable,
      );
    }
    if ((response.contentLength ?? 0) > _maximumVoiceBytes) {
      await _discard(response, operation);
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
      await _discard(response, operation);
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.invalidResponse,
      );
    }

    final builder = BytesBuilder(copy: false);
    var length = 0;
    final iterator = StreamIterator<List<int>>(response.stream);
    try {
      await (() async {
        while (await operation.wait(iterator.moveNext())) {
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
    operation.checkActive();
    await directory.create(recursive: true);
    operation.checkActive();
    final file = File('${directory.path}${Platform.pathSeparator}$cacheKey');
    await file.writeAsBytes(body, flush: true);
    return ChatVoiceFile(path: file.path, contentType: contentType);
  });

  /// A picture somebody just posted has no preview on the server yet. Measured
  /// against the reference instance on 9 September 2026: the endpoint answers
  /// 500 for the first seconds after the share and 200 afterwards. Asking once
  /// turned that into a permanent "could not be loaded" on the receiving side,
  /// which is what people actually saw, so those attempts are repeated here
  /// before any caller is told the picture is broken.
  ///
  /// Only that kind of failure waits. A 404 is the server saying it has no
  /// preview of this size at all — the same instance serves 1024 and refuses
  /// 2048 for the same file — and repeating it would only delay the caller's
  /// own fallback. A bad address, a missing credential and an oversized or
  /// non-image response are about the request, so they fail immediately too.
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
    return _oneAtATimePerFile(
      '${account.id}|${uri.queryParameters['fileId']}',
      () => _loadPreviewAttempts(account: account, uri: uri),
    );
  }

  /// Runs [action] after whatever is already queued for [key], so that two
  /// sizes of the same picture never reach the server together.
  Future<T> _oneAtATimePerFile<T>(String key, Future<T> Function() action) {
    final previous = _previewGates[key];
    final gate = Completer<void>();
    _previewGates[key] = gate.future;
    Future<T> run() => action().whenComplete(() {
      if (identical(_previewGates[key], gate.future)) {
        _previewGates.remove(key);
      }
      gate.complete();
    });
    return previous == null ? run() : previous.then((_) => run());
  }

  Future<ChatMediaImage?> _loadPreviewAttempts({
    required StoredAccount account,
    required Uri uri,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _loadImage(account: account, uri: uri);
      } on ChatMediaRepositoryException catch (failure) {
        if (failure.code == ChatMediaRepositoryError.invalidResponse) {
          final smaller = _halvedPreviewUri(uri);
          if (smaller == null) rethrow;
          return _loadImage(account: account, uri: smaller);
        }
        if (attempt == previewRetries.length ||
            failure.code != ChatMediaRepositoryError.unavailable) {
          rethrow;
        }
      }
      await _wait(previewRetries[attempt]);
    }
  }

  /// Downloads the preview image Nextcloud generated for a link reference.
  ///
  /// The address is re-checked here even though the resolver already gated it,
  /// so a caller cannot reach an arbitrary endpoint by handing over a URI of
  /// its own choosing.
  Future<ChatMediaImage?> loadReferenceThumbnail({
    required StoredAccount account,
    required Uri uri,
  }) async {
    final server = ServerBase.parse(account.serverUrl);
    if (!isSafeReferenceThumbnail(server: server, thumbnail: uri)) {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.invalidUri,
      );
    }
    return _loadImage(account: account, uri: uri);
  }

  Future<ChatMediaImage?> _loadImage({
    required StoredAccount account,
    required Uri uri,
  }) => _runForAccount(account.id, (operation) async {
    final appPassword = await operation.wait(
      _credentials.readAppPassword(account.id),
    );
    operation.checkActive();
    if (appPassword == null) {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.credentialMissing,
      );
    }

    final credentials = base64Encode(
      utf8.encode('${account.loginName}:$appPassword'),
    );
    final request =
        http.AbortableRequest('GET', uri, abortTrigger: operation.aborted)
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers.addAll({
            'Accept': 'image/png,image/jpeg,image/webp,image/gif',
            'OCS-APIRequest': 'true',
            'Authorization': 'Basic $credentials',
          });
    final http.StreamedResponse response;
    try {
      response = await operation.wait(
        _client.send(request).timeout(requestTimeout),
      );
    } on Object {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.unavailable,
      );
    }
    if (response.statusCode == 404) {
      await _discard(response, operation);
      return null;
    }
    if (response.statusCode != 200) {
      await _discard(response, operation);
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.unavailable,
      );
    }
    if ((response.contentLength ?? 0) > _maximumPreviewBytes) {
      await _discard(response, operation);
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.responseTooLarge,
      );
    }

    final builder = BytesBuilder(copy: false);
    var length = 0;
    final iterator = StreamIterator<List<int>>(response.stream);
    try {
      await (() async {
        while (await operation.wait(iterator.moveNext())) {
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
  });

  /// Downloads the original attachment from this account's WebDAV tree.
  ///
  /// Preview and Files UI endpoints are deliberately rejected. They either
  /// transform the file or return HTML, while export and local open require
  /// the exact authenticated bytes stored in WebDAV.
  Future<ChatMediaFile> loadOriginalFile({
    required StoredAccount account,
    required Uri uri,
    required String expectedContentType,
    ChatDownloadProgress? onProgress,
    int? maximumBytes,
  }) => _runForAccount(account.id, (operation) async {
    final limit = maximumBytes ?? _maximumOriginalBytes;
    final server = ServerBase.parse(account.serverUrl);
    final expected = _normalizedMediaType(expectedContentType);
    if (!_isAllowedOriginalUri(server, account.loginName, uri)) {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.invalidUri,
      );
    }
    if (expected == null || _isHtmlMediaType(expected)) {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.invalidResponse,
      );
    }
    final appPassword = await operation.wait(
      _credentials.readAppPassword(account.id),
    );
    operation.checkActive();
    if (appPassword == null) {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.credentialMissing,
      );
    }
    final credentials = base64Encode(
      utf8.encode('${account.loginName}:$appPassword'),
    );
    final request =
        http.AbortableRequest('GET', uri, abortTrigger: operation.aborted)
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers.addAll({
            'Accept': expected,
            'OCS-APIRequest': 'true',
            'Authorization': 'Basic $credentials',
          });
    final http.StreamedResponse response;
    try {
      response = await operation.wait(
        _client.send(request).timeout(requestTimeout),
      );
    } on Object {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.unavailable,
      );
    }
    if (response.statusCode != 200) {
      await _discard(response, operation);
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.unavailable,
      );
    }
    if ((response.contentLength ?? 0) > limit) {
      await _discard(response, operation);
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.responseTooLarge,
      );
    }
    final received = _normalizedMediaType(response.headers['content-type']);
    final contentType = received == 'application/octet-stream'
        ? expected
        : received;
    if (contentType == null ||
        _isHtmlMediaType(contentType) ||
        !_mediaTypesCompatible(expected, contentType)) {
      await _discard(response, operation);
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.invalidResponse,
      );
    }

    onProgress?.call(0, response.contentLength);
    final body = await _readBoundedBody(
      response,
      maximumBytes: limit,
      operation: operation,
      onProgress: onProgress,
      total: response.contentLength,
    );
    if (body.isEmpty ||
        (contentType.startsWith('image/') &&
            !_matchesImageSignature(contentType, body))) {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.invalidResponse,
      );
    }
    return ChatMediaFile(body: body, contentType: contentType);
  });

  void close() {
    _closed = true;
    for (final requests in _requests.values) {
      for (final request in requests) {
        request.cancel();
      }
    }
    if (_ownsClient) {
      _client.close();
    }
  }

  Future<void> _discard(
    http.StreamedResponse response,
    _MediaRequest operation,
  ) async {
    final subscription = response.stream.listen(null);
    try {
      await operation
          .wait(subscription.asFuture<void>())
          .timeout(requestTimeout);
    } on Object {
      // The response is already unusable. The bounded drain only gives the
      // client a chance to reuse its connection without delaying the UI.
    } finally {
      await subscription.cancel().timeout(requestTimeout);
    }
  }

  Future<Uint8List> _readBoundedBody(
    http.StreamedResponse response, {
    required int maximumBytes,
    required _MediaRequest operation,
    ChatDownloadProgress? onProgress,
    int? total,
  }) async {
    final builder = BytesBuilder(copy: false);
    var length = 0;
    final iterator = StreamIterator<List<int>>(response.stream);
    try {
      await (() async {
        while (await operation.wait(iterator.moveNext())) {
          length += iterator.current.length;
          if (length > maximumBytes) {
            throw const ChatMediaRepositoryException(
              ChatMediaRepositoryError.responseTooLarge,
            );
          }
          builder.add(iterator.current);
          onProgress?.call(length, total);
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
        // The response is complete or unusable.
      }
    }
    return builder.takeBytes();
  }
}

final class _MediaRequest {
  final _abort = Completer<void>();
  final done = Completer<void>();
  final _waiters = <void Function()>{};
  bool _cancelled = false;

  Future<void> get aborted => _abort.future;

  void checkActive() {
    if (_cancelled) {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.credentialMissing,
      );
    }
  }

  Future<T> wait<T>(Future<T> pending) {
    final stopped = Completer<T>();
    void stop() => stopped.completeError(
      const ChatMediaRepositoryException(
        ChatMediaRepositoryError.credentialMissing,
      ),
    );
    _waiters.add(stop);
    final result = Future.any([pending, stopped.future]);
    if (_cancelled) stop();
    return result.whenComplete(() => _waiters.remove(stop));
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    finishTransport();
    for (final stop in _waiters.toList()) {
      stop();
    }
  }

  void finishTransport() {
    if (!_abort.isCompleted) _abort.complete();
  }
}

bool _isAllowedOriginalUri(ServerBase server, String loginName, Uri uri) {
  if (!server.hasSameOrigin(uri) ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      uri.hasQuery) {
    return false;
  }
  final prefix = <String>[
    ...server.uri.pathSegments.where((segment) => segment.isNotEmpty),
    'remote.php',
    'dav',
    'files',
    loginName,
  ];
  final actual = uri.pathSegments;
  if (actual.length <= prefix.length) {
    return false;
  }
  for (var index = 0; index < prefix.length; index++) {
    if (actual[index] != prefix[index]) {
      return false;
    }
  }
  final tail = actual.skip(prefix.length);
  return tail.every(
    (segment) =>
        segment.isNotEmpty &&
        segment != '.' &&
        segment != '..' &&
        !segment.contains('/') &&
        !segment.contains(r'\') &&
        !segment.runes.any((value) => value < 0x20 || value == 0x7f),
  );
}

String? _normalizedMediaType(String? value) {
  final normalized = value?.split(';').first.trim().toLowerCase();
  if (normalized == null ||
      !RegExp(
        r'^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$',
      ).hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

bool _isHtmlMediaType(String value) =>
    value == 'text/html' || value == 'application/xhtml+xml';

bool _mediaTypesCompatible(String expected, String received) {
  if (expected == received) {
    return true;
  }
  return expected.startsWith('image/') && received.startsWith('image/');
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
  const allowedKeys = {'fileId', 'x', 'y', 'a', 'c'};
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

/// The same picture at half the box, or null when there is nothing to halve.
///
/// Measured on the reference instance, 9 September 2026: a server can record a
/// preview it cannot open afterwards. It then answers 200 with an image
/// content type and an HTML error page in the body — its log says "Unable to
/// open preview stream" — and it does so for one box only: the same file came
/// back correctly at 512 and at 2048 while 1024 stayed broken, and deleting
/// the stored preview files did not help because the record is in its file
/// cache. Refusing the HTML is right, but showing a broken picture over one
/// bad cache entry is not, so the smaller box is worth one try. It keeps the
/// aspect ratio, unlike dropping the aspect flag, and it is smaller to fetch.
Uri? _halvedPreviewUri(Uri uri) {
  final width = int.tryParse(uri.queryParameters['x'] ?? '');
  final height = int.tryParse(uri.queryParameters['y'] ?? '');
  if (width == null || height == null || width < 2 || height < 2) {
    return null;
  }
  return uri.replace(
    queryParameters: <String, String>{
      ...uri.queryParameters,
      'x': '${width ~/ 2}',
      'y': '${height ~/ 2}',
    },
  );
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
