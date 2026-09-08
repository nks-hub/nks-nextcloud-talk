part of 'signaling_settings_api_test.dart';

ConversationListRequest _conversationRequest(
  String account, {
  String host = 'cloud.example.invalid',
}) => ConversationListRequest(
  accountId: AccountId.parse(account),
  requestId: ConversationRequestId.parse('list-$account'),
  server: ServerBase.parse('https://$host'),
  mode: ConversationFetchMode.full,
  includeLastMessage: true,
);

void _registerConversationCookieTests() {
  test(
    'conversation refresh uses only its active account session cookie',
    () async {
      final cookies = <String?>[];
      var activations = 0;
      final room = _activeRoomFixture()..['sessionId'] = 'active-session';
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/participants/active')) {
            activations++;
            return http.Response(
              jsonEncode(_ocsEnvelope(room)),
              200,
              headers: {
                'set-cookie':
                    'nc_session=session-$activations; Path=/; HttpOnly',
              },
            );
          }
          cookies.add(request.headers['Cookie']);
          final session = request.headers['Cookie']?.split('=').last ?? '0';
          return http.Response(
            jsonEncode(
              _ocsEnvelope([
                {...room, 'sessionId': session},
              ]),
            ),
            200,
          );
        }),
      );
      addTearDown(api.close);
      for (final account in ['account-a', 'account-b']) {
        await api.activateRoomSession(
          activeRequest: _activeRequest(account),
          loginName: account,
          appPassword: 'fixture-password',
        );
      }
      for (final account in ['account-a', 'account-b']) {
        await api.getConversations(
          conversationRequest: _conversationRequest(account),
          loginName: account,
          appPassword: 'fixture-password',
        );
      }
      expect(cookies, ['nc_session=session-1', 'nc_session=session-2']);
      await api.clearAccountSession('account-a');
      await api.getConversations(
        conversationRequest: _conversationRequest('account-a'),
        loginName: 'account-a',
        appPassword: 'fixture-password',
      );
      await api.getConversations(
        conversationRequest: _conversationRequest(
          'account-b',
          host: 'other.example.invalid',
        ),
        loginName: 'account-b',
        appPassword: 'fixture-password',
      );
      await api.getConversations(
        conversationRequest: _conversationRequest('account-b'),
        loginName: 'account-b',
        appPassword: 'fixture-password',
      );
      expect(cookies, [
        'nc_session=session-1',
        'nc_session=session-2',
        null,
        null,
        'nc_session=session-2',
      ]);
    },
  );

  test(
    'stale conversation refresh cannot outlive its active session',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      final room = _activeRoomFixture()..['sessionId'] = 'active-session';
      final api = HttpNextcloudApi(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/participants/active')) {
            return http.Response(
              jsonEncode(_ocsEnvelope(room)),
              200,
              headers: {'set-cookie': 'nc_session=active; Path=/; HttpOnly'},
            );
          }
          started.complete();
          await release.future;
          return http.Response(
            jsonEncode(_ocsEnvelope([room])),
            200,
            headers: {'set-cookie': 'nc_session=obsolete; Path=/; HttpOnly'},
          );
        }),
      );
      addTearDown(api.close);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await api.activateRoomSession(
        activeRequest: _activeRequest('account-a'),
        loginName: 'account-a',
        appPassword: 'fixture-password',
      );
      final pending = api.getConversations(
        conversationRequest: _conversationRequest('account-a'),
        loginName: 'account-a',
        appPassword: 'fixture-password',
      );
      final rejected = expectLater(
        pending,
        throwsA(
          isA<NextcloudApiException>().having(
            (error) => error.code,
            'code',
            NextcloudApiError.cancelled,
          ),
        ),
      );
      await started.future.timeout(const Duration(seconds: 2));
      await api.clearAccountSession('account-a');
      release.complete();
      await rejected;
    },
  );
}
