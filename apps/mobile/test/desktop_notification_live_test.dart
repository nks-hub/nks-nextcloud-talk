import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

/// Requires a dedicated account. Creates and deletes only its own test room.
void main() {
  test(
    'live desktop notifications follow room notification settings',
    () async {
      final path = Platform.environment['NCTALK_NOTIFICATION_ACCESS_FILE'];
      if (path == null) throw StateError('Missing live credential file');
      final credentials =
          jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      final live = _NotificationsLive(credentials);
      try {
        await live.run();
      } finally {
        try {
          await live.cleanup();
        } finally {
          live.close();
        }
      }
    },
    skip: Platform.environment['NCTALK_NOTIFICATION_LIVE'] != 'YES'
        ? 'Requires explicit live opt-in and a dedicated account credential file'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

final class _NotificationsLive {
  _NotificationsLive(Map<String, dynamic> credentials)
    : server = ServerBase.parse(credentials['origin'] as String),
      user = credentials['user'] as String,
      password = credentials['password'] as String;

  final ServerBase server;
  final String user;
  final String password;
  final api = HttpNextcloudApi();
  final fixture = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final guestCookies = <String, Cookie>{};
  final marker = 'Notification verification ${const Uuid().v4()}';
  String? token;

  Future<List<Map<String, Object?>>> notifications() async {
    final result = await api.getDesktopNotifications(
      server: server,
      loginName: user,
      appPassword: password,
    );
    if (result == null) throw StateError('Notifications API is unavailable');
    return result;
  }

  Future<void> run() async {
    if (server.uri.scheme != 'https') {
      throw StateError('Live verification requires HTTPS');
    }
    await notifications();
    stdout.writeln('Live notification API decoded successfully');
    final capabilities = await request('GET', '/ocs/v2.php/cloud/capabilities');
    final features =
        ((capabilities.data as Map)['capabilities'] as Map)['spreed'] as Map;
    if (!(features['features'] as List).contains(
      'conversation-creation-password',
    )) {
      throw StateError(
        'Server cannot create a password-protected room atomically',
      );
    }
    final roomPassword = 'Aa9!${const Uuid().v4()}';
    final created = await request(
      'POST',
      '/ocs/v2.php/apps/spreed/api/v4/room',
      fields: {'roomType': '3', 'roomName': marker, 'password': roomPassword},
      allowed: const {201},
    );
    final room = created.data as Map;
    token = room['token'] as String;
    if (room['hasPassword'] != true || room['name'] != marker) {
      throw StateError('Created room does not match the protected fixture');
    }
    await request(
      'POST',
      '/ocs/v2.php/apps/spreed/api/v4/room/$token/notify',
      fields: {'level': '1'},
    );
    final joined = await request(
      'POST',
      '/ocs/v2.php/apps/spreed/api/v4/room/$token/participants/active',
      fields: {'password': roomPassword},
      guest: true,
      allowed: const {200, 401, 403, 404, 412},
    );
    if (joined.status != 200) {
      throw StateError(
        'Guest join refused (HTTP ${joined.status}); read-only API check passed',
      );
    }
    final first = await send('Notification allowed');
    Map<String, Object?>? approved;
    for (var attempt = 0; attempt < 15; attempt++) {
      final matching = (await notifications()).where(
        (item) =>
            item['app'] == 'spreed' &&
            item['object_type'] == 'chat' &&
            item['object_id'] == '$token/$first',
      );
      if (matching.isNotEmpty) {
        approved = matching.first;
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (approved == null) {
      throw StateError('Normal message produced no owner notification');
    }
    expect(approved['notification_id'], isA<int>());
    expect(approved['subject'], isA<String>());
    expect(approved['message'], isA<String>());
    expect(approved['shouldNotify'], isNot(false));
    stdout.writeln(
      'Normal guest message produced an eligible owner notification',
    );

    await request(
      'POST',
      '/ocs/v2.php/apps/spreed/api/v4/room/$token/notify',
      fields: {'level': '3'},
    );
    final muted = await send('Notification muted');
    for (var attempt = 0; attempt < 4; attempt++) {
      final unexpected = (await notifications()).any(
        (item) =>
            item['app'] == 'spreed' && item['object_id'] == '$token/$muted',
      );
      expect(
        unexpected,
        isFalse,
        reason: 'Muted room must not create a message notification',
      );
      if (attempt < 3) await Future<void>.delayed(const Duration(seconds: 1));
    }
    stdout.writeln('Muted guest message produced no owner notification');
  }

  Future<int> send(String message) async {
    final sent = await request(
      'POST',
      '/ocs/v2.php/apps/spreed/api/v1/chat/$token',
      fields: {'message': message, 'actorDisplayName': 'Verification guest'},
      guest: true,
      allowed: const {201},
    );
    return (sent.data as Map)['id'] as int;
  }

  Future<({int status, Object? data})> request(
    String method,
    String path, {
    Map<String, String>? fields,
    bool guest = false,
    Set<int> allowed = const {200},
  }) async {
    try {
      final uri = server.uri.replace(
        path: '${server.basePath}$path',
        queryParameters: {'format': 'json'},
      );
      final request = await fixture
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.set('Accept', 'application/json');
      request.headers.set('OCS-APIRequest', 'true');
      if (guest) {
        request.cookies.addAll(guestCookies.values);
      } else {
        request.headers.set(
          'Authorization',
          'Basic ${base64Encode(utf8.encode('$user:$password'))}',
        );
      }
      if (fields != null) {
        request.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: 'utf-8',
        );
        request.write(Uri(queryParameters: fields).query);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (guest) {
        for (final cookie in response.cookies) {
          guestCookies[cookie.name] = cookie;
        }
      }
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 20));
      if (!allowed.contains(response.statusCode)) {
        throw StateError('Fixture HTTP ${response.statusCode} for $method');
      }
      final decoded = jsonDecode(body) as Map;
      return (
        status: response.statusCode,
        data: (decoded['ocs'] as Map)['data'],
      );
    } on StateError {
      rethrow;
    } on Object catch (error) {
      throw StateError('Live fixture request failed (${error.runtimeType})');
    }
  }

  Future<void> cleanup() async {
    if (token == null) return;
    await request('DELETE', '/ocs/v2.php/apps/spreed/api/v4/room/$token');
    await request(
      'GET',
      '/ocs/v2.php/apps/spreed/api/v4/room/$token',
      allowed: const {404},
    );
    token = null;
    stdout.writeln('Created room deleted and absence verified');
  }

  void close() {
    fixture.close(force: true);
    api.close();
  }
}
