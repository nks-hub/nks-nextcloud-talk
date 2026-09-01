import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';

/// A conversation sync rewrites the cursor, the hash, the last sync time and
/// the last error on the account row. If the media provider keyed on the whole
/// row, every poll would be a different key: the running provider would be
/// disposed and the picture refetched, which is what made images and GIFs
/// blink every few seconds in an open room.
void main() {
  const base = StoredAccount(
    id: 'account-a',
    serverUrl: 'https://cloud.example.invalid',
    loginName: 'alice',
    serverProductName: 'Nextcloud',
    talkFeaturesJson: '[]',
    selected: true,
    createdAtMillis: 1767225600000,
  );
  final uri = Uri.parse('https://cloud.example.invalid/index.php/core/preview');

  ChatMediaProviderKey keyFor(StoredAccount account) =>
      ChatMediaProviderKey(account: account, uri: uri);

  test('a sync of the same account keeps the same media key', () {
    final synced = base.copyWith(
      lastSyncedAtMillis: const Value(1767225700000),
      conversationCursor: const Value('cursor-2'),
      conversationHash: const Value('hash-2'),
      lastSyncError: const Value('network'),
    );

    expect(synced, isNot(base), reason: 'the row itself really did change');
    expect(keyFor(synced), keyFor(base));
    expect(keyFor(synced).hashCode, keyFor(base).hashCode);
  });

  test('a different account or address is a different key', () {
    expect(keyFor(base.copyWith(id: 'account-b')), isNot(keyFor(base)));
    expect(
      keyFor(base.copyWith(serverUrl: 'https://other.example.invalid')),
      isNot(keyFor(base)),
    );
    expect(keyFor(base.copyWith(loginName: 'bob')), isNot(keyFor(base)));
    expect(
      ChatMediaProviderKey(
        account: base,
        uri: Uri.parse('https://cloud.example.invalid/other'),
      ),
      isNot(keyFor(base)),
    );
  });
}
