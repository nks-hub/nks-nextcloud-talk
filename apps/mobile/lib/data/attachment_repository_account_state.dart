part of 'attachment_repository.dart';

AttachmentRuntimeAccountsCompanion _runtimeAccountCompanion(
  AttachmentAccountState account,
  int updatedAtMillis,
) => AttachmentRuntimeAccountsCompanion.insert(
  accountId: account.accountId.value,
  serverUrl: account.server.value,
  lane: account.lane.name,
  credentialGeneration: account.credentialGeneration,
  capabilityGeneration: account.capabilityGeneration,
  updatedAtMillis: updatedAtMillis,
);

Future<void> _resumeSuspendedAttachmentAccount(
  AppDatabase database,
  AccountId accountId,
  DateTime updatedAt,
) async {
  await (database.update(database.attachmentRuntimeAccounts)..where(
        (row) =>
            row.accountId.equals(accountId.value) &
            row.lane.equals(AttachmentAccountLane.suspended.name),
      ))
      .write(
        AttachmentRuntimeAccountsCompanion(
          lane: Value(AttachmentAccountLane.ready.name),
          updatedAtMillis: Value(updatedAt.toUtc().millisecondsSinceEpoch),
        ),
      );
}
