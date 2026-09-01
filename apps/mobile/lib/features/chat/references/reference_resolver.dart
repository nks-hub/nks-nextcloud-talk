import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:talk_protocol/talk_protocol.dart';

import '../../../data/account_repository.dart';
import '../../../data/app_database.dart';
import '../../../data/credential_vault.dart';
import '../../../network/nextcloud_api.dart';

const int referenceMaximumResponseBytes = 1024 * 1024;

enum ReferenceResolverError {
  accountMissing,
  originMismatch,
  credentialMissing,
  unsupported,
  cancelled,
  network,
  timeout,
  responseTooLarge,
  invalidResponse,
  reauthenticationRequired,
  rateLimited,
  serviceUnavailable,
}

final class ReferenceResolverException implements Exception {
  const ReferenceResolverException(this.error);

  final ReferenceResolverError error;

  @override
  String toString() => 'ReferenceResolverException(${error.name})';
}

final class ReferenceResolutionTarget {
  ReferenceResolutionTarget({
    required this.accountId,
    required this.server,
    required this.reference,
  }) {
    if (accountId.isEmpty || !isSafeReferenceUri(reference)) {
      throw const ReferenceResolverException(
        ReferenceResolverError.invalidResponse,
      );
    }
  }

  final String accountId;
  final ServerBase server;
  final Uri reference;

  @override
  bool operator ==(Object other) =>
      other is ReferenceResolutionTarget &&
      other.accountId == accountId &&
      other.server.uri == server.uri &&
      other.reference == reference;

  @override
  int get hashCode => Object.hash(accountId, server.uri, reference);

  @override
  String toString() => 'ReferenceResolutionTarget(<redacted>)';
}

final class ReferenceCardData {
  const ReferenceCardData({
    required this.reference,
    required this.title,
    required this.description,
    required this.richObjectType,
    this.thumbnail,
  });

  final Uri reference;
  final String title;
  final String? description;
  final String richObjectType;

  /// Preview image, present only when the server offered one on its own
  /// origin. A third-party address never reaches this field, so rendering it
  /// cannot tell a foreign host that the reader opened the conversation.
  final Uri? thumbnail;

  @override
  String toString() =>
      'ReferenceCardData(type: $richObjectType, content: <redacted>)';
}

abstract interface class ReferenceResolver {
  Future<ReferenceCardData?> resolve(
    ReferenceResolutionTarget target, {
    Future<void>? abortTrigger,
  });
}

final class HttpReferenceResolver implements ReferenceResolver {
  factory HttpReferenceResolver({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    http.Client? client,
    Duration requestTimeout = const Duration(seconds: 10),
    Duration cacheTtl = const Duration(hours: 1),
    Duration negativeCacheTtl = const Duration(minutes: 5),
    int maximumCacheEntries = 128,
    DateTime Function()? clock,
  }) => HttpReferenceResolver._(
    accounts,
    credentials,
    api,
    client ?? http.Client(),
    requestTimeout,
    cacheTtl,
    negativeCacheTtl,
    maximumCacheEntries,
    clock ?? DateTime.now,
  );

  HttpReferenceResolver._(
    this._accounts,
    this._credentials,
    this._api,
    this._client,
    this.requestTimeout,
    this.cacheTtl,
    this.negativeCacheTtl,
    this.maximumCacheEntries,
    this._clock,
  );

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final http.Client _client;
  final DateTime Function() _clock;
  final Duration requestTimeout;
  final Duration cacheTtl;
  final Duration negativeCacheTtl;
  final int maximumCacheEntries;
  final LinkedHashMap<_ReferenceCacheKey, _CachedReference> _cache =
      LinkedHashMap<_ReferenceCacheKey, _CachedReference>();
  final Map<_ReferenceCacheKey, Future<ReferenceCardData?>> _inFlight = {};
  var _closed = false;

  @override
  Future<ReferenceCardData?> resolve(
    ReferenceResolutionTarget target, {
    Future<void>? abortTrigger,
  }) async {
    if (_closed) {
      throw const ReferenceResolverException(
        ReferenceResolverError.invalidResponse,
      );
    }
    final account = await _boundAccount(target);
    final key = _ReferenceCacheKey(
      accountId: account.id,
      loginName: account.loginName,
      server: target.server.uri,
      reference: target.reference,
    );
    final cached = _readCache(key);
    if (cached != null) {
      return cached.value;
    }
    final running = _inFlight[key];
    if (running != null) {
      return _waitForCaller(running, abortTrigger);
    }

    final operation =
        _resolveRemote(
          target: target,
          account: account,
          abortTrigger: null,
        ).then((value) async {
          await _requireUnchangedAccount(target, account);
          if (!_closed) {
            _writeCache(key, value);
          }
          return value;
        });
    _inFlight[key] = operation;
    unawaited(
      operation.then<void>(
        (_) => _removeInFlight(key, operation),
        onError: (Object _, StackTrace _) => _removeInFlight(key, operation),
      ),
    );
    return _waitForCaller(operation, abortTrigger);
  }

  Future<ReferenceCardData?> _waitForCaller(
    Future<ReferenceCardData?> operation,
    Future<void>? abortTrigger,
  ) {
    if (abortTrigger == null) {
      return operation;
    }
    final result = Completer<ReferenceCardData?>();
    operation.then<void>(
      (value) {
        if (!result.isCompleted) {
          result.complete(value);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!result.isCompleted) {
          result.completeError(error, stackTrace);
        }
      },
    );
    abortTrigger.then<void>(
      (_) {
        if (!result.isCompleted) {
          result.completeError(
            const ReferenceResolverException(ReferenceResolverError.cancelled),
          );
        }
      },
      onError: (Object _, StackTrace _) {
        if (!result.isCompleted) {
          result.completeError(
            const ReferenceResolverException(ReferenceResolverError.cancelled),
          );
        }
      },
    );
    return result.future;
  }

  void _removeInFlight(
    _ReferenceCacheKey key,
    Future<ReferenceCardData?> operation,
  ) {
    if (identical(_inFlight[key], operation)) {
      _inFlight.remove(key);
    }
  }

  Future<StoredAccount> _boundAccount(ReferenceResolutionTarget target) async {
    final account = await _accounts.getAccount(target.accountId);
    if (account == null) {
      throw const ReferenceResolverException(
        ReferenceResolverError.accountMissing,
      );
    }
    final ServerBase server;
    try {
      server = ServerBase.parse(account.serverUrl);
    } on TalkProtocolException {
      throw const ReferenceResolverException(
        ReferenceResolverError.invalidResponse,
      );
    }
    if (server.uri != target.server.uri) {
      throw const ReferenceResolverException(
        ReferenceResolverError.originMismatch,
      );
    }
    return account;
  }

  Future<void> _requireUnchangedAccount(
    ReferenceResolutionTarget target,
    StoredAccount expected,
  ) async {
    final current = await _boundAccount(target);
    if (current.loginName != expected.loginName) {
      throw const ReferenceResolverException(
        ReferenceResolverError.originMismatch,
      );
    }
  }

  Future<ReferenceCardData?> _resolveRemote({
    required ReferenceResolutionTarget target,
    required StoredAccount account,
    required Future<void>? abortTrigger,
  }) async {
    final appPassword = await _credentials.readAppPassword(account.id);
    if (appPassword == null || appPassword.isEmpty) {
      throw const ReferenceResolverException(
        ReferenceResolverError.credentialMissing,
      );
    }

    final CapabilitySnapshot capabilities;
    try {
      capabilities = await _api.getAuthenticatedCapabilities(
        server: target.server,
        loginName: account.loginName,
        appPassword: appPassword,
        abortTrigger: abortTrigger,
      );
    } on NextcloudApiException catch (error) {
      throw ReferenceResolverException(_capabilityError(error));
    } on TalkProtocolException {
      throw const ReferenceResolverException(
        ReferenceResolverError.invalidResponse,
      );
    }
    if (!ReferenceCapabilityProfile.fromCapabilities(capabilities).enabled) {
      throw const ReferenceResolverException(
        ReferenceResolverError.unsupported,
      );
    }

    final request = ReferenceResolveRequest(
      server: target.server,
      reference: target.reference,
    );
    final response = await _send(
      request,
      loginName: account.loginName,
      appPassword: appPassword,
      abortTrigger: abortTrigger,
    );
    if (response.classification == ReferenceClassification.unavailable) {
      return null;
    }
    if (response.classification != ReferenceClassification.resolved ||
        response.reference == null) {
      throw ReferenceResolverException(
        _classificationError(response.classification),
      );
    }
    final resolved = response.reference!;
    return ReferenceCardData(
      reference: resolved.reference,
      title: resolved.title,
      description: resolved.description?.isEmpty == true
          ? null
          : resolved.description,
      richObjectType: resolved.richObjectType,
      thumbnail:
          isSafeReferenceThumbnail(
            server: target.server,
            thumbnail: resolved.thumbnail,
          )
          ? resolved.thumbnail
          : null,
    );
  }

  Future<ReferenceResolveResponse> _send(
    ReferenceResolveRequest referenceRequest, {
    required String loginName,
    required String appPassword,
    required Future<void>? abortTrigger,
  }) async {
    final abort = _ReferenceAbort(
      timeout: requestTimeout,
      callerTrigger: abortTrigger,
    );
    try {
      final request =
          http.AbortableRequest(
              'GET',
              referenceRequest.uri,
              abortTrigger: abort.trigger,
            )
            ..followRedirects = false
            ..maxRedirects = 0
            ..headers.addAll(<String, String>{
              'Accept': 'application/json',
              'OCS-APIRequest': 'true',
              'Authorization':
                  'Basic ${base64Encode(utf8.encode('$loginName:$appPassword'))}',
            });
      final response = await _client
          .send(request)
          .timeout(abort.remaining, onTimeout: abort.throwTimeout);
      final contentLength = response.contentLength;
      if (contentLength != null &&
          contentLength > referenceMaximumResponseBytes) {
        throw const ReferenceResolverException(
          ReferenceResolverError.responseTooLarge,
        );
      }
      final bytes = await _readBounded(
        response.stream,
      ).timeout(abort.remaining, onTimeout: abort.throwTimeout);
      final Object? json;
      if (response.statusCode == 200) {
        try {
          json = bytes.isEmpty
              ? const <String, Object?>{}
              : jsonDecode(utf8.decode(bytes));
        } on FormatException {
          throw const ReferenceResolverException(
            ReferenceResolverError.invalidResponse,
          );
        }
      } else {
        json = const <String, Object?>{};
      }
      try {
        return ReferenceResolveResponse.parse(
          request: referenceRequest,
          statusCode: response.statusCode,
          json: json,
        );
      } on ReferenceProtocolException {
        throw const ReferenceResolverException(
          ReferenceResolverError.invalidResponse,
        );
      }
    } on ReferenceResolverException {
      rethrow;
    } on http.RequestAbortedException {
      throw ReferenceResolverException(abort.error);
    } on TimeoutException {
      throw const ReferenceResolverException(ReferenceResolverError.timeout);
    } on http.ClientException {
      throw const ReferenceResolverException(ReferenceResolverError.network);
    } on SocketException {
      throw const ReferenceResolverException(ReferenceResolverError.network);
    } finally {
      abort.dispose();
    }
  }

  Future<Uint8List> _readBounded(Stream<List<int>> stream) async {
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in stream) {
      length += chunk.length;
      if (length > referenceMaximumResponseBytes) {
        throw const ReferenceResolverException(
          ReferenceResolverError.responseTooLarge,
        );
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  _CachedReference? _readCache(_ReferenceCacheKey key) {
    final cached = _cache.remove(key);
    if (cached == null || !cached.expiresAt.isAfter(_clock())) {
      return null;
    }
    _cache[key] = cached;
    return cached;
  }

  void _writeCache(_ReferenceCacheKey key, ReferenceCardData? value) {
    _cache.remove(key);
    _cache[key] = _CachedReference(
      value: value,
      expiresAt: _clock().add(value == null ? negativeCacheTtl : cacheTtl),
    );
    while (_cache.length > maximumCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _client.close();
    _cache.clear();
    _inFlight.clear();
  }
}

final class _ReferenceCacheKey {
  const _ReferenceCacheKey({
    required this.accountId,
    required this.loginName,
    required this.server,
    required this.reference,
  });

  final String accountId;
  final String loginName;
  final Uri server;
  final Uri reference;

  @override
  bool operator ==(Object other) =>
      other is _ReferenceCacheKey &&
      other.accountId == accountId &&
      other.loginName == loginName &&
      other.server == server &&
      other.reference == reference;

  @override
  int get hashCode => Object.hash(accountId, loginName, server, reference);
}

final class _CachedReference {
  const _CachedReference({required this.value, required this.expiresAt});

  final ReferenceCardData? value;
  final DateTime expiresAt;
}

final class _ReferenceAbort {
  _ReferenceAbort({
    required Duration timeout,
    required Future<void>? callerTrigger,
  }) : _deadline = DateTime.now().add(timeout) {
    _timer = Timer(timeout, _abortForTimeout);
    callerTrigger?.then<void>(
      (_) => _abortForCaller(),
      onError: (Object _, StackTrace _) => _abortForCaller(),
    );
  }

  final Completer<void> _trigger = Completer<void>();
  final DateTime _deadline;
  late final Timer _timer;
  var _timedOut = false;
  var _disposed = false;

  Future<void> get trigger => _trigger.future;
  ReferenceResolverError get error => _timedOut
      ? ReferenceResolverError.timeout
      : ReferenceResolverError.cancelled;
  Duration get remaining {
    final value = _deadline.difference(DateTime.now());
    return value.isNegative ? Duration.zero : value;
  }

  Never throwTimeout() {
    _abortForTimeout();
    throw TimeoutException('Reference request timed out');
  }

  void _abortForTimeout() {
    if (_disposed) {
      return;
    }
    _timedOut = true;
    if (!_trigger.isCompleted) {
      _trigger.complete();
    }
  }

  void _abortForCaller() {
    if (!_disposed && !_trigger.isCompleted) {
      _trigger.complete();
    }
  }

  void dispose() {
    _disposed = true;
    _timer.cancel();
  }
}

ReferenceResolverError _capabilityError(NextcloudApiException error) =>
    switch (error.code) {
      NextcloudApiError.cancelled => ReferenceResolverError.cancelled,
      NextcloudApiError.network => ReferenceResolverError.network,
      NextcloudApiError.timeout => ReferenceResolverError.timeout,
      NextcloudApiError.responseTooLarge =>
        ReferenceResolverError.responseTooLarge,
      NextcloudApiError.unexpectedStatus when error.statusCode == 401 =>
        ReferenceResolverError.reauthenticationRequired,
      NextcloudApiError.unexpectedStatus when error.statusCode == 429 =>
        ReferenceResolverError.rateLimited,
      NextcloudApiError.unexpectedStatus
          when error.statusCode == 500 || error.statusCode == 503 =>
        ReferenceResolverError.serviceUnavailable,
      _ => ReferenceResolverError.invalidResponse,
    };

ReferenceResolverError _classificationError(
  ReferenceClassification classification,
) => switch (classification) {
  ReferenceClassification.unsupported => ReferenceResolverError.unsupported,
  ReferenceClassification.reauthenticationRequired =>
    ReferenceResolverError.reauthenticationRequired,
  ReferenceClassification.rateLimited => ReferenceResolverError.rateLimited,
  ReferenceClassification.serviceUnavailable =>
    ReferenceResolverError.serviceUnavailable,
  ReferenceClassification.invalidResponse ||
  ReferenceClassification.resolved ||
  ReferenceClassification.unavailable => ReferenceResolverError.invalidResponse,
};
