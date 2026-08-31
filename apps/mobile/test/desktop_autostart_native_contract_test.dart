import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relativePath) {
  return File(relativePath).readAsStringSync();
}

void main() {
  test('Windows autostart uses the current-user Run registry value', () {
    final source = _read('windows/runner/desktop_autostart.cpp');
    expect(
      source,
      contains('Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run'),
    );
    expect(source, contains('HKEY_CURRENT_USER'));
    expect(source, contains('RegSetValueExW'));
    expect(source, contains('RegDeleteValueW'));
    expect(
      _read('windows/runner/CMakeLists.txt'),
      contains('desktop_autostart.cpp'),
    );
  });

  test('macOS autostart uses the main-app login item service', () {
    final source = _read('macos/Runner/MainFlutterWindow.swift');
    expect(source, contains('import ServiceManagement'));
    expect(source, contains('SMAppService.mainApp'));
    expect(source, contains('#available(macOS 13.0, *)'));
    expect(source, contains('try service.register()'));
    expect(source, contains('try service.unregister()'));
  });

  test('Linux autostart owns an XDG desktop entry for the running binary', () {
    final source = _read('linux/runner/desktop_autostart.cc');
    expect(source, contains('g_get_user_config_dir()'));
    expect(source, contains('com.nkshub.nextcloudtalk.desktop'));
    expect(source, contains('X-GNOME-Autostart-enabled'));
    expect(source, contains('g_file_read_link("/proc/self/exe"'));
    expect(source, contains('g_file_set_contents'));
    expect(
      _read('linux/runner/CMakeLists.txt'),
      contains('desktop_autostart.cc'),
    );
  });
}
