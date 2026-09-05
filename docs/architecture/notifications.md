# Notifications

The application runs on Android, iOS, Windows and macOS, and on each of those
platforms it delivers notifications by a different route. This document describes
which route, why that one, and above all what is fixed by the platform and cannot
be worked around.

## Three channels, not one

| channel | platform | wakes a closed app | what it needs |
| --- | --- | --- | --- |
| push v2 through our own proxy | Android, iOS, macOS | yes | the proxy and a token from FCM/APNs |
| Web Push through UnifiedPush | Android | yes | VAPID on the server |
| Nextcloud Client Push (`notify_push`) | all | no | `notify_push` on the server |

On Android two paths exist at the same time and the user switches between them in
Settings → Push notifications, without a new build. The default is the proxy, Web
Push remains a fallback. Details below in "Two paths on Android".

They are not alternatives to choose between: they complement each other. The live
channel delivers immediately for as long as the application is running, and it
does so everywhere. Waking a terminated application is only possible with Web
Push on Android and APNs on Apple devices.

## Web Push (Android)

Registration goes to `/ocs/v2.php/apps/notifications/api/v2/webpush`, the newer
endpoint of the notifications app without an intermediary. The client fetches the
VAPID public key and creates a subscription; delivery is handled by UnifiedPush
with a distributor bundled inside the application, so the user installs nothing
else. The encrypted content is unpacked by the native layer.

Where that message really flows, though, has to be said exactly, because a
bundled distributor is not the same thing as a direct connection. The library
`org.unifiedpush.android:embedded-fcm-distributor` does not use the Firebase SDK
and needs no `google-services.json`; it talks to Google Play Services through the
old C2DM broadcasts (`com.google.android.c2dm.intent.RECEIVE`). As the
subscription endpoint it registers
`https://fcm.distributor.unifiedpush.org/wpfcm`, a public rewriting gateway of
the UnifiedPush project which converts a Web Push request into an FCM message.
Two foreign infrastructures therefore stand in the path, UnifiedPush and Google.
The content is unreadable to both — the Web Push payload is encrypted with
`aes128gcm` using keys from the subscription, which the gateway does not have —
but the metadata (time, target device, frequency) are visible to them. Anyone who
does not want that has to build their own gateway or reach for a separate
distributor.

It can wake a terminated application, because the message is delivered by a
broadcast and the transport is held by Play Services, not by our application. It
has three limits, though:

- **Force stop** (Settings → Force stop, aggressive OEM battery managers on
  Xiaomi, Huawei or Samsung) puts the application into the "stopped state" and
  Android delivers it no broadcasts until the user launches it themselves. A
  platform rule, and it applies to the official Talk with FCM too.
- **Without Google Play Services** the bundled distributor does not work —
  `AndroidWebPushChannel.ensureEmbeddedDistributor()` throws
  `embedded_distributor_unavailable`. On GrapheneOS without sandboxed Play, on
  Huawei or /e/OS a separate distributor (ntfy) is necessary.
- **Doze** defers normal-priority messages into a maintenance window. The high
  priority that `Push::getNotifTopicAndUrgency` sets for calls and mentions goes
  through it immediately.

On iOS this route cannot be used: Web Push does not exist in a native app and
UnifiedPush is Android-only, because iOS does not allow holding a connection in
the background.

## Two paths on Android and the switch between them

The native path on Android is our own proxy, that is exactly the contract iOS
uses: `POST /ocs/v2.php/apps/notifications/api/v2/push` with
`proxyServer: <the build's PUSH_GATEWAY_ORIGIN>` and then registration with the
proxy at `/devices`. The server side does not change at all — `Push.php` does not
distinguish platforms, it groups by the `proxyserver` column, and the decision of
whether to send a notification to APNs or to FCM is made only by the proxy,
according to the format of the token. That removes
`fcm.distributor.unifiedpush.org` from the path.

The Web Push branch is not deleted. It stays as a fallback behind a switch, in
case the proxy path causes trouble.

The code is therefore split like this:

| file | what it does |
| --- | --- |
| `push_registration_coordinator.dart` | the platform-neutral loop over the `talk_protocol` push-v2 state machine |
| `android_push_device_key_store.dart` + `AndroidPushDeviceKeyStore.kt` | the RSA-2048 device key in the Android Keystore, one per account |
| `android_push_coordinator.dart` | the existing Web Push path, unchanged apart from `revokeAllRegistrations()` |
| `android_push_transport.dart` | choosing the path, storing it and switching cleanly |

The switch is a file in the application directory, the same mechanism as the
theme choice, so it changes at runtime without a new build. The order during a
switch is the important part: Nextcloud keys the registration by device, not by
path, so **the old path is unregistered first** with both Nextcloud and its own
gateway, and only then is the new choice stored. If the unregistration fails, the
choice does not change and the user sees it; the device then stays registered the
old way instead of ending up registered nowhere.

The device key is per account: the handle is the SHA-256 of the `accountId` and
the push state machine rejects a key already held by another account, so one
account can never decrypt a notification belonging to another.

On Android the notification is produced **exclusively by the native layer** from
the push transport. The application has no local notification package and no
notification is ever posted from Dart; Client Push over the websocket only
triggers a synchronization. A running application therefore cannot receive the
same event visibly twice, even when it arrives both over the websocket and from
FCM — there is no second source that would display it. A repeated delivery of the
same message does not create a second notification: the platform ID is stable per
`(accountId, nid)`, so the first one is overwritten.

An undecryptable message is discarded without a trace — nothing is shown, nothing
is written anywhere and nothing is counted. Which key fitted is in itself
information about whom the message belongs to, and a message no key opens belongs
to an account that is no longer on the device.

### Delivery

`NksFirebaseMessagingService` receives a `data`-only message from the proxy with
a single key `nc-subject`, which is the base64 of the RSA ciphertext exactly as
Nextcloud produced it. It decrypts it with the private key from the Android
Keystore (RSA, PKCS#1 v1.5 — Nextcloud has that default in its appconfig) and
passes the result into the **same** `AndroidWebPushPayloadParser` and
`AndroidSystemNotifications.apply` that Web Push uses. A second display layer
therefore does not exist.

Which account receives the message is determined by which key opens it — there is
one token per device, and the keys are per account. The list of signed-in
accounts is sent to the native side by Dart (`setAccounts`), because a delivery
may wake a dead process.

A live pass on 27 August 2026 on Android 14 proved the whole primary chain
Nextcloud → our own proxy → FCM → terminated process. The package was not in the
force-stop state, but the process was not running. The notification showed the
real content, the tap opened the correct account and room, Reply created exactly
one server-side message and Mark as read moved the server read marker. Web Push
was then verified separately as a working fallback, including switching in both
directions.

Commit `18bb4f0` closes the error states of the handover between transports: the
choice is loaded before the coordinator starts, concurrent switches are
serialized, and a failed write of the new choice restores the already
unregistered original path. After a failed switch the user is therefore not left
without a registration.

### When a notification arrives immediately and when it does not

In Nextcloud, Talk always has high urgency, even an ordinary message —
`Push.php` sets `urgency = high` for `spreed`, `talk` and
`admin_notification_talk`. The proxy maps that one to one onto
`android.priority: high`.

MEASURED 2026-08-27 on `chatujmePixel` (Android 14) through
`RemoteMessage.getOriginalPriority()` and `getPriority()`, with temporary
instrumentation that did not stay in the tree. Both returned `1`, that is
`PRIORITY_HIGH`, and they did so even in a state that was expected to lower the
priority: the app removed from the battery optimization exceptions, the standby
bucket `RESTRICTED` (45) and the device in the `deviceidle` state `IDLE`. The
message arrived 471 ms after `sentTime`. **The whole chain therefore carries the
high priority correctly and Android does not lower it even in deep power saving
mode**; App Standby Buckets are ruled out as an explanation.

The delay we did observe had a different cause: on the emulator the Play Services
connection goes stale after a longer period of inactivity and messages pile up
until something wakes it. Nothing is lost in the process — once the connection
was restored, all the deferred messages arrived too. The proxy log confirmed it
from the other side: six sends, six `200 OK` from Google.

The practical consequence: **do not look for a report of "notifications arrive
late" in our code.** The priority is correct from Nextcloud all the way to
`getPriority()` on the device. Before testing push on an emulator, pull it out of
power saving mode (`adb shell cmd deviceidle unforce`, or whitelist the package),
otherwise you are measuring Google's scheduler, not our path. A physical device
does not behave this way.

## Client Push (`notify_push`) — all platforms

The live channel designed by Nextcloud. The server advertises it in capabilities:

```
notify_push.type      → ["files", "activities", "notifications"]
notify_push.endpoints → { websocket: "wss://…/push/ws", pre_auth: "https://…" }
```

That it sends notifications too, not only file changes, follows from
`apps/notify_push/lib/Listener.php` implementing `INotifier` and calling
`$this->queue->push('notify_notification', …)`.

The client procedure:

1. `POST` to `pre_auth` over authenticated HTTPS → a one-time token. **The route
   is POST**; the server rejects a `GET` with `405` and the socket then never
   gets a token. In that case the channel silently fails to connect and the
   application looks normal — which is why a test guards it.
2. Connect `wss://…/push/ws`, send an **empty user name** and then that token.
   The app password never travels over the socket.
3. The server answers `authenticated` and then sends frames.
   `notify_notification` means "something arrived, synchronize".

Implementation: the protocol in `packages/talk_protocol/lib/src/client_push/`,
the connection and coordination in
`apps/mobile/lib/features/push/client_push_*.dart`. The endpoint from the
capabilities must belong to the same host as the account, otherwise the token is
not sent anywhere; `ws` without TLS is rejected and frames delivered before the
token is accepted are discarded.

Verifying that the channel is really running is done from the server, not from
the application log:

```sh
occ notify_push:metrics   # Active connection count / Active user count
```

## APNs (iOS, macOS) and why a proxy is needed for it

This is the part that surprises people, so it is described in detail.

Nextcloud **cannot talk to APNs**. There is not a single mention of Apple in
`apps/notifications/lib/Push.php`; the server only groups notifications by the
`proxyserver` column and does a `POST <proxyServer>/notifications`. Delivery to
APNs is handled by that address.

The official Nextcloud Talk app for iOS therefore points at
`https://push-notifications.nextcloud.com` — a service operated by Nextcloud GmbH
which signs the notification with **their** Apple certificate for **their**
bundle id. The documentation `nextcloud/notifications/docs/push-v2.md` says so
directly: the keys and certificates cannot be part of the server, otherwise
everyone would have them; the proxy verifies the notification with the user's
public key and then "signs with Google or Apple Developer certificate".

From that follows what applies to us as well:

- The proxy **is not part of a self-hosted Nextcloud**. Your server only sends an
  outgoing request to it.
- A notification never reaches an application with a different bundle id through
  it, because Nextcloud cannot sign it with their certificate.
- The address is chosen by the **client** at device registration, not by the
  administrator. `PushController::registerDevice` accepts the parameter
  `proxyServer` and only validates it (a valid URL up to 256 characters,
  `https://`, and for testing also `localhost` and `*.internal` / `*.local`). It
  is configured nowhere in the Nextcloud UI — the admin notifications section
  only exposes `setting_batchtime`.

Our client therefore sends its own address; the field is in
`packages/talk_protocol/lib/src/push/effects.dart`:

```dart
Map<String, String> get formFields => <String, String>{
  'pushTokenHash': providerToken.sha512,
  'devicePublicKey': key.publicKey.pem,
  'proxyServer': context.gateway.value,
};
```

What the server sends to that address:

```
POST <proxyServer>/notifications
{"notifications": [{deviceIdentifier, pushTokenHash, subject,
                    signature, priority, type}, …]}
```

`subject` is the payload encrypted with the device public key. The proxy **does
not and cannot decrypt it** — it is unpacked only by the Notification Service
Extension inside the phone. `pushTokenHash` is the SHA-512 of the real push
token, so the proxy needs its own registration in which the client stores the
pair hash → token.

The registration with the proxy additionally carries an explicit
`pushProvider=apns|fcm`. The provider is stored with the device and the proxy
chooses the sending branch by it; the shape of the token is not authoritative. An
APNs registration must also carry `pushEnvironment=development|production`, while
FCM rejects that value. A debug Apple build uses development, Profile and Release
use production. The proxy holds both APNs clients at once and picks the endpoint
per device, so concurrent simulator and TestFlight traffic do not erase each
other's valid registrations.

On the Apple side this is what is needed:

| item | value |
| --- | --- |
| Team | `<team-id>` |
| App ID | `com.nkshub.nextcloudtalk` with the Push Notifications capability |
| Extension App ID | `com.nkshub.nextcloudtalk.NotificationService` |
| App Group | `group.com.nkshub.nextcloudtalk` |
| APNs key | token-based `.p8`, both Sandbox and Production |

The extension has its own App ID and, through the App Group, reaches the private
key it uses to decrypt the notification. Certificates are not needed, the `.p8`
replaces them and does not expire.

Just as on Android (above), here too only one source is able to display a
notification: `pubspec.yaml` contains no local notification package and Dart
calls nothing anywhere that would produce a notification — Client Push over the
websocket only starts `ConversationSyncService.sync`. The banner on the screen
comes exclusively from what the Notification Service Extension builds out of the
APNs payload. A running application therefore cannot receive the same message
visibly twice, even if Client Push and APNs announced it practically
simultaneously — there is no second display source, so there is nothing to
deduplicate.

### Implementation state: iOS finished and verified live through our own proxy

DONE AND VERIFIED in `d75d0b8` (built through `flutter run` + `xcodebuild test`,
not just `analyze`), state as of 2026-08-27/28:

- The Notification Service Extension as its own Xcode target (two real
  build-blocking bugs in the hand-written `project.pbxproj` found and fixed by an
  actual build, not by reading — a missing
  `XCBuildConfiguration`/`XCConfigurationList` and a missing
  `PBXSourcesBuildPhase` object).
- Decryption of `nc-subject` (`PushEnvelopeDecryptor`, PKCS#1 v1.5 first,
  OAEP-SHA1 as Nextcloud's only alternative); the ciphertext is rejected if it is
  not exactly 256 B (the RSA-2048 modulus) — the check happens before the first
  `SecKeyCreateDecryptedData`, not after it. The payload must carry `app` as a
  non-empty string, "it is a JSON object" alone is not enough.
- Rewriting the title/body and `content.categoryIdentifier` for Reply/Mark as
  Read. The title is identical to Android: `app == "spreed"` → the localized
  application name, otherwise the raw `app` id — switching between devices must
  not show a different text for the same message.
- Both the tap and the notification actions carry the account **directly from the
  decrypting key** (the Keychain label,
  `PushDeviceKeyStore.setAccount`/`allKeys()`), not reconstructed from the server
  host. An independent audit (Codex) flagged this as a serious finding: two
  accounts on the same server could otherwise send a tap or a reply from a
  notification under a foreign identity. `ApplePushNotificationOpenDelivery`
  carries `{accountId, roomToken}` in the same queue shape as
  `AppleDeepLinkDelivery`, but it is a separate mechanism — it mirrors the
  Android `AndroidNotificationOpen`, which also does not go through the deep-link
  resolver.
- `ApplePushRegistrationCoordinator.dispose()` waits for an in-progress `_drain()`
  before closing the gateway client — previously it could interrupt an in-flight
  register/unregister and leave the device registered only with Nextcloud, or
  only with the proxy. Verified the other way round too: without the fix, the
  test fails exactly on "dispose must wait for the in-flight drain".
- Foreground dedup of Client Push vs. APNs was built and then **removed** — it
  was verified (by grep) that a second display source does not exist at all (see
  the paragraph above), so there was nothing to deduplicate.

The live APNs development pass through our own proxy proved delivery with the
process terminated, decryption in the Notification Service Extension and a cold
Open into the correct account and room. Reply created exactly one message under
the account determined by the decrypting key, and Mark as read moved the server
marker. The account is never looked up by the host. The pod-wired iOS XCTest
ended with `TEST SUCCEEDED`.

### Implementation state: macOS production verified

The signed Universal Release of 28 August 2026 registered through our own proxy
as `apns/production`. With the process terminated, the whole flow Nextcloud →
proxy → APNs production → macOS Notification Service Extension passed. The NSE
decrypted the content and the system displayed a real NKS Talk card. The cold
Open opened the correct account and room, Reply created exactly one server-side
message under the recipient, and Mark as Read ended with
`lastReadMessage == lastMessage.id` and a zero unread count. Commits `9d8e7ac`
and `5f8ee50` additionally guard that the NSE does not link the Runner pods and
that it declares the macOS `NSExtensionService_Subsystem`.

## Windows: a running application yes, a closed one no

On Windows the notification is shown by the application itself, for as long as it
is running. Client Push triggers a synchronization and a new Talk message is
displayed as a WinRT `ToastGeneric`. The notification offers explicit Open, Reply
and Mark as read actions.

**The current unpackaged build cannot wake a terminated process.** Such delivery
requires the Windows Notification Service, a packaged identity from the Microsoft
Store and an out-of-process COM activator. As long as we distribute the
application outside the Store, a running process is a deliberate platform
boundary, not a feature falsely presented as done.

The toast XML contains neither the `accountId` nor the room token. For every
notification the native layer creates a random opaque GUID and holds a bounded
map of at most 64 routes. The activation hands Dart only the corresponding
`{accountId, roomToken}`; the tap queue in Dart holds at most 32 items. A Reply
is enqueued into the same durable outbox as a reply from the application, and
Mark as read uses the same account-scoped read service. Two accounts on the same
server are therefore not distinguished by the host.

The content is never fetched again. It is composed of the rows the
synchronization has already written and which the conversation list renders, and
the trigger is a rise in the unread count. The first load is merely remembered:
otherwise every start would fire a batch of notifications for everything long
unread. The Talk filter is satisfied by construction — `cachedConversations`
contains Talk conversations only, and a card from Deck never gets into that
table.

A live pass on Windows 11 on top of commits `ef80b04` and `ea63609` proved the
release build, delivery into the Notification Center, one server-side message
after Reply, a server-side `unreadMessages=0` after Mark as read and an explicit
Open into the correct account and room. The focused Windows suite passed 12/12,
the integration tests 2/2 and `flutter analyze` had no findings.

## Only Talk, nothing else

Nextcloud sends notifications of **all** applications to a registered device, not
only Talk's, so a card from Deck arrives on the same channel as a message. The
`app` field in the payload is therefore a gate: only `spreed` is displayed. A
payload without `app` is not considered Talk — nothing is guessed.

## VoIP push and why it is not here yet

On iOS, calls need a second, separate channel: PushKit with a VoIP token. Apple
enforces that every delivered VoIP push must end with a call to
`reportNewIncomingCall`, otherwise the system kills the application — so that
channel cannot be used for ordinary notifications, and vice versa.

Upstream solves it in a way worth knowing before this starts to be built: the iOS
client sends the proxy **one string with two tokens separated by a space**,
`"<ordinary hex> <voip hex>"`, and computes the `pushTokenHash` for Nextcloud as
the SHA-512 of exactly that joined form (`NCKeyChainController.m`). Our proxy does
not accept that form today: `token_kind()` only recognizes pure hex or base64url
and a space passes neither mask, so the registration would end with
`INVALID_PUSH_TOKEN`. On top of that, the proxy database has a single
`push_token` column, so even if it passed, there is nowhere to store the VoIP
token.

The mapping of `type: "voip"` onto a topic with the `.voip` suffix is already
done in the proxy, so only that identity and schema are missing. On the Apple
side this will additionally require the VoIP entitlement, which is not in the
table above.

We are not bound by the upstream shape — both the proxy and the client are ours,
so the pair of tokens can go in two fields instead of one string with a space.
That will be decided when calls are being built; until then this is only a
recorded finding, not a plan.
