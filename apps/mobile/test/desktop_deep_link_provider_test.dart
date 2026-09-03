import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('desktops with a deep link runner create the native bridge', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(deepLinkPlatformProvider), isNotNull);
  }, skip: !Platform.isMacOS && !Platform.isWindows);
}
