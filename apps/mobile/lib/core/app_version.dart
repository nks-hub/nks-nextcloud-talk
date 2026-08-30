/// Application version as declared in `apps/mobile/pubspec.yaml`.
///
/// The pubspec is the only source of truth for the shipped version — the
/// Windows installer script reads it straight from there — and Flutter has no
/// runtime lookup for it without an extra platform plugin. The value is
/// therefore mirrored here and `test/diagnostics_screen_test.dart` fails as
/// soon as the two drift apart.
///
/// Known limitation: a build that overrides `--build-name` or `--build-number`
/// on the command line still reports the pubspec value here.
const appVersionName = '0.1.0';

/// Build number part of the pubspec `version:` field. See [appVersionName].
const appBuildNumber = '18';
