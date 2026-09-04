# Nextcloud account addition contract

Verification date: 25 August 2026.

State: the OpenAPI, the synthetic fixtures, the security scenarios, the pure Dart
parser and a read-only live smoke test are runnably verified. The Flutter layer
now implements the HTTP/UI onboarding, the system browser, Login Flow v2, secure
storage and the atomic creation of an account-scoped Drift record. The current
Android APK completed a real Login Flow v2 including a second factor and access
approval, loaded the signed-in capabilities and preserved the account in secure
storage across a process restart.

## Scope

The contract describes the first client slice:

1. normalization of the server entered by the user;
2. the public `status.php`;
3. browser-mediated Login Flow v2;
4. anonymous and subsequently signed-in OCS capabilities;
5. the safe creation of a local `accountId`.

This is not a new server endpoint. The OpenAPI captures existing Nextcloud wire
behaviour, while the validator adds the client trust invariants that JSON Schema
alone cannot express.

Authoritative sources:

- Nextcloud server
  [`d7c20b71e219461ff0c677b3846b9d1d723ff17f`](https://github.com/nextcloud/server/tree/d7c20b71e219461ff0c677b3846b9d1d723ff17f),
  in particular `status.php`, `ClientFlowLoginV2Controller.php`,
  `LoginFlowV2Service.php` and `OCSController.php`;
- Talk Android
  [`5428960f9d1eca708df1b39a0831141dcbba4729`](https://github.com/nextcloud/talk-android/tree/5428960f9d1eca708df1b39a0831141dcbba4729),
  in particular `NetworkLoginDataSource.kt` and the login response models;
- the runtime baseline of the reference instance from 22 August 2026; the
  repeatable smoke test loads only the status and the anonymous capabilities,
  while the one-off verification of init created only an expirable, unfinished
  Login Flow.

The OpenAPI 3.1 is in
[`contracts/client-bootstrap/openapi.json`](../../contracts/client-bootstrap/openapi.json).

## Server normalization

The output of the normalization is a canonical server base URL, not an arbitrary
web URL. A legitimate Nextcloud subpath, for example `/nextcloud`, is preserved.

<!-- markdownlint-disable MD013 -->

| Input | Result |
| --- | --- |
| `cloud.example.invalid` | `https://cloud.example.invalid` |
| `HTTPS://Cloud.Example.Invalid/nextcloud/` | `https://cloud.example.invalid/nextcloud` |
| `https://cloud.example.invalid:443` | `https://cloud.example.invalid` |
| HTTP | Only under an explicit debug policy; production rejects it |
| Userinfo, a query, a fragment or a backslash | Reject |
| A control character, a dot segment, an encoded or a double path separator | Reject |
| An invalid port, a trailing-dot host or a non-canonical IPv4 | Reject |

<!-- markdownlint-enable MD013 -->

The reference validator uses deliberately conservative subpath segments.
Extending it with further legitimate encodings requires a new positive as well as
collision fixture; it must not appear through a silent `decode` and a
reassembly of the URL.

## Server readiness

`GET /status.php` is public and requires no credentials. The client does not
continue if at least one of these holds:

- `installed` is `false`;
- `maintenance` is `true`;
- `needsDbUpgrade` is `true`.

`version` and `versionstring` serve diagnostics only. Which features are enabled
is decided by the capabilities after login.

## Login Flow v2

Initialization is an empty `application/x-www-form-urlencoded` POST to
`/index.php/login/v2`. A stable `User-Agent` carries a human name and the product
version, because an administrator may restrict Login Flow by a user-agent policy.

The response returns two independent opaque tokens:

- `login` is the URL opened in the system browser;
- `poll.token` is sent as a form-urlencoded `token` to `poll.endpoint`.

Before opening the browser or sending the poll token, the client verifies:

- the same origin as the verified server; in production always HTTPS;
- the same Nextcloud base path;
- the exact poll path `/index.php/login/v2/poll`, or `/login/v2/poll` on a server
  with pretty URLs (`htaccess.RewriteBase`, the default in the official Docker
  image) — both endpoints must use the same form;
- the login path `/index.php/login/v2/flow/{opaque-token}` (or
  `/login/v2/flow/{opaque-token}`);
- no userinfo, query, fragment, control character or encoded path escapes.

A cross-origin login URL is never opened and a cross-origin poll endpoint never
receives a token. The same applies to a URL on the same host that escaped from
the verified subpath. An explicit debug HTTP policy has to be passed through the
whole flow; it must not enable only the first normalization and then change the
trust rules for Login Flow or the credentials.

An unfinished poll returns HTTP 404 and the JSON `[]`. The same result also means
an invalid, expired or already consumed token. The client therefore must not
interpret it as a certain "the user is still waiting". It responds with bounded
polling, the state of the browser flow and a new initialization after the local
time window ends.

A successful poll returns `server`, `loginName` and `appPassword` exactly once.
The server implementation in the SHA above generates 128-character login/poll
tokens and a 72-character app password, and the record expires after 1200
seconds. The client treats them as opaque values and does not rely on a specific
length beyond the security limits.

## Credential commit and accountId

The `server` field of a successful response is normalized again and must be
identical to the originally verified base URL. A change of the origin or the
subpath invalidates the whole result.

After validation the client:

1. creates a new random local UUID `accountId`;
2. stores the app password under an account-scoped key directly in the Keystore
   or the Keychain;
3. in a database transaction stores the account, a reference to the
   secure-storage item and the state `capabilitiesPending`;
4. loads the capabilities with the new credentials and, in another transaction,
   stores the account-scoped snapshot and switches the account into the ready
   state;
5. on a failure of the first DB commit deletes the new secure-storage item, or
   creates a bounded local cleanup tombstone.

The app password is never written into the ordinary database, into an output
fixture or into a log. When the first local commit fails after the poll response
was consumed, the credentials cannot be obtained a second time; the client safely
cleans up the local secret and requests a new Login Flow. A network error during
the subsequent capability request, by contrast, leaves the secured account in the
visible `capabilitiesPending` state and the request can be safely retried without
a new login.

## Two capability phases

`GET /ocs/v2.php/cloud/capabilities?format=json` uses the header
`OCS-APIRequest: true`.

The anonymous response is suitable only for onboarding and basic diagnostics. On
the reference instance it contained 5 namespaces and 105 Spreed features, but the
Notifications namespace, for example, was missing and the account-dependent
attachment state was not authoritative.

After obtaining the app password the client repeats the endpoint with Basic auth.
Only this response is an account-scoped capability snapshot. The reference
response had 26 namespaces and the Notifications `push` features `devices`,
`object-data` and `delete`. Unknown namespaces and fields are safely preserved or
ignored; deserialization must not fail because of a new server capability.

The snapshot belongs exclusively to the specific `accountId`. The anonymous and
the signed-in response must not be shared and must not overwrite a global cache.

## Runnable verification

Local validation from the repository root:

```powershell
rtk proxy python contracts\client-bootstrap\validate_contract.py
```

The read-only live smoke test:

```powershell
rtk proxy python contracts\client-bootstrap\validate_contract.py `
  --live-origin <NEXTCLOUD_ORIGIN>
```

The validator performs:

1. OpenAPI 3.1 validation.
2. A Draft 2020-12 check of the positive as well as negative fixtures.
3. A real form encode/decode round trip.
4. Twenty-two origin normalization scenarios.
5. Root, subpath, debug HTTP, both cross-origin directions and separate
   login/poll base-path-escape scenarios.
6. A match of the credential server including the subpath and a
   synthetic-secret scan.
7. Separate classification of anonymous and account capabilities.
8. Manifest completeness and a ban on an unlisted fixture.

The current result: 1 OpenAPI document, 22 fixtures, 22 origin cases, 2 status
classifications, 9 login trust scenarios, 5 credential scenarios and 2 capability
snapshots passed. The live smoke test additionally confirmed 5 anonymous
namespaces and 105 Talk features without writing anything to the server.

The same 22 fixtures and 22 origin cases are now loaded by the tests of the
production pure Dart package [`talk_protocol`](../../packages/talk_protocol). The
implementation additionally verifies the IDN/Punycode host, subpath-aware
endpoints, redacted exceptions, a duplicate feature and a ban on guessing the
meaning of an unknown poll HTTP status.

Verification from the `packages/talk_protocol` directory:

```powershell
dart analyze --fatal-infos
dart test
```

On Flutter 3.44.4 and Dart 3.12.2 the static analysis passed with no findings and
all 54 Dart tests passed. One builds and runs a release executable, another runs
the VM with the profile compile-time flag; both prove that not even the debug
policy choice allows HTTP. Further tests limit unknown capability JSON to 64
levels and 10,000 nodes. The runtime dependency `punycoder` is pinned by the
lockfile and its MIT license is recorded in the
[dependency audit](dependency-licenses.md).

## What the evidence still does not cover

The Flutter slice and its tests already cover the HTTP transport, the system
browser, account-scoped secure storage and the transactional creation of an
account. The debug APK from commit `5f6e2f4` has SHA-256
`0d38d4ab2a665883d0ee0de7426f201c107cefc6b5f7e701b1c856255f6195cf`.
On 25 August 2026 it was update-installed on `emulator-5554`; the hash of the
installed `base.apk` is identical. A real Login Flow v2, the second factor,
access approval, the signed-in conversation list and opening a room all passed.
The account survived another `adb install -r` as well as terminating and starting
the process again.

Remote revocation of the app password, two real servers in one installation, a
complete clean-install/upgrade matrix, platform crash-log redaction and a
signed-in runtime on iOS/macOS/Linux are still not documented. The current record
is in the [Flutter application foundation](flutter-foundation.md).
