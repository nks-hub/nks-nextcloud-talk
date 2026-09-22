import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../test/test_support.dart';

/// Uses a dedicated server account without opening the installed app's profile.
final class DesktopCallFixture {
  DesktopCallFixture._(
    this.container,
    this.database,
    this.directory,
    this.paths,
  );

  static const accountId = 'desktop-call-fixture';
  final ProviderContainer container;
  final AppDatabase database;
  final Directory directory;
  final PathProviderPlatform paths;

  static Future<DesktopCallFixture?> openFromEnvironment() async {
    final path = Platform.environment['NKS_CALL_ACCESS_FILE'];
    if (path == null) return null;
    if (Platform.environment['NKS_TALK_INTEGRATION_TEST'] != '1') {
      throw StateError('The isolated Windows test mode must be enabled.');
    }
    final access = jsonDecode(await File(path).readAsString()) as Map;
    final origin = access['origin'] as String;
    final user = access['user'] as String;
    final password = access['password'] as String;
    if (Uri.parse(origin).scheme != 'https' ||
        user.isEmpty ||
        password.isEmpty) {
      throw const FormatException('Invalid live test access file.');
    }
    final database = openTestDatabase();
    final vault = MemoryCredentialVault();
    await vault.writeAppPassword(accountId, password);
    await AccountRepository(database).upsertAccount(
      accountId: accountId,
      serverUrl: origin,
      loginName: user,
      serverProductName: 'Nextcloud',
      createdAt: DateTime.now().toUtc(),
    );
    final directory = await Directory.systemTemp.createTemp('nks-talk-call-');
    final paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _CallPaths(directory.path);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        clientPushEnabledProvider.overrideWithValue(false),
      ],
    );
    return DesktopCallFixture._(container, database, directory, paths);
  }

  Future<void> dispose() async {
    await container.read(chatServiceProvider).close();
    await container.read(callSignalingCoordinatorProvider).dispose();
    await container.read(callLifecycleServiceProvider).dispose();
    container.dispose();
    await database.close();
    PathProviderPlatform.instance = paths;
    await directory.delete(recursive: true);
  }
}

final class _CallPaths extends PathProviderPlatform {
  _CallPaths(this.path);
  final String path;

  @override
  Future<String> getTemporaryPath() async => path;
  @override
  Future<String> getApplicationSupportPath() async => path;
  @override
  Future<String> getApplicationDocumentsPath() async => path;
  @override
  Future<String> getApplicationCachePath() async => path;
  @override
  Future<String> getDownloadsPath() async => path;
}

typedef CallAudioCounters = ({int sent, int received});

/// Observes native connection IDs and reads real RTP counters through getStats.
final class DesktopCallStats {
  static const _channel = 'FlutterWebRTC.Method';
  static const _codec = StandardMethodCodec();
  final _messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final _connections = <String>{};

  void start() {
    _messenger.setMockMessageHandler(_channel, (message) async {
      final call = _codec.decodeMethodCall(message);
      final response = await _messenger.delegate.send(_channel, message);
      if (response != null && call.method == 'createPeerConnection') {
        final value = _codec.decodeEnvelope(response) as Map;
        _connections.add(value['peerConnectionId'] as String);
      } else if (call.method == 'peerConnectionDispose') {
        _connections.remove((call.arguments as Map)['peerConnectionId']);
      }
      return response;
    });
  }

  Future<CallAudioCounters> audioCounters() async {
    var sent = 0;
    var received = 0;
    for (final id in _connections.toList()) {
      final response = await _messenger.delegate.send(
        _channel,
        _codec.encodeMethodCall(
          MethodCall('getStats', {'peerConnectionId': id}),
        ),
      );
      if (response == null) throw StateError('Native WebRTC stats are absent.');
      final result = _codec.decodeEnvelope(response) as Map;
      for (final report in result['stats'] as List) {
        final values = report['values'] as Map;
        if ((values['kind'] ?? values['mediaType']) != 'audio') continue;
        if (report['type'] == 'outbound-rtp') {
          sent += (values['bytesSent'] as num?)?.toInt() ?? 0;
        } else if (report['type'] == 'inbound-rtp') {
          received += (values['bytesReceived'] as num?)?.toInt() ?? 0;
        }
      }
    }
    return (sent: sent, received: received);
  }

  Future<List<Map<String, Object?>>> diagnostics() async {
    final snapshots = <Map<String, Object?>>[];
    for (final id in _connections.toList()) {
      Future<Object?> invoke(String method) async {
        final response = await _messenger.delegate.send(
          _channel,
          _codec.encodeMethodCall(MethodCall(method, {'peerConnectionId': id})),
        );
        return response == null ? null : _codec.decodeEnvelope(response);
      }

      final stats = await invoke('getStats') as Map;
      final senders = await invoke('getSenders') as Map;
      snapshots.add({
        'connection': await invoke('getConnectionState'),
        'ice': await invoke('getIceConnectionState'),
        'tracks': [
          for (final sender in senders['senders'] as List)
            {
              for (final field in ['kind', 'enabled', 'readyState'])
                if ((sender['track'] as Map).containsKey(field))
                  field: sender['track'][field],
            },
        ],
        'reports': [
          for (final report in stats['stats'] as List)
            if ([
              'outbound-rtp',
              'inbound-rtp',
              'transport',
              'candidate-pair',
              'local-candidate',
              'remote-candidate',
              'media-source',
            ].contains(report['type']))
              {
                'type': report['type'],
                for (final field in [
                  'kind',
                  'mediaType',
                  'bytesSent',
                  'bytesReceived',
                  'packetsSent',
                  'packetsReceived',
                  'state',
                  'nominated',
                  'dtlsState',
                  'requestsSent',
                  'responsesReceived',
                  'candidateType',
                  'protocol',
                  'audioLevel',
                  'totalAudioEnergy',
                ])
                  if ((report['values'] as Map).containsKey(field))
                    field: report['values'][field],
              },
        ],
      });
    }
    return snapshots;
  }

  void dispose() => _messenger.setMockMessageHandler(_channel, null);
}
