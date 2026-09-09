import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/credential_vault.dart';
import 'package:nextcloudtalk/features/onboarding/onboarding_coordinator.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';

AppDatabase openTestDatabase() {
  return AppDatabase.forTesting(NativeDatabase.memory());
}

final class MemoryCredentialVault
    implements CredentialVault, PendingRevocationStore {
  final Map<String, String> values = {};

  @override
  Future<void> deleteAppPassword(String accountId) async {
    values.remove(accountId);
  }

  @override
  Future<String?> readAppPassword(String accountId) async => values[accountId];

  @override
  Future<void> writeAppPassword(String accountId, String appPassword) async {
    values[accountId] = appPassword;
  }

  String? pendingRevocations;

  @override
  Future<String?> readPendingRevocations() async => pendingRevocations;

  @override
  Future<void> writePendingRevocations(String? json) async {
    pendingRevocations = json;
  }
}

final class RecordingLoginPageLauncher implements LoginPageLauncher {
  RecordingLoginPageLauncher({this.result = true});

  final bool result;
  Uri? openedUri;

  @override
  Future<bool> open(Uri uri) async {
    openedUri = uri;
    return result;
  }
}

Widget localizedTestApp({
  required Widget home,
  ThemeData? theme,
  Locale locale = const Locale('en'),
  double textScale = 1,
  List<NavigatorObserver> navigatorObservers = const <NavigatorObserver>[],
}) {
  return MaterialApp(
    locale: locale,
    navigatorObservers: navigatorObservers,
    theme: theme ?? AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    // Accessibility text sizes are a real device setting, so a suite has to be
    // able to pump its own screen at one instead of building a second app.
    builder: textScale == 1
        ? null
        : (context, inner) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: inner!,
          ),
    home: home,
  );
}

Map<String, Object?> readyStatusJson() => <String, Object?>{
  'installed': true,
  'maintenance': false,
  'needsDbUpgrade': false,
  'version': '34.0.1.0',
  'versionstring': '34.0.1',
  'edition': '',
  'productname': 'Nextcloud',
  'extendedSupport': false,
};

Map<String, Object?> loginInitializationJson() => <String, Object?>{
  'poll': <String, Object?>{
    'token': 'fixture-poll-token-root-00000000000000000000000000000000',
    'endpoint': 'https://cloud.example.invalid/index.php/login/v2/poll',
  },
  'login':
      'https://cloud.example.invalid/index.php/login/v2/flow/'
      'fixture-login-token-root-00000000000000000000000000000000',
};

Map<String, Object?> loginSuccessJson() => <String, Object?>{
  'server': 'https://cloud.example.invalid',
  'loginName': 'fixture-user',
  'appPassword': 'fixture-app-password-never-use',
};

/// A `/cloud/capabilities` body.
///
/// [attachments] is written under `spreed.config.attachments` verbatim, and
/// leaving it null is a server that says NOTHING about attachments — which is
/// a different server from one that sends `{'allowed': false}`, even though
/// `AttachmentCapabilityProfile` decides the same way about both.
Map<String, Object?> capabilitiesJson({
  bool withTalk = true,
  Iterable<String>? talkFeatures,
  Iterable<String>? notificationPushFeatures,
  Map<String, Object?>? attachments,
}) {
  return <String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'version': <String, Object?>{
          'major': 34,
          'minor': 0,
          'micro': 1,
          'string': '34.0.1',
          'edition': '',
          'extendedSupport': false,
        },
        'capabilities': <String, Object?>{
          if (withTalk)
            'spreed': <String, Object?>{
              'features': <Object?>[
                ...?talkFeatures,
                if (talkFeatures == null) ...<String>[
                  'conversation-v4',
                  'chat-v2',
                ],
              ],
              'features-local': <Object?>[],
              'config': <String, Object?>{'attachments': ?attachments},
              'version': '24.0.2',
            },
          if (notificationPushFeatures != null)
            'notifications': <String, Object?>{
              'push': <Object?>[...notificationPushFeatures],
            },
        },
      },
    },
  };
}

Object? readFixtureJson(String relativePath) {
  return jsonDecode(File('../../contracts/$relativePath').readAsStringSync());
}

/// Pumps until [condition] holds, giving up on a real-time deadline.
///
/// A fixed number of five-millisecond waits is a budget of about one second,
/// and one second is not enough on a machine that is also running a build or
/// the rest of the suite - which is how two of these turned into intermittent
/// failures whose message blamed the feature under test. The deadline is
/// generous on purpose: a test that is genuinely stuck still fails, but a slow
/// machine is given the time it needs rather than a verdict.
Future<void> pumpUntilCondition(
  WidgetTester tester,
  bool Function() condition, {
  String reason = 'the condition was never reached',
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    await tester.pump();
    if (condition()) {
      return;
    }
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out after ${timeout.inSeconds}s: $reason');
    }
    await tester.runAsync(() => Future<void>.delayed(step));
  }
}
