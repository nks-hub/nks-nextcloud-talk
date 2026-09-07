# Local flutter_webrtc patches

Runtime sources are vendored from flutter_webrtc 1.6.1:
https://pub.dev/api/archives/flutter_webrtc-1.6.1.tar.gz

Archive SHA-256:
`a2eb4a45bf741c4e3fb6731dbbe35daef5f366c3783645e091d03f205b70b733`

The archive hash matches the published package metadata and the application's
previous hosted lockfile. All platform runtime directories, shared sources,
package metadata and upstream licenses are retained. Upstream examples and
development tooling are omitted.

macOS patches preserve explicit monitor selection on the legacy capturer, reject
a vanished requested display, serialize asynchronous capture startup and stop,
and propagate ScreenCaptureKit startup failures through getDisplayMedia.
Native regression tests live in the application's macOS RunnerTests target.
