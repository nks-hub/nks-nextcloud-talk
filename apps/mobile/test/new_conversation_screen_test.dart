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

  testWidgets('creates an empty group without selecting a recipient', (
    tester,
  ) async {
    service.createResult = ConversationToken.parse(
      'newroom3',
      path: r'$.token',
    );
    ConversationToken? created;

    await tester.pumpWidget(app(onCreated: (token) => created = token));
    await tester.tap(find.byKey(const Key('create-empty-group-conversation')));
    await tester.pumpAndSettle();
    expect(find.text('Name this group conversation'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Project room');
    await tester.tap(find.text('Create'));
    await tester.pump();
    await tester.pump();

    expect(service.lastStandaloneType, StandaloneConversationType.group);
    expect(service.lastCreateRoomName, 'Project room');
    expect(service.lastCreateRecipient, isNull);
    expect(created?.value, 'newroom3');
  });

  testWidgets('creates a public room without selecting a recipient', (
    tester,
  ) async {
    service.createResult = ConversationToken.parse(
      'newroom4',
      path: r'$.token',
    );
    ConversationToken? created;

    await tester.pumpWidget(app(onCreated: (token) => created = token));
    await tester.tap(find.byKey(const Key('create-public-conversation')));
    await tester.pumpAndSettle();
    expect(find.text('Name this public conversation'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Town hall');
    await tester.tap(find.text('Create'));
    await tester.pump();
    await tester.pump();

    expect(service.lastStandaloneType, StandaloneConversationType.public);
    expect(service.lastCreateRoomName, 'Town hall');
    expect(service.lastCreateRecipient, isNull);
    expect(created?.value, 'newroom4');
  });

  testWidgets('standalone room actions wrap on a narrow Czech screen', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [newConversationServiceProvider.overrideWithValue(service)],
        child: localizedTestApp(
          locale: const Locale('cs'),
          home: NewConversationScreen(
            accountId: 'account-a',
            onConversationCreated: (_) {},
          ),
        ),
      ),
    );

    for (final key in const <String>[
      'create-empty-group-conversation',
      'create-public-conversation',
    ]) {
      final action = find.byKey(Key(key));
      expect(action, findsOneWidget);
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('standalone room name stays open when empty and caps input', (
    tester,
  ) async {
    await tester.pumpWidget(app(onCreated: (_) {}));
    await tester.tap(find.byKey(const Key('create-empty-group-conversation')));
    await tester.pumpAndSettle();

    final field = find.byType(TextFormField);
    final textField = tester.widget<TextField>(
      find.descendant(of: field, matching: find.byType(TextField)),
    );
    expect(textField.maxLength, 200);
    await tester.tap(find.text('Create'));
    await tester.pump();

    expect(find.text('The conversation needs a name.'), findsOneWidget);
    expect(find.text('Name this group conversation'), findsOneWidget);
    expect(service.lastStandaloneType, isNull);
  });

  testWidgets('joining an open conversation opens it like a new one', (
    tester,
  ) async {
    service.openRooms = [
      ListedRoom(
        token: ConversationToken.parse('open1234', path: r'$.token'),
        displayName: 'Open room',
        description: '',
        lastActivity: null,
        hasPassword: true,
      ),
    ];
    ConversationToken? opened;
    await tester.pumpWidget(app(onCreated: (token) => opened = token));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('browse-open-conversations')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open-conversations-list')), findsOneWidget);

    await tester.tap(find.byKey(const Key('open-conversation-open1234')));
    await tester.pumpAndSettle();

    // A password protected room asks first; nothing is joined before that.
    expect(
      find.byKey(const Key('open-conversation-password-dialog')),
      findsOneWidget,
    );
    expect(service.lastJoinToken, isNull);

    await tester.enterText(find.byType(TextField).last, 'open sesame');
    await tester.tap(
      find.byKey(const Key('open-conversation-password-submit')),
    );
    await tester.pumpAndSettle();

    expect(service.lastJoinPassword, 'open sesame');
    expect(opened?.value, 'open1234');
  });

  testWidgets('a server without open conversations says so', (tester) async {
    service.openRoomsError = const NewConversationException(
      NewConversationError.unavailable,
    );
    await tester.pumpWidget(app(onCreated: (_) {}));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('browse-open-conversations')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open-conversations-error')), findsOneWidget);
    expect(find.byKey(const Key('open-conversations-list')), findsNothing);
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
  StandaloneConversationType? lastStandaloneType;

  List<ListedRoom> openRooms = const [];
  NewConversationException? openRoomsError;
  ConversationToken? joinResult;
  NewConversationException? joinError;
  ConversationToken? lastJoinToken;
  String? lastJoinPassword;

  @override
  Future<List<ListedRoom>> listOpenConversations({
    required String accountId,
    String searchTerm = '',
  }) async {
    final error = openRoomsError;
    if (error != null) {
      throw error;
    }
    return openRooms;
  }

  @override
  Future<ConversationToken> joinOpenConversation({
    required String accountId,
    required ConversationToken roomToken,
    String password = '',
  }) async {
    lastJoinToken = roomToken;
    lastJoinPassword = password;
    final error = joinError;
    if (error != null) {
      throw error;
    }
    return joinResult ?? roomToken;
  }

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

  @override
  Future<ConversationToken> createStandaloneConversation({
    required String accountId,
    required StandaloneConversationType type,
    required String roomName,
  }) async {
    lastCreateAccountId = accountId;
    lastCreateRecipient = null;
    lastCreateRoomName = roomName;
    lastStandaloneType = type;
    final error = createError;
    if (error != null) {
      throw error;
    }
    return createResult!;
  }
}
