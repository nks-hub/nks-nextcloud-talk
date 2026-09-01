part of 'nextcloud_api.dart';

final class _AccountCookieStore {
  final Map<AccountId, _AccountCookies> _accounts = {};

  void apply(http.BaseRequest request, AccountId accountId, ServerBase server) {
    final stored = _accounts[accountId];
    if (stored == null || stored.server.uri != server.uri) {
      return;
    }
    final now = DateTime.now().toUtc();
    stored.cookies.removeWhere(
      (_, cookie) => cookie.expires != null && !cookie.expires!.isAfter(now),
    );
    final eligible = stored.cookies.values.where(
      (cookie) =>
          (!cookie.secure || request.url.scheme == 'https') &&
          (cookie.path == null || request.url.path.startsWith(cookie.path!)),
    );
    if (eligible.isNotEmpty) {
      request.headers['Cookie'] = eligible
          .map((cookie) => '${cookie.name}=${cookie.value}')
          .join('; ');
    }
  }

  void capture(
    Map<String, String> headers,
    AccountId accountId,
    ServerBase server,
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
    for (final value in header.split(
      RegExp(r',(?=\s*[!#$%&\x27*+\-.^_`|~0-9A-Za-z]+=)'),
    )) {
      final Cookie cookie;
      try {
        cookie = Cookie.fromSetCookieValue(value.trim());
      } on FormatException {
        continue;
      }
      if (cookie.maxAge == 0 || cookie.value.isEmpty) {
        stored.cookies.remove(cookie.name);
      } else {
        stored.cookies[cookie.name] = cookie;
      }
    }
  }

  void clear(AccountId accountId) => _accounts.remove(accountId);

  void clearAll() => _accounts.clear();
}

final class _AccountCookies {
  _AccountCookies({required this.server});

  ServerBase server;
  final Map<String, Cookie> cookies = {};
}
