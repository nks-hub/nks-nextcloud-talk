import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Persists the user's chosen [ThemeMode] locally. Not per-account: the
/// theme choice applies to the whole app regardless of the active account.
abstract interface class ThemePreferenceStore {
  Future<ThemeMode> read();

  Future<void> write(ThemeMode mode);
}

final class FileThemePreferenceStore implements ThemePreferenceStore {
  FileThemePreferenceStore({this._directory});

  final Directory? _directory;

  Future<File> _file() async {
    final dir = _directory ?? await getApplicationSupportDirectory();
    return File('${dir.path}/theme_mode.txt');
  }

  @override
  Future<ThemeMode> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return ThemeMode.system;
      }
      final raw = (await file.readAsString()).trim();
      return ThemeMode.values.firstWhere(
        (mode) => mode.name == raw,
        orElse: () => ThemeMode.system,
      );
    } on Object {
      return ThemeMode.system;
    }
  }

  @override
  Future<void> write(ThemeMode mode) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(mode.name);
    } on Object {
      // ponytail: best effort — a failed write just falls back to the last
      // in-memory choice for this session, no user-visible data loss.
    }
  }
}
