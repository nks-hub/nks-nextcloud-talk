import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

/// Live smoke over the same transport the search screen uses. The unified
/// search response shape had drifted from the hand-written fixtures, and only
/// a real server catches that.
void main() {
  test(
    'live transport decodes a unified message search response',
    () async {
      final api = HttpNextcloudApi();
      addTearDown(api.close);
      final server = ServerBase.parse(
        Platform.environment['NEXTCLOUD_TALK_ORIGIN']!,
      );
      final username = Platform.environment['NEXTCLOUD_TALK_USERNAME']!;
      final appPassword = Platform.environment['NEXTCLOUD_TALK_APP_PASSWORD']!;

      final response = await api.searchMessages(
        searchRequest: MessageSearchRequest(
          accountId: AccountId.parse('live-account'),
          requestId: SearchRequestId.parse('live-search-request'),
          server: server,
          scope: MessageSearchScope.global,
          term: Platform.environment['NEXTCLOUD_TALK_SEARCH_TERM'] ?? 'a',
          limit: 20,
        ),
        loginName: username,
        appPassword: appPassword,
      );

      expect(
        response.classification,
        anyOf(
          MessageSearchClassification.results,
          MessageSearchClassification.empty,
        ),
        reason: 'the live provider must decode, not classify as an error',
      );
    },
    skip:
        Platform.environment['NEXTCLOUD_TALK_ORIGIN'] == null ||
            Platform.environment['NEXTCLOUD_TALK_USERNAME'] == null ||
            Platform.environment['NEXTCLOUD_TALK_APP_PASSWORD'] == null
        ? 'Live Nextcloud credentials are not configured.'
        : false,
  );
  test(
    'live room-scoped search returns only the room it was pointed at',
    () async {
      final api = HttpNextcloudApi();
      addTearDown(api.close);
      final server = ServerBase.parse(
        Platform.environment['NEXTCLOUD_TALK_ORIGIN']!,
      );
      final roomToken = ConversationToken.parse(
        Platform.environment['NEXTCLOUD_TALK_TEST_ROOM_TOKEN']!,
        path: r'$.roomToken',
      );

      final response = await api.searchMessages(
        searchRequest: MessageSearchRequest(
          accountId: AccountId.parse('live-account'),
          requestId: SearchRequestId.parse('live-scoped-request'),
          server: server,
          scope: MessageSearchScope.currentRoom,
          roomToken: roomToken,
          term: Platform.environment['NEXTCLOUD_TALK_SEARCH_TERM'] ?? 'a',
          limit: 20,
        ),
        loginName: Platform.environment['NEXTCLOUD_TALK_USERNAME']!,
        appPassword: Platform.environment['NEXTCLOUD_TALK_APP_PASSWORD']!,
      );

      expect(
        response.classification,
        anyOf(
          MessageSearchClassification.results,
          MessageSearchClassification.empty,
        ),
      );
      // The whole point of the scope: nothing from any other conversation.
      expect(
        response.results.every((result) => result.roomToken == roomToken),
        isTrue,
        reason: 'room-scoped search leaked another conversation',
      );
    },
    skip:
        Platform.environment['NEXTCLOUD_TALK_ORIGIN'] == null ||
            Platform.environment['NEXTCLOUD_TALK_USERNAME'] == null ||
            Platform.environment['NEXTCLOUD_TALK_APP_PASSWORD'] == null ||
            Platform.environment['NEXTCLOUD_TALK_TEST_ROOM_TOKEN'] == null
        ? 'Live Nextcloud credentials are not configured.'
        : false,
  );
}
