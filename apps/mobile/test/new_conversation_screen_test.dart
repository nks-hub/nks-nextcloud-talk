import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/newconversation/new_conversation_screen.dart';
import 'package:nextcloudtalk/features/newconversation/new_conversation_service.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  late _FakeNewConversationService service;

  setUp(() {
    service = _FakeNewConversationService();
  });

  Widget app({required ValueChanged<ConversationToken> onCreated}) {
    return ProviderScope(
      overrides: [newConversationServiceProvider.overrideWithValue(service)],
      child: localizedTestApp(
        home: NewConversationScreen(
          accountId: 'account-a',
          onConversationCreated: onCreated,
        ),
      ),
    );
  }

  testWidgets('searches for recipients after a debounce and lists them', (
    tester,
  ) async {
    service.searchResult = [_syntheticUser(), _syntheticGroup()];

    await tester.pumpWidget(app(onCreated: (_) {}));
    await tester.enterText(find.byType(TextField), 'ali');
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(milliseconds: 350));

    expect(service.lastAccountId, 'account-a');
    expect(service.lastSearchTerm, 'ali');
    expect(find.text('Alice Example'), findsOneWidget);
    expect(find.text('alice@example.invalid'), findsOneWidget);
    expect(find.text('Engineering'), findsOneWidget);
  });

  testWidgets('shows an empty state when nothing matches', (tester) async {
    service.searchResult = const [];

    await tester.pumpWidget(app(onCreated: (_) {}));
    await tester.enterText(find.byType(TextField), 'nobody');
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('No people or groups found.'), findsOneWidget);
  });

  testWidgets('shows an error message when the search fails', (tester) async {
    service.searchError = const NewConversationException(
      NewConversationError.network,
    );

    await tester.pumpWidget(app(onCreated: (_) {}));
    await tester.enterText(find.byType(TextField), 'ali');
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Could not reach the server.'), findsOneWidget);
  });

  testWidgets('creates a one-to-one conversation and reports its token', (
    tester,
  ) async {
    service.searchResult = [_syntheticUser()];
    service.createResult = ConversationToken.parse(
      'newroom1',
      path: r'$.token',
    );
    ConversationToken? created;

    await tester.pumpWidget(app(onCreated: (token) => created = token));
    await tester.enterText(find.byType(TextField), 'ali');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('Alice Example'));
    await tester.pump();
    await tester.pump();

    expect(service.lastCreateAccountId, 'account-a');
    expect(service.lastCreateRecipient?.id, 'alice');
    expect(created?.value, 'newroom1');
  });

  testWidgets('creating a group conversation prompts for a room name', (
    tester,
  ) async {
    service.searchResult = [_syntheticGroup()];
    service.createResult = ConversationToken.parse(
      'newroom2',
      path: r'$.token',
    );
    ConversationToken? created;

    await tester.pumpWidget(app(onCreated: (token) => created = token));
    await tester.enterText(find.byType(TextField), 'eng');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('Engineering'));
    await tester.pumpAndSettle();

    expect(find.text('Name this group conversation'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Eng Room');
    await tester.tap(find.text('Create'));
    await tester.pump();
    await tester.pump();

    expect(service.lastCreateRecipient?.id, 'engineering');
    expect(service.lastCreateRoomName, 'Eng Room');
    expect(created?.value, 'newroom2');
  });
}

ConversationRecipient _syntheticUser() => _decodeRecipient({
  'id': 'alice',
  'label': 'Alice Example',
  'source': 'users',
  'subline': 'alice@example.invalid',
});

ConversationRecipient _syntheticGroup() => _decodeRecipient({
  'id': 'engineering',
  'label': 'Engineering',
  'source': 'groups',
});

/// Builds a [ConversationRecipient] through the real decoder so the fixture
/// stays in lockstep with the wire contract instead of hand-rolling one.
ConversationRecipient _decodeRecipient(Map<String, Object?> item) {
  final response = decodeRecipientSearchResponse(
    request: RecipientSearchRequest(
      accountId: AccountId.parse('account-a'),
      server: ServerBase.parse('https://cloud.example.invalid'),
      searchTerm: 'fixture',
    ),
    statusCode: 200,
    json: {
      'ocs': {
        'meta': {'status': 'ok', 'statuscode': 200},
        'data': [item],
      },
    },
  );
  return (response as RecipientSearchSuccess).recipients.single;
}

final class _FakeNewConversationService implements NewConversationService {
  List<ConversationRecipient> searchResult = const [];
  NewConversationException? searchError;
  String? lastAccountId;
  String? lastSearchTerm;

  ConversationToken? createResult;
  NewConversationException? createError;
  String? lastCreateAccountId;
  ConversationRecipient? lastCreateRecipient;
  String? lastCreateRoomName;

  @override
  Future<List<ConversationRecipient>> searchRecipients({
    required String accountId,
    required String searchTerm,
  }) async {
    lastAccountId = accountId;
    lastSearchTerm = searchTerm;
    final error = searchError;
    if (error != null) {
      throw error;
    }
    return searchResult;
  }

  String? lastOneToOneUserId;

  @override
  Future<ConversationToken> createOneToOneWithUser({
    required String accountId,
    required String userId,
  }) async {
    lastCreateAccountId = accountId;
    lastOneToOneUserId = userId;
    final error = createError;
    if (error != null) {
      throw error;
    }
    return createResult!;
  }

  @override
  Future<ConversationToken> createConversation({
    required String accountId,
    required ConversationRecipient recipient,
    String? roomName,
  }) async {
    lastCreateAccountId = accountId;
    lastCreateRecipient = recipient;
    lastCreateRoomName = roomName;
    final error = createError;
    if (error != null) {
      throw error;
    }
    return createResult!;
  }
}
