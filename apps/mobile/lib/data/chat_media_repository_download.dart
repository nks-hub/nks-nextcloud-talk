part of 'chat_media_repository.dart';

extension ChatMediaDownloads on ChatMediaRepository {
  /// Streams an attachment to disk, waiting for each write before reading on.
  Future<String> downloadOriginalToFile({
    required StoredAccount account,
    required Uri uri,
    required String expectedContentType,
    required File target,
    ChatDownloadProgress? onProgress,
    int maximumBytes = ChatMediaRepository._maximumStoredFileBytes,
  }) => _runForAccount(account.id, (operation) async {
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
    StreamIterator<List<int>>? chunks;
    RandomAccessFile? output;
    var created = false;
    var completed = false;
    try {
      final response = await operation.wait(
        _client.send(request).timeout(requestTimeout),
      );
      chunks = StreamIterator(response.stream);
      if (response.statusCode != 200) {
        throw const ChatMediaRepositoryException(
          ChatMediaRepositoryError.unavailable,
        );
      }
      // IOClient keeps the compressed Content-Length after decoding gzip.
      final encoding = response.headers['content-encoding']?.toLowerCase();
      final total = encoding == null || encoding == 'identity'
          ? response.contentLength
          : null;
      if ((total ?? 0) > maximumBytes) {
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
        throw const ChatMediaRepositoryException(
          ChatMediaRepositoryError.invalidResponse,
        );
      }
      operation.checkActive();
      output = await target.open(mode: FileMode.write);
      created = true;
      var written = 0;
      onProgress?.call(0, total);
      // The timeout measures a stalled network read, not the whole download.
      while (await operation.wait(chunks.moveNext().timeout(requestTimeout))) {
        operation.checkActive();
        final chunk = chunks.current;
        written += chunk.length;
        if (written > maximumBytes) {
          throw const ChatMediaRepositoryException(
            ChatMediaRepositoryError.responseTooLarge,
          );
        }
        await output.writeFrom(chunk);
        onProgress?.call(written, total);
      }
      if (written == 0 || (total != null && total != written)) {
        throw const ChatMediaRepositoryException(
          ChatMediaRepositoryError.invalidResponse,
        );
      }
      await output.flush();
      await output.close();
      output = null;
      operation.checkActive();
      completed = true;
      return contentType;
    } on ChatMediaRepositoryException {
      rethrow;
    } on FileSystemException {
      rethrow;
    } on Object {
      throw const ChatMediaRepositoryException(
        ChatMediaRepositoryError.unavailable,
      );
    } finally {
      operation.finishTransport();
      try {
        await chunks?.cancel().timeout(requestTimeout);
      } on Object {
        // A failed transport must not hide the download or storage error.
      }
      try {
        await output?.close();
      } on FileSystemException {
        // Keep the original storage error while cleaning up the partial file.
      }
      if (created && (!completed || !isAccountActive(account.id))) {
        try {
          await target.delete();
        } on FileSystemException {
          // Account removal or a disconnected drive may have removed it.
        }
      }
    }
  });
}
