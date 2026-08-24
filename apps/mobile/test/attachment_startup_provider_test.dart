import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/attachment_service.dart';

void main() {
  test(
    'account observation eagerly starts durable attachment recovery',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final started = Completer<void>();
      final pendingService = Completer<AttachmentService>();
      final container = ProviderContainer(
        overrides: <Override>[
          appDatabaseProvider.overrideWithValue(database),
          attachmentServiceProvider.overrideWith((ref) async {
            started.complete();
            return pendingService.future;
          }),
        ],
      );
      addTearDown(container.dispose);

      final subscription = container.listen(
        accountsProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await started.future.timeout(const Duration(seconds: 1));
    },
  );
}
