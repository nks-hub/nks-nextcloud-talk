import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app.dart';
import 'package:nextcloudtalk/app_providers.dart';

import 'test_support.dart';

void main() {
  testWidgets('app startup initializes the system call bridge', (tester) async {
    final database = openTestDatabase();
    addTearDown(database.close);
    var initialized = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          callKitChannelProvider.overrideWith((ref) {
            initialized = true;
            return null;
          }),
        ],
        child: const NextcloudTalkApp(),
      ),
    );
    expect(initialized, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
