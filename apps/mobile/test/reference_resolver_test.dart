import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/references/reference_resolver.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late AppDatabase database;
  late AccountRepository accounts;
  late MemoryCredentialVault credentials;

  setUp(() async {
    database = openTestDatabase();
    accounts = AccountRepository(database);
    credentials = MemoryCredentialVault();
    await _addAccount(accounts, credentials, 'account-a', 'user-a');
    await _addAccount(accounts, credentials, 'account-b', 'user-b');
  });

  tearDown(() => database.close());

  test(
    'resolves and caches exact references per account and server origin',
    () async {
      var resolverRequests = 0;
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _jsonResponse(_capabilities(referenceApi: true));
        }
        if (request.url.path.endsWith('/references/resolve')) {
          resolverRequests++;
          final original = request.url.queryParameters['reference']!;
          return _jsonResponse(
            _referenceResponse(
              original,
              providerLink: 'https://spoofed.example.invalid/path',
            ),
          );
        }
        return http.Response('', 404);
      });
      final resolver = _resolver(accounts, credentials, client);
      addTearDown(resolver.close);
      final reference = Uri.parse('https://docs.example.invalid/topic');

      final first = await resolver.resolve(_target('account-a', reference));
      final cached = await resolver.resolve(_target('account-a', reference));
      final otherAccount = await resolver.resolve(
        _target('account-b', reference),
      );

      expect(first?.reference, reference);
      expect(first?.title, 'Reference title');
      expect(cached, same(first));
      expect(otherAccount?.reference, reference);
      expect(resolverRequests, 2);
      expect(
        requests.where(
          (request) => request.url.path.endsWith('/references/resolve'),
        ),
        everyElement(
          isA<http.Request>()
              .having(
                (request) => request.headers['OCS-APIRequest'],
                'OCS header',
                'true',
              )
              .having(
                (request) => request.followRedirects,
                'redirect policy',
                isFalse,
              ),
        ),
      );
    },
  );

  test(
    'rejects stale account origin before credentials or transport',
    () async {
      var requests = 0;
      final resolver = _resolver(
        accounts,
        credentials,
        MockClient((request) async {
          requests++;
          return http.Response('', 500);
        }),
      );
      addTearDown(resolver.close);

      expect(
        () => resolver.resolve(
          ReferenceResolutionTarget(
            accountId: 'account-a',
            server: ServerBase.parse('https://other.example.invalid'),
            reference: Uri.parse('https://docs.example.invalid/topic'),
          ),
        ),
        throwsA(
          isA<ReferenceResolverException>().having(
            (error) => error.error,
            'error',
            ReferenceResolverError.originMismatch,
          ),
        ),
      );
      expect(requests, 0);
    },
  );

  test('does not call the resolver without core reference-api', () async {
    var resolverRequests = 0;
    final resolver = _resolver(
      accounts,
      credentials,
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _jsonResponse(_capabilities(referenceApi: false));
        }
        resolverRequests++;
        return http.Response('', 500);
      }),
    );
    addTearDown(resolver.close);

    expect(
      () => resolver.resolve(
        _target('account-a', Uri.parse('https://docs.example.invalid/topic')),
      ),
      throwsA(
        isA<ReferenceResolverException>().having(
          (error) => error.error,
          'error',
          ReferenceResolverError.unsupported,
        ),
      ),
    );
    expect(resolverRequests, 0);
  });

  test('rejects a resolver body above one MiB', () async {
    final resolver = _resolver(
      accounts,
      credentials,
      MockClient((request) async {
        if (request.url.path.endsWith('/cloud/capabilities')) {
          return _jsonResponse(_capabilities(referenceApi: true));
        }
        return http.Response.bytes(
          List<int>.filled(referenceMaximumResponseBytes + 1, 0x20),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(resolver.close);

    expect(
      () => resolver.resolve(
        _target('account-a', Uri.parse('https://docs.example.invalid/topic')),
      ),
      throwsA(
        isA<ReferenceResolverException>().having(
          (error) => error.error,
          'error',
          ReferenceResolverError.responseTooLarge,
        ),
      ),
    );
  });

  test(
    'one cancelled caller does not abort a shared account-bound resolve',
    () async {
      final resolverStarted = Completer<void>();
      final responseGate = Completer<http.Response>();
      var resolverRequests = 0;
      final resolver = _resolver(
        accounts,
        credentials,
        MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return _jsonResponse(_capabilities(referenceApi: true));
          }
          resolverRequests++;
          if (!resolverStarted.isCompleted) {
            resolverStarted.complete();
          }
          return responseGate.future;
        }),
      );
      addTearDown(resolver.close);
      final target = _target(
        'account-a',
        Uri.parse('https://docs.example.invalid/topic'),
      );
      final abort = Completer<void>();

      final first = resolver.resolve(target, abortTrigger: abort.future);
      await resolverStarted.future;
      final second = resolver.resolve(target);
      abort.complete();

      await expectLater(
        first,
        throwsA(
          isA<ReferenceResolverException>().having(
            (error) => error.error,
            'error',
            ReferenceResolverError.cancelled,
          ),
        ),
      );
      responseGate.complete(
        _jsonResponse(
          _referenceResponse(
            target.reference.toString(),
            providerLink: target.reference.toString(),
          ),
        ),
      );
      expect((await second)?.reference, target.reference);
      expect(resolverRequests, 1);
    },
  );

  test(
    'classifies an HTML authentication response without parsing it',
    () async {
      final resolver = _resolver(
        accounts,
        credentials,
        MockClient((request) async {
          if (request.url.path.endsWith('/cloud/capabilities')) {
            return _jsonResponse(_capabilities(referenceApi: true));
          }
          return http.Response('<html>Sign in</html>', 401);
        }),
      );
      addTearDown(resolver.close);

      expect(
        () => resolver.resolve(
          _target('account-a', Uri.parse('https://docs.example.invalid/topic')),
        ),
        throwsA(
          isA<ReferenceResolverException>().having(
            (error) => error.error,
            'error',
            ReferenceResolverError.reauthenticationRequired,
          ),
        ),
      );
    },
  );
}

HttpReferenceResolver _resolver(
  AccountRepository accounts,
  MemoryCredentialVault credentials,
  http.Client client,
) => HttpReferenceResolver(
  accounts: accounts,
  credentials: credentials,
  api: HttpNextcloudApi(client: client),
  client: client,
);

ReferenceResolutionTarget _target(String accountId, Uri reference) =>
    ReferenceResolutionTarget(
      accountId: accountId,
      server: ServerBase.parse('https://cloud.example.invalid/nextcloud'),
      reference: reference,
    );

Future<void> _addAccount(
  AccountRepository accounts,
  MemoryCredentialVault credentials,
  String accountId,
  String loginName,
) async {
  await accounts.upsertAccount(
    accountId: accountId,
    serverUrl: 'https://cloud.example.invalid/nextcloud',
    loginName: loginName,
    serverProductName: 'Nextcloud',
    talkFeatures: const {},
    createdAt: DateTime.utc(2026, 1, 1),
  );
  credentials.values[accountId] = 'password-$accountId';
}

http.Response _jsonResponse(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json'},
);

Map<String, Object?> _capabilities({required bool referenceApi}) => {
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
        'core': {'reference-api': referenceApi},
        'spreed': {'features': <Object?>[]},
      },
    },
  },
};

Map<String, Object?> _referenceResponse(
  String reference, {
  required String providerLink,
}) => {
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
    'data': {
      'references': {
        reference: {
          'richObjectType': 'integration_unknown',
          'richObject': <String, Object?>{},
          'openGraphObject': {
            'id': reference,
            'name': 'Reference title',
            'description': 'Reference description',
            'thumb': null,
            'link': providerLink,
          },
          'accessible': true,
        },
      },
    },
  },
};
