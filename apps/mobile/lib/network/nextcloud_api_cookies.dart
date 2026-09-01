part of 'nextcloud_api.dart';

final class _AccountCookieStore {
  _AccountCookieStore(this._clock);

  final DateTime Function() _clock;
  final Map<AccountId, _AccountCookies> _accounts = {};

  void apply(http.BaseRequest request, AccountId accountId, ServerBase server) {
    final stored = _accounts[accountId];
    if (stored == null || stored.server.uri != server.uri) {
      return;
    }
    if (!server.hasSameOrigin(request.url) ||
        !_requestIsWithinServer(server, request.url)) {
      return;
    }
    final now = _clock().toUtc();
    stored.cookies.removeWhere(
      (_, cookie) =>
          cookie.expiresAt != null && !cookie.expiresAt!.isAfter(now),
    );
    final eligible = stored.cookies.values.where(
      (stored) =>
          (!stored.cookie.secure || request.url.scheme == 'https') &&
          _domainMatches(request.url.host, stored.domain) &&
          _pathMatches(request.url.path, stored.path),
    );
    if (eligible.isNotEmpty) {
      request.headers['Cookie'] = eligible
          .map((stored) => '${stored.cookie.name}=${stored.cookie.value}')
          .join('; ');
    }
  }

  void capture(
    Map<String, String> headers,
    AccountId accountId,
    ServerBase server,
    Uri requestUri,
  ) {
    final header = headers['set-cookie'];
    if (header == null || header.isEmpty) {
      return;
    }
    final stored = _accounts.putIfAbsent(
      accountId,
      () => _AccountCookies(server: server),
    );
    if (stored.server.uri != server.uri) {
      stored
        ..server = server
        ..cookies.clear();
    }
    final now = _clock().toUtc();
    for (final value in header.split(
      RegExp(r',(?=\s*[!#$%&\x27*+\-.^_`|~0-9A-Za-z]+=)'),
    )) {
      final Cookie cookie;
      try {
        cookie = Cookie.fromSetCookieValue(value.trim());
      } on FormatException {
        continue;
      } on HttpException {
        continue;
      }
      final domain = _cookieDomain(cookie, requestUri.host);
      if (domain == null || !_domainMatches(requestUri.host, domain)) {
        continue;
      }
      final path = _cookiePath(cookie.path, requestUri.path);
      final key = (name: cookie.name, domain: domain, path: path);
      final maxAge = cookie.maxAge;
      if ((maxAge != null && maxAge <= 0) || cookie.value.isEmpty) {
        stored.cookies.remove(key);
      } else {
        stored.cookies[key] = _StoredCookie(
          cookie: cookie,
          domain: domain,
          path: path,
          expiresAt: maxAge == null
              ? cookie.expires?.toUtc()
              : now.add(Duration(seconds: maxAge)),
        );
      }
    }
  }

  void clear(AccountId accountId) => _accounts.remove(accountId);

  void clearAll() => _accounts.clear();
}

final class _AccountCookies {
  _AccountCookies({required this.server});

  ServerBase server;
  final Map<({String name, String domain, String path}), _StoredCookie>
  cookies = {};
}

final class _StoredCookie {
  const _StoredCookie({
    required this.cookie,
    required this.domain,
    required this.path,
    required this.expiresAt,
  });

  final Cookie cookie;
  final String domain;
  final String path;
  final DateTime? expiresAt;
}

String? _cookieDomain(Cookie cookie, String requestHost) {
  final raw = cookie.domain?.trim().toLowerCase();
  if (raw == null || raw.isEmpty) return requestHost.toLowerCase();
  final domain = raw.startsWith('.') ? raw.substring(1) : raw;
  return domain.isEmpty ? null : domain;
}

String _cookiePath(String? raw, String requestPath) {
  if (raw != null && raw.startsWith('/')) return raw;
  if (!requestPath.startsWith('/') || requestPath == '/') return '/';
  final lastSlash = requestPath.lastIndexOf('/');
  return lastSlash <= 0 ? '/' : requestPath.substring(0, lastSlash);
}

bool _domainMatches(String host, String domain) {
  final normalizedHost = host.toLowerCase();
  final normalizedDomain = domain.toLowerCase();
  return normalizedHost == normalizedDomain ||
      normalizedHost.endsWith('.$normalizedDomain');
}

bool _pathMatches(String requestPath, String cookiePath) {
  if (requestPath == cookiePath) return true;
  if (!requestPath.startsWith(cookiePath)) return false;
  return cookiePath.endsWith('/') ||
      (requestPath.length > cookiePath.length &&
          requestPath.codeUnitAt(cookiePath.length) == 0x2f);
}
