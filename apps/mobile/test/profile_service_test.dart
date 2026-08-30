import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/profile/profile_models.dart';
import 'package:nextcloudtalk/features/profile/profile_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault vault;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    vault = MemoryCredentialVault()
      ..values['account-a'] = 'password-a'
      ..values['account-b'] = 'password-b';
    await accounts.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud-a.example.invalid',
      loginName: 'alice',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
    );
    await accounts.upsertAccount(
      accountId: 'account-b',
      serverUrl: 'https://cloud-b.example.invalid',
      loginName: 'bob',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 2),
    );
  });

  tearDown(() => database.close());

  ProfileService service(MockClient client) {
    final api = HttpNextcloudApi(client: client);
    addTearDown(api.close);
    return ProfileService(accounts, vault, api);
  }

  test(
    'loads two profiles without crossing account credentials or hosts',
    () async {
      final calls = <String>[];
      final subject = service(
        MockClient((request) async {
          final user = _user(request);
          calls.add('$user ${request.url.host} ${request.url.path}');
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return _jsonResponse(
              _capabilities(statusEnabled: true, busy: user == 'alice'),
            );
          }
          if (request.url.path.endsWith('/cloud/user')) {
            return _ocsResponse({
              'id': user,
              'displayname': user == 'alice' ? 'Alice' : 'Bob',
              'email': null,
            });
          }
          return _ocsResponse(_status(user));
        }),
      );

      final results = await Future.wait([
        subject.load('account-a'),
        subject.load('account-b'),
      ]);

      expect(results[0].accountId, 'account-a');
      expect(results[0].profile.userId, 'alice');
      expect(results[0].statusCapability.supportsBusy, isTrue);
      expect(results[1].accountId, 'account-b');
      expect(results[1].profile.userId, 'bob');
      expect(results[1].statusCapability.supportsBusy, isFalse);
      expect(calls.where((call) => call.startsWith('alice ')).length, 3);
      expect(calls.where((call) => call.startsWith('bob ')).length, 3);
      expect(calls.where((call) => call.contains('alice cloud-b')), isEmpty);
      expect(calls.where((call) => call.contains('bob cloud-a')), isEmpty);
    },
  );

  test(
    'missing or malformed capability prevents every status endpoint call',
    () async {
      var statusRequests = 0;
      final subject = service(
        MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return _jsonResponse(
              _capabilities(statusEnabled: false, malformed: true),
            );
          }
          if (request.url.path.endsWith('/cloud/user')) {
            return _ocsResponse({
              'id': 'alice',
              'displayname': 'Alice',
              'email': null,
            });
          }
          statusRequests++;
          return http.Response('', 500);
        }),
      );

      final snapshot = await subject.load('account-a');
      expect(snapshot.statusCapability.enabled, isFalse);
      expect(snapshot.status, isNull);
      await expectLater(
        subject.setStatusType(
          accountId: 'account-a',
          status: OwnUserStatusType.away,
        ),
        throwsA(
          isA<OwnProfileException>().having(
            (error) => error.code,
            'code',
            OwnProfileError.unsupported,
          ),
        ),
      );
      expect(statusRequests, 0);
    },
  );

  test('busy is rejected unless the server advertises supports_busy', () async {
    var mutationRequests = 0;
    final subject = service(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _jsonResponse(_capabilities(statusEnabled: true, busy: false));
        }
        mutationRequests++;
        return http.Response('', 500);
      }),
    );

    await expectLater(
      subject.setStatusType(
        accountId: 'account-a',
        status: OwnUserStatusType.busy,
      ),
      throwsA(
        isA<OwnProfileException>().having(
          (error) => error.code,
          'code',
          OwnProfileError.unsupported,
        ),
      ),
    );
    expect(mutationRequests, 0);
  });

  test('server rejects an invalid custom status as invalid input', () async {
    var mutationRequests = 0;
    final subject = service(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _jsonResponse(_capabilities(statusEnabled: true));
        }
        mutationRequests++;
        return http.Response('', 400);
      }),
    );

    await expectLater(
      subject.setCustomMessage(
        accountId: 'account-a',
        message: 'Working',
        statusIcon: 'not-an-emoji',
      ),
      throwsA(
        isA<OwnProfileException>().having(
          (error) => error.code,
          'code',
          OwnProfileError.invalidInput,
        ),
      ),
    );
    expect(mutationRequests, 1);
  });

  test('a status expiry becomes an absolute clearAt on the wire', () async {
    String? body;
    final subject = service(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _jsonResponse(_capabilities(statusEnabled: true));
        }
        body = request.body;
        return _ocsResponse(_status('alice'));
      }),
    );

    // Pinned clock: the server only ever sees the resolved instant, so the
    // test asserts the arithmetic, not "roughly half an hour from now".
    final now = DateTime(2026, 8, 30, 14, 0);
    await subject.setCustomMessage(
      accountId: 'account-a',
      message: 'Working',
      expiry: StatusExpiry.halfHour,
      now: now,
    );

    final expected =
        DateTime(2026, 8, 30, 14, 30).millisecondsSinceEpoch ~/ 1000;
    expect(body, contains('clearAt=$expected'));
  });

  test('never leaves clearAt off the request entirely', () async {
    String? body;
    final subject = service(
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _jsonResponse(_capabilities(statusEnabled: true));
        }
        body = request.body;
        return _ocsResponse(_status('alice'));
      }),
    );

    await subject.setCustomMessage(
      accountId: 'account-a',
      message: 'Working',
      now: DateTime(2026, 8, 30, 14, 0),
    );

    expect(body, isNotNull);
    expect(body, isNot(contains('clearAt')));
  });

  test(
    'a response for another user is rejected instead of changing scope',
    () async {
      final subject = service(
        MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return _jsonResponse(_capabilities(statusEnabled: true));
          }
          if (request.url.path.endsWith('/cloud/user')) {
            return _ocsResponse({
              'id': 'mallory',
              'displayname': 'Wrong user',
              'email': null,
            });
          }
          return _ocsResponse(_status('alice'));
        }),
      );

      await expectLater(
        subject.load('account-a'),
        throwsA(
          isA<OwnProfileException>().having(
            (error) => error.code,
            'code',
            OwnProfileError.invalidResponse,
          ),
        ),
      );
    },
  );

  test(
    'clear confirms the resulting server state with a follow-up GET',
    () async {
      final methods = <String>[];
      final subject = service(
        MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return _jsonResponse(_capabilities(statusEnabled: true));
          }
          methods.add(request.method);
          if (request.method == 'DELETE') {
            return _ocsResponse(<Object?>[]);
          }
          return _ocsResponse(_status('alice', message: null, icon: null));
        }),
      );

      final status = await subject.clearMessage('account-a');

      expect(status.message, isNull);
      expect(methods, ['DELETE', 'GET']);
    },
  );
}

String _user(http.Request request) {
  final header = request.headers['Authorization'];
  for (final entry in const [('alice', 'password-a'), ('bob', 'password-b')]) {
    if (header ==
        'Basic ${base64Encode(utf8.encode('${entry.$1}:${entry.$2}'))}') {
      return entry.$1;
    }
  }
  fail('Unexpected account credential');
}

Map<String, Object?> _capabilities({
  required bool statusEnabled,
  bool busy = true,
  bool malformed = false,
}) => <String, Object?>{
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
    'data': {
      'version': {
        'major': 34,
        'minor': 0,
        'micro': 1,
        'string': '34.0.1',
        'edition': '',
        'extendedSupport': false,
      },
      'capabilities': {
        'spreed': {
          'features': ['conversation-v4'],
          'config': <String, Object?>{},
        },
        'user_status': {
          'enabled': malformed ? 'yes' : statusEnabled,
          'supports_emoji': statusEnabled,
          'supports_busy': busy,
        },
      },
    },
  },
};

Map<String, Object?> _status(
  String user, {
  String? message = 'Working',
  String? icon = '💡',
}) => <String, Object?>{
  'userId': user,
  'message': message,
  'messageId': null,
  'messageIsPredefined': false,
  'icon': icon,
  'clearAt': null,
  'status': 'online',
  'statusIsUserDefined': true,
};

http.Response _ocsResponse(Object? data) => _jsonResponse({
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
    'data': data,
  },
});

http.Response _jsonResponse(Object? data) => http.Response.bytes(
  utf8.encode(jsonEncode(data)),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
