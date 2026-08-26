import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';

void main() {
  test(
    'macOS creates the native deep link bridge',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(deepLinkPlatformProvider), isNotNull);
    },
    skip: !Platform.isMacOS,
  );
}
