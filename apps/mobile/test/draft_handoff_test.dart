import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/draft_handoff.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  const room = (accountId: 'account-a', roomToken: 'room123', threadId: 71);
  const other = (accountId: 'account-b', roomToken: 'room123', threadId: 71);
  const otherThread = (
    accountId: 'account-a',
    roomToken: 'room123',
    threadId: 72,
  );
  late Directory storage;
  late _DraftServer server;
  late DraftHandoffStore a;
  late DraftHandoffStore b;
  DraftHandoffStore device(String name) => DraftHandoffStore(
    server.request,
    directory: Directory('${storage.path}/$name'),
  );
  setUp(() async {
    storage = await Directory.systemTemp.createTemp('handoff-test');
    server = _DraftServer();
    a = device('phone');
    b = device('desktop');
  });
  tearDown(() => storage.delete(recursive: true));

  test(
    'opt-in precedes data, account removal resets the local identity',
    () async {
      expect(await a.stage(room, 'private', 203), isNull);
      expect(await a.sync(room), isEmpty);
      expect(server.calls, isEmpty);
      await a.setEnabled('account-a', true);
      final shared = (await a.stage(room, 'shared', 203))!;
      expect((await a.sync(room)).single.id, shared.id);
      expect(await a.enabled('account-b'), false);
      expect(await a.stage(other, 'different account', null), isNull);
      expect(await a.sync(otherThread), isEmpty);
      await a.delete(AccountId.parse('account-a'));
      final restarted = device('phone');
      expect(await restarted.enabled('account-a'), false);
      expect(await restarted.sync(room), isEmpty);
    },
  );

  test(
    'two offline edits survive restart and sending one keeps the other',
    () async {
      await a.setEnabled('account-a', true);
      await b.setEnabled('account-a', true);
      await a.stage(room, 'shared beginning', 200);
      final original = (await a.sync(room)).single;
      final copy = (await b.sync(room)).single;
      await b.adopt(room, copy);
      server.online = false;
      final phone = (await a.stage(room, 'phone edit', 201))!;
      final desktop = (await b.stage(room, 'desktop edit', 202))!;
      await expectLater(a.sync(room), throwsA(isA<SocketException>()));
      await expectLater(b.sync(room), throwsA(isA<SocketException>()));
      expect(phone.baseId, original.id);
      expect(desktop.baseId, original.id);
      expect(phone.id, isNot(desktop.id));
      server.online = true;
      a = device('phone');
      b = device('desktop');
      await a.sync(room);
      final versions = await b.sync(room);
      expect(
        versions.map((v) => (v.text, v.replyTo)),
        unorderedEquals([('phone edit', 201), ('desktop edit', 202)]),
      );
      final sent = (await a.stage(
        room,
        'phone edit',
        201,
        sendingDraftId: 'first',
      ))!;
      expect(sent.id, phone.id);
      await a.stage(room, 'next text', null);
      expect((await device('phone').reserved(room, 'first'))?.id, sent.id);
      server.online = false;
      await expectLater(
        a.admitted(room, sent),
        throwsA(isA<SocketException>()),
      );
      server.online = true;
      final after = await device('phone').sync(room);
      expect(
        after.map((v) => v.text),
        unorderedEquals(['desktop edit', 'next text']),
      );
      expect(after.singleWhere((v) => v.id == desktop.id).replyTo, 202);
      expect(await device('phone').reserved(room, 'first'), isNull);
      await a.clearCurrent(room);
      expect((await a.sync(room)).single.id, desktop.id);
      expect(
        server.calls.where((call) => call == 'DELETE:${desktop.id}'),
        isEmpty,
      );
    },
  );

  test('lost PUT response replays the immutable revision only', () async {
    await a.setEnabled(room.accountId, true);
    final first = (await a.stage(room, 'quote', 204))!;
    server.losePut = true;
    await expectLater(a.sync(room), throwsA(isA<SocketException>()));
    final list = await device('phone').sync(room);
    expect(list.single.id, first.id);
    expect(server.calls.where((call) => call == 'PUT:${first.id}').length, 2);
  });
}

final class _DraftServer {
  bool online = true, losePut = false;
  final calls = <String>[];
  final rooms = <String, Map<String, Map<String, Object?>>>{};
  final accepted = <String, Map<String, Object?>>{};
  Future<Map<String, dynamic>> request({
    required String accountId,
    required String feature,
    required List<String> path,
    String method = 'GET',
    Map<String, String>? query,
    Map<String, Object?>? values,
  }) async {
    expect(feature, draftHandoffFeature);
    expect(path.first, 'room');
    expect(path[2], 'drafts');
    if (!online) throw const SocketException('offline');
    final rows = rooms.putIfAbsent(
      '$accountId/${path.take(4).join('/')}',
      () => {},
    );
    final id = path.last;
    calls.add('$method:$id');
    if (method == 'PUT') {
      final before = accepted[id];
      if (before == null) {
        final row = {'id': id, ...values!};
        accepted[id] = row;
        rows.remove(values['baseId']);
        rows[id] = row;
      } else {
        expect(before, {'id': id, ...values!});
      }
      if (losePut) {
        losePut = false;
        throw const SocketException('accepted response lost');
      }
    } else if (method == 'DELETE') {
      rows.remove(id);
    }
    return {'variants': rows.values.toList()};
  }
}
