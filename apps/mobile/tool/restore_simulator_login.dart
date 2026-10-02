import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:nextcloudtalk/app.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/onboarding/onboarding_coordinator.dart';

// Recovery is limited to an empty simulator profile. Credentials are consumed
// from its Documents directory, never embedded in a compiled app or a log.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isIOS || !Platform.environment.containsKey('SIMULATOR_UDID')) {
    throw StateError('Login recovery requires an iOS simulator');
  }
  final documents = await getApplicationDocumentsDirectory();
  final file = File('${documents.path}/restore-login.json');
  final container = ProviderContainer();
  try {
    final accounts = container.read(accountRepositoryProvider);
    if ((await accounts.listAccounts()).isNotEmpty) {
      throw StateError('Login recovery requires an empty profile');
    }
    final config =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final account = await container
        .read(onboardingCoordinatorProvider)
        .commitScannedLogin(
          QrLoginCredentials(
            server: ServerBase.parse(config['origin']),
            loginName: config['username'] as String,
            secret: config['password'] as String,
            isOneTime: false,
          ),
          CancellationSignal(),
        );
    final synced = await container
        .read(conversationSyncServiceProvider)
        .syncConfirmed(account.id, forceFull: true);
    if (!synced) throw StateError('Restored account did not synchronize');
    final rooms = await accounts.watchConversations(account.id).first;
    debugPrint('Simulator login restored; conversations: ${rooms.length}');
  } on Object {
    container.dispose();
    rethrow;
  } finally {
    if (await file.exists()) await file.delete();
  }
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const NextcloudTalkApp(),
    ),
  );
}
