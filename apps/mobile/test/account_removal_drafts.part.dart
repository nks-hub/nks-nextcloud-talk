part of 'account_removal_service_test.dart';

Future<void> _seedAccountDrafts(
  AppDatabase database,
  String accountId,
  String roomToken,
) async {
  await database
      .into(database.chatDrafts)
      .insert(
        ChatDraftsCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          scopeKey: 'root',
          draftText: 'Half-written and private',
          updatedAtMillis: 1770000000,
        ),
      );
  await database
      .into(database.refusedTextDrafts)
      .insert(
        RefusedTextDraftsCompanion.insert(
          accountId: accountId,
          roomToken: roomToken,
          draftId: 'local-draft',
          message: 'Waiting for admission',
          silent: false,
          createdAtMillis: 1770000000,
        ),
      );
}
