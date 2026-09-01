# Upstream provenance

This package is a desktop-only fork of `desktop_drop` 0.8.3 from
<https://github.com/MixinNetwork/flutter-plugins/tree/main/packages/desktop_drop>.

- Upstream release: <https://pub.dev/packages/desktop_drop/versions/0.8.3>
- Pub archive SHA-256: `4c639b4cb80780d1cb94c3252309772e5e68522372181497bc9cd2fbd973aec1`
- Imported: 2026-09-01
- License: Apache-2.0, preserved in `LICENSE`

The Android, web and example targets are intentionally omitted. The app uses
this fork only on macOS, Linux and Windows. The web dispatcher branch and the
unused Android coordinate scaling were removed with those targets. This keeps
Android Gradle configuration independent of a feature that never runs there.
The web-oriented `universal_platform` dependency was replaced with `dart:io`
platform checks because this fork has no web target.
