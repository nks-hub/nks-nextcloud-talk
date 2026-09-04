# Telemetry

The client reports crashes and anonymous screen usage to our own self-hosted
Sentry and Rybbit instances. The scope is deliberately narrower than what both
SDKs can do; this document is a binding description of what may leave the device.

## Enabled only in our builds

The configuration arrives exclusively through `--dart-define`, never from a file
the app reads at runtime, and never from the repository — both the DSN and the
Rybbit host are internal addresses and this repository is public.

```sh
cp apps/mobile/telemetry.env.example apps/mobile/telemetry.env
flutter build apk --dart-define-from-file=telemetry.env
```

`telemetry.env` is in `.gitignore`. A build without that file gets empty values
and then **no SDK is initialized at all**: `TelemetryConfig` in
`apps/mobile/lib/core/telemetry.dart` requires a Sentry DSN in URL form and, for
Rybbit, both the host and the site id. That is the default state for anyone who
builds the client against their own Nextcloud — this is a general multi-server
client, not a white-label application, so a foreign build must not report to us.

| Variable | Meaning | Empty value |
| --- | --- | --- |
| `SENTRY_DSN` | DSN of the self-hosted Sentry | no crash reporting |
| `RYBBIT_HOST` | address of the Rybbit instance | no analytics |
| `RYBBIT_SITE_ID` | site id in Rybbit | no analytics |
| `TELEMETRY_ENVIRONMENT` | distinguishes a test build from production | `development` |
| `TELEMETRY_RELEASE_GATE` | sends an error and a diagnostic probe before a release | `false` |

## What is sent

- **Crashes and errors without content.** The stack trace and the exception type.
  Every text goes through `TelemetryScrubber`: an absolute URL is truncated to
  `scheme://<host>`, so both the server and the room token in `…/call/<token>`
  disappear, and anything in the form `Authorization:`, `Bearer …` or `Basic …`
  is replaced with `<redacted>`. `SentryEvent.request` is dropped entirely.
- **Anonymous screen usage.** Only route names (`/settings`,
  `/conversation/details`, …) from `RouteSettings`. No account id, room token or
  conversation name ever gets into a route name.
- **A random installation id.** 128 bits from `Random.secure()` in the file
  `telemetry_installation_id.txt` next to the other local preferences. It is not
  derived from the account, the server or a device property, so it cannot be
  linked to a person or to which Nextcloud someone uses. It survives a restart,
  not a reinstall.

### Attachment upload diagnostics

Picking and uploading an attachment can end in a pending state without an
exception, so they have their own limited Sentry events. They record only
predefined enums and trimmed values: the boundary of the picker and the durable
copy, the UI and durable phase, whether a durable session already exists, the
progress and time bucket, the attempt count at most as `4+`, information about a
scheduled retry, the lifecycle and the platform.

The picker, the copy, the admission and every durable change add a breadcrumb. A
caught error and a queue that stays in the `queued` phase for 45 seconds create a
warning event with a fixed fingerprint. The event uses a cleaned isolated scope
without a user, inherited breadcrumbs, tags and extras. It never receives an
exception or its text, a file name or path, a source handle or hash, an account,
a room token, a server, a URL, a caption, a message, a credential or a job ID. A
build without a valid `SENTRY_DSN` only calls an inactive SDK hub and sends
nothing.

A temporarily unavailable Apple Keychain is reported as the fixed checkpoint
`credentialUnavailable` with the durable/resume phase, the credential retry
bucket and the scheduled delay. The first occurrence creates an event; further
attempts of the same outage do not flood it. After a successful read the counter
is discarded, and once exhausted the job is durably moved to reauthentication.

### Release gate

`TELEMETRY_RELEASE_GATE=true` is an explicit pre-release mode. After
initialization the SDK sends one fixed `TelemetryReleaseGateError` with the
application stack and one `attachment-upload-releaseGate` event with structured
tags. It is normally off and without the define creates no probe. The launcher
tool `apps/mobile/tool/sentry_release_gate_test.dart` is outside the usual test
discovery.

Rybbit additionally adds the device model, the OS version, the application
version and an approximate location derived from the IP address on its own. None
of that is sent by the client and it cannot be turned off on our side; it is
standard server behaviour.

## What is not sent

`sendDefaultPii`, `attachScreenshot` and performance tracing are all off. Message
contents, conversation names, credentials, the push identity and the server
address are not sent. `Rybbit.init` runs with `autoTrackErrors: false` — errors
belong to Sentry, which scrubs them first, and Rybbit's own handler would
additionally take over `FlutterError.onError` from under the Sentry integration.

Neither SDK may bring down the application start: telemetry is diagnostics, not a
feature the user asked for. A failure of `Rybbit.init` is swallowed and the app
keeps running without analytics.

## Verification

Build 36 from the exact `da84214` verified the whole Sentry flow:

- **Android 14 release:** the error event `ce2cdb8984d641ee9db81dc64dba1baa` and
  the diagnostic `492f9f5cea9d463f9af94e3137dd4ec1` arrived as
  `com.nkshub.nextcloudtalk@0.1.0+36`, `dist=36`, `production`.
- **iOS 18.6 Simulator:** Flutter does not support simulator release mode, so the
  closest installable ad-hoc debug artifact with the same source, production
  telemetry and build number was used. The error
  `9ca434526e00422e9e5372a0910a61b9` and the diagnostic
  `fa615f4dea4447b0bd25fed4fbd2167f` arrived with `attachment.platform=iOS`; the
  diagnostic had no user, request or breadcrumbs.
- Five iOS cold launch/terminate cycles peaked at 671,712 KiB RSS and a 309 MB
  physical footprint; release 36 produced no `WatchdogTermination`.
- After closing the historical and synthetic probe issues, the Sentry query
  `is:unresolved` for the NKS Talk project returns an empty list.

The original verification on the Android emulator against
`com.nkshub.nextcloudtalk`, build `e5f893d` with
`--dart-define-from-file=telemetry.env`:

- **Rybbit verified (L).** The site `com.nkshub.nextcloudtalk` (org NKS Apps)
  accepted `app_open` with `environment=development` and the pageviews `/` →
  `/search/messages` → `/`. There is no token, account id or conversation name in
  the payload. The file `telemetry_installation_id.txt` (32 characters) was
  created in the app's `files/`.
- **Historical limitation of that test.** Both the SDK and sentry-native started
  (`sentry-native: starting backend` in logcat), but no event from the instance
  arrived: at that time the Relay at `sentry.example.invalid` could not load the
  project config (`error fetching project state …: deadline exceeded`) for ~230
  keys, that is for the whole instance. `POST /api/43/store/` returns HTTP 200 and
  yet no issue is created. That is an operational state of the instance, not an
  integration bug — the end-to-end verification is now replaced by the build-36
  evidence above.

Tests:

- `apps/mobile/test/telemetry_test.dart` — the configuration gate, the scrubber
  and the format of the installation id.
- `apps/mobile/test/telemetry_bootstrap_test.dart` — dropping
  `SentryEvent.request` and scrubbing messages, exceptions and breadcrumbs.
- `apps/mobile/test/attachment_upload_telemetry_test.dart` — a fixed event
  without a request, a user, breadcrumbs, an exception and a free-text payload.
- `apps/mobile/test/platform/media/image_attachment_picker_test.dart`,
  `image_attachment_upload_controller_test.dart` and
  `attachment_submission_test.dart` — the picker/copy order, the watchdog before
  and after durable admission and the safe transfer of phase and retry metadata.
