# Push gateway contract

Verification date: 23 August 2026.

Product state: a historical, runnably verified variant of Notifications push-v2.
For Android it was replaced by the direct Notifications Web Push flow per
[D-025](decisions-technical.md#d-025-android-over-notifications-web-push) and the
[current push analysis](../research/push-fcm.md). The gateway is neither
implemented nor deployed as a mandatory part of the Android application. The
document remains evidence of historical wire compatibility. A future iOS APNs
relay and the PushKit branch require a separate contract and a new stack
selection; they do not inherit this contract automatically.

Contract state: the gateway wire contract, the client wire contract and the pure
Dart registration and routing runtime are runnably verified. A production
gateway, the datastore, a Firebase project, a platform crypto adapter and runtime
delivery do not exist yet.

## The historical answer of the original push-v2 variant

The original push-v2 variant did not assume a Firebase project for every
Nextcloud server. It assumed one publisher Firebase project and gateway for all
supported servers; that topology no longer drives the Android implementation.

The application reads only the capabilities from the connected Nextcloud. It
downloads no Firebase configuration, no service-account credential and no gateway
URL from the server. A fixed trusted gateway origin is part of the configuration
of the signed application, and the client sends it to the Notifications API v2 as
`proxyServer` during registration. Adding another server therefore requires no
rebuild.

An ordinary Nextcloud administrator needs the standard Notifications app active,
working background jobs and outgoing HTTPS to the gateway. A dedicated Nextcloud
companion app may later add diagnostics and optional server-side features, but it
is not necessary for this push flow and must not create a second notification
engine.

## Authoritative compatibility

The contract is bound to:

- Nextcloud Notifications
  [`f15413203a73eea7a42f454f6310ec5eca2735a0`](https://github.com/nextcloud/notifications/tree/f15413203a73eea7a42f454f6310ec5eca2735a0);
- the server-side push-v2 description and `Push::sendNotificationsToProxies()`
  from the same SHA;
- Nextcloud server
  [`d7c20b71e219461ff0c677b3846b9d1d723ff17f`](https://github.com/nextcloud/server/tree/d7c20b71e219461ff0c677b3846b9d1d723ff17f),
  in particular the conversion of the `body` array into URL-encoded `form_params`
  and the public identity-proof endpoint;
- Talk Android
  [`5428960f9d1eca708df1b39a0831141dcbba4729`](https://github.com/nextcloud/talk-android/tree/5428960f9d1eca708df1b39a0831141dcbba4729),
  `NcApi.java` and `PushUtils.kt`;
- Talk iOS
  [`2d31eda5e2acbf3cef27aa289376942bdf0de25d`](https://github.com/nextcloud/talk-ios/tree/2d31eda5e2acbf3cef27aa289376942bdf0de25d),
  `NCAPIController.swift`.

The OpenAPI 3.1 is in
[`contracts/push-gateway/openapi.json`](../../contracts/push-gateway/openapi.json).
The client OCS/envelope boundary is in
[`contracts/push-client`](../../contracts/push-client/README.md).

## The real wire format

<!-- markdownlint-disable MD013 -->

| Operation | Primary format | Reason |
| --- | --- | --- |
| `POST /devices` | `application/x-www-form-urlencoded` | The official Android uses Retrofit `@FormUrlEncoded`; iOS uses a form serializer |
| `DELETE /devices` | The full triple in the query; a form body is accepted too | Android uses `@QueryMap`, iOS sends DELETE parameters; the push-v2 document shows a body |
| `POST /notifications` | URL-encoded `notifications[0]`, `notifications[1]`, … | Nextcloud passes an array of JSON strings through an HTTP client that converts the `body` array into `form_params` |
| `/notifications` response | JSON `unknown` + an integer `failed` | `Push::handleProxyResponse()` removes unknown registrations and reports a partial error based on these two keys |

<!-- markdownlint-enable MD013 -->

A JSON-only `/devices` or `/notifications` would look cleaner, but would not be
compatible with the real clients and the Nextcloud server. Every
`notifications[N]` item is a separate JSON string with the fields
`deviceIdentifier`, `pushTokenHash`, `subject`, `signature`, `priority` and
`type`.

## The meaning of the responses

`POST /devices` verifies the RSA/SHA-512 signature and writes the registration
idempotently. Success returns `200` with an empty body, because that is exactly
what the current clients expect.

The server first signs a private JSON preimage using SHA-512 and then publishes
`deviceIdentifier` as the Base64 SHA-512 digest of the same preimage. The gateway
does not know the preimage, so it verifies the signature against the
Base64-decoded digest in prehashed mode. Hashing `deviceIdentifier` with SHA-512
a second time would wrongly reject a valid registration. By contrast, the
signature of the notification `subject` is verified as an ordinary SHA-512
signature over the decoded ciphertext.

`DELETE /devices` removes only the exact cryptographic identity. The same
physical FCM token may stay bound to a different accountId. If both the query and
the body are present, they must be identical; otherwise the gateway returns
`400`.

`POST /notifications` classifies every item separately:

- an unknown deviceIdentifier is added to `unknown` and does not increase
  `failed`;
- a wrong token hash, signature or format, or a failed durable enqueue increases
  `failed`;
- a valid item is written into the durable queue before the response;
- a partial error still returns `200` with exact counts.

The gateway never decrypts `subject`. It verifies the signature of the ciphertext
and that the SHA-512 of the stored token matches `pushTokenHash`; the plaintext
is only filled in by the phone after decryption and the subsequent OCS catch-up.

## Conflict 409 and cloudId

The same provider token commonly appears on several accounts of one
installation. The gateway must therefore not overwrite or delete the first
account on a conflict. It returns `409`; the client may repeat the registration
with `cloudId`.

For an HTTPS server, Nextcloud's `IUser::getCloudId()` usually returns the form
`userid@host[/subpath]` without a scheme. The gateway uses an equivalent of the
exact Nextcloud parser, fills in a missing scheme only as HTTPS and rejects an
explicit HTTP. A username may contain `@`, so a plain split at the first at-sign
is not correct.

After a safe split the gateway loads the public endpoint
`/ocs/v2.php/identityproof/key/{url-encoded-user-id}` without credentials and
compares the returned public key. The remote part is an SSRF boundary:

- HTTPS only, without userinfo and without a fragment;
- no loopback, private, link-local, reserved or IPv4-mapped IPv6 target;
- an A/AAAA check both before the request and at connection time;
- no redirects;
- a short timeout and a limited body and content type;
- no app password, FCM token or internal header in the request.

A LAN-only server therefore may not be able to complete the 409 recovery on a
public gateway. An own internal gateway may allow it only through an explicit
egress policy.

## Runnable fixtures

The fixtures contain a synthetic public RSA key, valid signatures, a
registration, an unregistration, a negative request, a 409 problem response and a
full as well as a partially failing batch. They contain no private key, no real
FCM token and no user data.

Verification from the repository root:

```powershell
python contracts\push-gateway\validate_contract.py
```

The validator performs:

1. OpenAPI 3.1 validation.
2. Draft 2020-12 validation of all positive and negative fixtures.
3. A real form/query/indexed-form encode-decode round trip.
4. RSA-2048/SHA-512 verification of the registration and notification signatures.
5. A SHA-512 token-hash check and deterministic classification of a partial
   batch.

The current result: 1 OpenAPI document, 10 fixtures, 3 registration signatures,
4 notification envelopes and 2 batch scenarios passed.

## The client contract and the pure Dart runtime

The separate [`push-client` contract](../../contracts/push-client/README.md)
contains 1 OpenAPI document and 8 fixtures: the OCS request/response, the mobile
envelope, a normal wake-up, three silent-delete variants and one invalid
ambiguous payload. On every run the Python validator generates RSA-2048 keys in
memory only and really verifies SHA512withRSA, OAEP SHA-1/MGF1 SHA-1 as well as
PKCS#1 v1.5. The generated envelopes pass `MobilePushEnvelope` directly; the
stored wire fixture is not presented as encrypt/decrypt evidence. The Dart
contract test loads the same manifest and fixtures directly.

`packages/talk_protocol/lib/src/push` implements one provider token for several
accounts, a separate key handle for every `accountId`, a deterministic
single-flight registration queue, an exact retry from the failed phase, 409
recovery and exactly-one decrypt routing. Disabling the capability preserves the
account key. Logout performs the Nextcloud unregister, the gateway unregister and
only then destroys the key handle; a transient cleanup stays as a retryable
revocation tombstone. An old effect after a token or authority rotation cannot
commit new state or route a push through; the crypto completion is re-bound to
the current account snapshot.

The client slice passes 42 Dart tests: 20 contract, 13 runtime, 8 security and 1
real release AOT test. After it was added, the whole of `talk_protocol` passes
527 tests.

## What this evidence still does not cover

The contract does not prove datastore concurrency, a real cloudId request, FCM
HTTP v1, the retry queue, invalid-token cleanup, rate limiting or delivery to a
device. Those pieces of evidence would be mandatory for the original push-v2
gateway, which will not be implemented for Android. The OpenAPI and the fixtures
are historical wire evidence, not an active runtime gate. A future iOS
APNs/PushKit relay must have its own contract and verification.
