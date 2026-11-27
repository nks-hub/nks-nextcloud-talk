import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/composer/gif_favorites_store.dart';
import 'package:nextcloudtalk/features/chat/composer/gif_favorites_sync.dart';
import 'package:nextcloudtalk/features/chat/composer/giphy.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_extensions_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'owntalk_extensions_test_support.dart';
import 'test_support.dart';

final _serverBase = ServerBase.parse('https://cloud.example.invalid/cloud');
final _phoneAccount = AccountId.parse('phone-account');
final _desktopAccount = AccountId.parse('desktop-account');
final _otherAccount = AccountId.parse('other-account');

GiphyEntry _gif(String id) => GiphyEntry(
  resourceUrl: Uri.https('giphy.com', '/gifs/animal-$id'),
  thumbnailUrl: _serverBase.uri.replace(
    path: '/cloud/index.php/apps/integration_giphy/gif/$id',
  ),
  title: 'Animal $id',
  subline: '',
);

void main() {
  test(
    'two clients replay a lost save without undoing a later removal',
    () async {
      final server = _FavoriteServer();
      final phone = await _Device.create(server);
      final desktop = await _Device.create(server);
      await phone.add(_phoneAccount, 'fixture-owner');
      await desktop.add(_desktopAccount, 'fixture-owner');
      await desktop.add(_otherAccount, 'fixture-other');
      final otter = _gif('otter');
      final seal = _gif('seal');

      server.offline = true;
      await phone.store.setFavorite(_phoneAccount, otter, saved: true);
      await phone.refresh(_phoneAccount);
      expect((await phone.store.read(_phoneAccount)).single.title, otter.title);
      expect(server.writes, isEmpty);
      phone.restart();

      server.offline = false;
      server.loseNextSave = true;
      await phone.refresh(_phoneAccount);
      final save = server.writes.single;
      expect(save.account, 'fixture-owner');
      expect(save.method, 'PUT');
      expect((await phone.store.read(_phoneAccount)).single.title, otter.title);

      await desktop.store.setFavorite(_otherAccount, seal, saved: true);
      await desktop.refresh(_otherAccount);
      expect(
        (await desktop.store.read(_otherAccount)).single.title,
        seal.title,
      );
      expect(server.writes, [save]);
      await desktop.refresh(_desktopAccount);
      final downloaded = (await desktop.store.read(_desktopAccount)).single;
      expect(sameFavoriteGif(otter, downloaded), isTrue);
      expect(downloaded.resourceUrl, Uri.https('giphy.com', '/gifs/otter'));
      expect(
        downloaded.thumbnailUrl.path,
        '/cloud/index.php/apps/integration_giphy/gif/otter',
      );
      expect(downloaded.thumbnailUrl.queryParameters, {
        'preferredVersion': 'fixed_width',
      });

      await desktop.store.setFavorite(_desktopAccount, otter, saved: false);
      await desktop.refresh(_desktopAccount);
      phone.restart();
      await phone.refresh(_phoneAccount);

      expect(server.writes.map((change) => change.method), [
        'PUT',
        'DELETE',
        'PUT',
      ]);
      expect(server.writes.last, save);
      expect(await phone.store.read(_phoneAccount), isEmpty);
      expect(await desktop.store.read(_desktopAccount), isEmpty);
      expect(
        (await desktop.store.read(_otherAccount)).single.title,
        seal.title,
      );
      expect(server.itemsFor('fixture-owner'), isEmpty);
    },
  );

  test('imports an existing file once and accepts a remote deletion', () async {
    final server = _FavoriteServer();
    final phone = await _Device.create(server);
    final desktop = await _Device.create(server);
    await phone.add(_phoneAccount, 'fixture-owner');
    await desktop.add(_desktopAccount, 'fixture-owner');
    final otter = _gif('otter');
    final seal = _gif('seal');
    await phone.store.setFavorite(_phoneAccount, otter, saved: true);
    await phone.store.setFavorite(_phoneAccount, seal, saved: true);
    await _useLegacyFavoritesFile(phone.directory);

    await phone.refresh(_phoneAccount);
    expect(server.writes.map((write) => write.id), ['otter', 'seal']);
    await desktop.refresh(_desktopAccount);
    expect(
      (await desktop.store.read(_desktopAccount)).map((entry) => entry.title),
      [seal.title, otter.title],
    );
    await desktop.add(_otherAccount, 'fixture-independent');
    await desktop.store.setFavorite(_otherAccount, otter, saved: true);
    await desktop.refresh(_otherAccount);
    await desktop.store.setFavorite(_desktopAccount, otter, saved: false);
    await desktop.refresh(_desktopAccount);
    await phone.refresh(_phoneAccount);
    await desktop.refresh(_otherAccount);
    expect((await phone.store.read(_phoneAccount)).single.title, seal.title);
    expect(
      (await desktop.store.read(_otherAccount)).single.resourceUrl,
      Uri.https('giphy.com', '/gifs/otter'),
    );
    expect(server.writes.map((write) => (write.account, write.method)), [
      ('fixture-owner', 'PUT'),
      ('fixture-owner', 'PUT'),
      ('fixture-independent', 'PUT'),
      ('fixture-owner', 'DELETE'),
    ]);
  });

  test(
    'a stale snapshot cannot restore a queued deletion or a removed account',
    () async {
      final server = _FavoriteServer();
      final phone = await _Device.create(server);
      await phone.add(_phoneAccount, 'fixture-owner');
      final otter = _gif('otter');
      await phone.store.setFavorite(_phoneAccount, otter, saved: true);
      await phone.refresh(_phoneAccount);

      final first = server.holdList();
      final stale = phone.refresh(_phoneAccount);
      await first.started.future;
      await phone.store.setFavorite(_phoneAccount, otter, saved: false);
      first.release.complete();
      await stale;
      expect(await phone.store.read(_phoneAccount), isEmpty);
      expect(server.writes.map((change) => change.method), ['PUT']);
      phone.restart();
      await phone.refresh(_phoneAccount);
      expect(server.writes.map((change) => change.method), ['PUT', 'DELETE']);

      await phone.store.setFavorite(_phoneAccount, _gif('cat'), saved: true);
      final second = server.holdList();
      final removed = phone.refresh(_phoneAccount);
      await second.started.future;
      await phone.store.delete(_phoneAccount);
      second.release.complete();
      await removed;
      expect(await phone.store.read(_phoneAccount), isEmpty);
      final files = await phone.directory
          .list(recursive: true)
          .where((e) => e is File)
          .toList();
      expect(files, isEmpty);
    },
  );
}

Future<void> _useLegacyFavoritesFile(Directory directory) async {
  final files = await directory
      .list(recursive: true)
      .where((e) => e is File)
      .toList();
  final file = files.single as File;
  final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  for (final entry in data['entries'] as List<dynamic>) {
    (entry as Map<String, dynamic>)
      ..remove('id')
      ..remove('operationId');
  }
  await file.writeAsString(jsonEncode(data));
}

final class _Device {
  _Device(this.database, this.directory, this.api) {
    extensions = OwnTalkExtensionsService(
      accounts: _accounts,
      credentials: _credentials,
      api: api,
    );
    restart();
  }

  static Future<_Device> create(_FavoriteServer server) async {
    final device = _Device(
      openTestDatabase(),
      await Directory.systemTemp.createTemp('owntalk-gif-sync-'),
      HttpNextcloudApi(client: MockClient(server.handle)),
    );
    addTearDown(() async {
      device.sync.dispose();
      device.store.dispose();
      await device.api.close();
      await device.database.close();
      await device.directory.delete(recursive: true);
    });
    return device;
  }

  final AppDatabase database;
  final Directory directory;
  final HttpNextcloudApi api;
  late final _accounts = AccountRepository(database);
  final _credentials = MemoryCredentialVault();
  late final OwnTalkExtensionsService extensions;
  GifFavoritesStore? _store;
  GifFavoritesSync? _sync;

  GifFavoritesStore get store => _store!;
  GifFavoritesSync get sync => _sync!;

  Future<void> add(AccountId account, String login) async {
    await _accounts.upsertAccount(
      accountId: account.value,
      serverUrl: _serverBase.uri.toString(),
      loginName: login,
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    _credentials.values[account.value] = 'test-app-password';
  }

  void restart() {
    _sync?.dispose();
    _store?.dispose();
    _store = GifFavoritesStore(directory: directory);
    _sync = GifFavoritesSync(store, extensions);
  }

  Future<void> refresh(AccountId account) => sync.refresh(account, _serverBase);
}

typedef _Write = ({
  String account,
  String method,
  String id,
  String operationId,
});
typedef _HeldList = ({Completer<void> started, Completer<void> release});

final class _FavoriteServer {
  static const _supportedLogins = {'fixture-owner', 'fixture-independent'};
  final _items = <String, List<Map<String, String>>>{};
  final writes = <_Write>[];
  final _seen = <(String, String), _Write>{};
  _HeldList? _held;
  bool offline = false;
  bool loseNextSave = false;

  _HeldList holdList() =>
      _held = (started: Completer<void>(), release: Completer<void>());

  List<Map<String, String>> itemsFor(String account) =>
      _items.putIfAbsent(account, () => []);

  Future<http.Response> handle(http.Request request) async {
    if (offline) throw http.ClientException('Offline', request.url);
    final auth = request.headers['Authorization']!;
    final account = utf8
        .decode(base64Decode(auth.substring(6)))
        .split(':')
        .first;
    if (request.url.path.endsWith('/cloud/capabilities')) {
      final envelope = capabilitiesJson()['ocs']! as Map<String, Object?>;
      final data = envelope['data']! as Map<String, Object?>;
      final capabilities = data['capabilities']! as Map<String, Object?>;
      if (_supportedLogins.contains(account)) {
        capabilities['owntalk_extensions'] = ownTalkCapabilityJson(
          features: ['personal.gifFavorites'],
        );
      }
      return ocsResponse(200, data);
    }
    const path =
        '/cloud/ocs/v2.php/apps/owntalk_extensions/api/v1/personal/gifs';
    expect(_supportedLogins, contains(account));
    expect(request.url.queryParameters['format'], 'json');
    final items = itemsFor(account);
    if (request.url.path == path && request.method == 'GET') {
      final snapshot = List.of(items);
      final held = _held;
      if (held != null) {
        _held = null;
        held.started.complete();
        await held.release.future;
      }
      return ocsResponse(200, {'items': snapshot});
    }
    expect(request.url.path, startsWith('$path/giphy/'));
    final id = request.url.pathSegments.last;
    final body = request.method == 'PUT'
        ? jsonDecode(request.body) as Map<String, dynamic>
        : null;
    final operationId =
        (body?['operationId'] ?? request.url.queryParameters['operationId'])
            as String;
    final change = (
      account: account,
      method: request.method,
      id: id,
      operationId: operationId,
    );
    writes.add(change);
    final first = _seen[(account, operationId)];
    if (first == null) {
      _seen[(account, operationId)] = change;
      items.removeWhere((entry) => entry['id'] == id);
      if (body != null) {
        expect(body.keys, unorderedEquals(['operationId', 'title', 'subline']));
        items.insert(0, {
          'provider': 'giphy',
          'id': id,
          'title': body['title'] as String,
          'subline': body['subline'] as String,
        });
        if (loseNextSave) {
          loseNextSave = false;
          throw http.ClientException('Reply lost', request.url);
        }
      } else {
        expect(request.method, 'DELETE');
      }
    } else {
      expect(first, change);
    }
    return ocsResponse(200, {'saved': items.any((entry) => entry['id'] == id)});
  }
}
