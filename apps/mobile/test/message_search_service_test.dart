import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/features/search/message_search_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';

import 'test_support.dart';

Map<String, Object?> _searchEntry({
  required String title,
  required String subline,
  required String roomToken,
  required int messageId,
  int? timestamp,
}) => <String, Object?>{
  'title': title,
  'subline': subline,
  'resourceUrl':
      'https://cloud.example.invalid/index.php/apps/spreed/?token=$roomToken',
  'attributes': <String, Object?>{
    'conversation': roomToken,
    'messageId': '$messageId',
    'timestamp': ?timestamp,
  },
};

Map<String, Object?> _successBody(List<Map<String, Object?>> entries) =>
    <String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{'status': 'ok', 'statuscode': 200},
        'data': <String, Object?>{
          'name': 'Messages',
          'isPaginated': false,
          'entries': entries,
        },
      },
    };

void main() {
  late AccountRepository repository;
  late MemoryCredentialVault vault;

  setUp(() async {
    final database = openTestDatabase();
    addTearDown(database.close);
    repository = AccountRepository(database);
    vault = MemoryCredentialVault();
    await repository.upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    vault.values['account-a'] = 'fixture-app-password-never-use';
  });

  HttpMessageSearchService buildService(
    Future<http.Response> Function(http.Request request) handler,
  ) {
    return HttpMessageSearchService(
      accounts: repository,
      credentials: vault,
      api: HttpNextcloudApi(client: MockClient(handler)),
    );
  }

  test('returns typed results on a successful search', () async {
    final service = buildService((request) async {
      expect(request.url.path, endsWith('/talk-message/search'));
      expect(request.url.queryParameters['term'], 'hello');
      expect(request.headers['Authorization'], startsWith('Basic '));
      return http.Response(
        jsonEncode(
          _successBody([
            _searchEntry(
              title: 'Alice',
              subline: 'Hello there',
              roomToken: 'abcd1234',
              messageId: 42,
              timestamp: 1770000000,
            ),
          ]),
        ),
        200,
      );
    });

    final results = await service.search(accountId: 'account-a', term: 'hello');

    expect(results, hasLength(1));
    expect(results.single.author, 'Alice');
    expect(results.single.excerpt, 'Hello there');
    expect(results.single.messageId, 42);
    expect(results.single.roomToken.value, 'abcd1234');
  });

  test('a room token asks the current-room provider and scopes with from', () async {
    // Measured on Talk 24.0.2: the current-room provider returns only that
    // room, while the global one EXCLUDES it — pairing them the other way
    // round silently hides the room the user is reading.
    final service = buildService((request) async {
      expect(request.url.path, endsWith('/talk-message-current/search'));
      expect(request.url.queryParameters['from'], '/call/abcd1234');
      return http.Response(jsonEncode(_successBody(const [])), 200);
    });

    await service.search(
      accountId: 'account-a',
      term: 'hello',
      roomToken: 'abcd1234',
    );
  });

  test('a global search never sends a room route', () async {
    final service = buildService((request) async {
      expect(request.url.path, endsWith('/talk-message/search'));
      expect(request.url.queryParameters.containsKey('from'), isFalse);
      return http.Response(jsonEncode(_successBody(const [])), 200);
    });

    await service.search(accountId: 'account-a', term: 'hello');
  });

  test('returns an empty list when the provider has no hits', () async {
    final service = buildService(
      (request) async => http.Response(jsonEncode(_successBody(const [])), 200),
    );

    final results = await service.search(accountId: 'account-a', term: 'nothing');

    expect(results, isEmpty);
  });

  test('rejects a blank search term without a network call', () async {
    var calls = 0;
    final service = buildService((request) async {
      calls++;
      return http.Response(jsonEncode(_successBody(const [])), 200);
    });

    await expectLater(
      service.search(accountId: 'account-a', term: '   '),
      throwsA(
        isA<MessageSearchException>().having(
          (error) => error.code,
          'code',
          MessageSearchError.invalidSearchTerm,
        ),
      ),
    );
    expect(calls, 0);
  });

  test('throws accountMissing for an unknown account', () async {
    final service = buildService(
      (request) async => http.Response(jsonEncode(_successBody(const [])), 200),
    );

    await expectLater(
      service.search(accountId: 'missing-account', term: 'hello'),
      throwsA(
        isA<MessageSearchException>().having(
          (error) => error.code,
          'code',
          MessageSearchError.accountMissing,
        ),
      ),
    );
  });

  test('throws credentialMissing when no app password is stored', () async {
    vault.values.remove('account-a');
    final service = buildService(
      (request) async => http.Response(jsonEncode(_successBody(const [])), 200),
    );

    await expectLater(
      service.search(accountId: 'account-a', term: 'hello'),
      throwsA(
        isA<MessageSearchException>().having(
          (error) => error.code,
          'code',
          MessageSearchError.credentialMissing,
        ),
      ),
    );
  });

  final statusCases = <int, MessageSearchError>{
    401: MessageSearchError.reauthenticationRequired,
    404: MessageSearchError.providerNotFound,
    429: MessageSearchError.transientError,
    503: MessageSearchError.transientError,
  };
  for (final entry in statusCases.entries) {
    test('maps HTTP ${entry.key} to ${entry.value.name}', () async {
      final service = buildService(
        (request) async => http.Response('', entry.key),
      );

      await expectLater(
        service.search(accountId: 'account-a', term: 'hello'),
        throwsA(
          isA<MessageSearchException>().having(
            (error) => error.code,
            'code',
            entry.value,
          ),
        ),
      );
    });
  }

  test('maps an OCS-level failure to ocsFailure', () async {
    final service = buildService(
      (request) async => http.Response(
        jsonEncode(<String, Object?>{
          'ocs': <String, Object?>{
            'meta': <String, Object?>{'status': 'failure', 'statuscode': 400},
            'data': <String, Object?>{},
          },
        }),
        200,
      ),
    );

    await expectLater(
      service.search(accountId: 'account-a', term: 'hello'),
      throwsA(
        isA<MessageSearchException>().having(
          (error) => error.code,
          'code',
          MessageSearchError.ocsFailure,
        ),
      ),
    );
  });
}
