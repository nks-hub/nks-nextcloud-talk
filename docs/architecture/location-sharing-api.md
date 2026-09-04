# Sharing the current location

State as of 1 September 2026. The wire flow matches the Talk server
`f2958bb25be6604240c58a3faf9a2033a30d20e5` and the Android client `5428960`.

The action is only offered behind the capability `geo-location-sharing`, in a
writable room and in the root or a named thread scope. A plain reply branch does
not offer it, because the rich-object endpoint only accepts a named `threadId`.

After an explicit user action the client asks only for the foreground permission,
obtains a single current location with a 15-second limit and shows the
coordinates for confirmation before sending. Background location is not used.

```text
POST /ocs/v2.php/apps/spreed/api/v1/chat/{token}/share
objectType=geo-location
objectId=geo:{latitude},{longitude}
metaData={...}
referenceId={uuid}
threadId={named-thread-id}  # named thread only
```

The request validates finite coordinates within ±90/±180, a bounded name, the
account/server/room/credential/capability binding, and for the named scope also
the cached canonical root. The response must be HTTP/OCS 201 and must return a
message of the same room and thread. 400/413, 401, 403, 404, 429 and 5xx stay
distinguished.

Automated evidence: location contract 5/5, service and permission/fallback 12/12,
composer 4/4, platform metadata and both analyzers with no findings. The flow is
bound to the generation of the original room; changing it before confirmation
cancels the write. A timeout, a network loss, an unreadable 201 and a 5xx after
dispatch are `ambiguous`, not a safely retryable failure. The release APK passed
the license gate with 145 Flutter packages and 111 Android components.

The Android 14 emulator obtained a live foreground GPS fix, showed the exact
coordinates for confirmation, and the server created message 78017. The client
rendered it as a shared location; the screenshot is
`.artifacts/nks-location-live.png` and the PID log after the successful run had
no Flutter or HTTP exception. The test message was then deleted on the server
through the client, and the local authoritative projection confirmed `deleted=1`.
The menu and the confirmation have real light/dark screenshots in `.artifacts`.
The pixel minimum for text is 4.567:1 light and 8.5054:1 dark; the minimum for
icons is 8.4713:1 light and 10.3081:1 dark. The confirm button has 6.4986:1 light
and 9.6541:1 dark. The first attempt ended with a system `DeadSystemException`
together with a crash of Chrome and the Android UI; after a full emulator start
the same flow passed.

The iOS 18.6 build 32 went live through the system foreground dialog, a one-time
permission, the fix `50.087000, 14.421000`, the confirmation and a typed
server-side share. Message 78164 was rendered as a shared location and after
deletion turned into `comment_deleted`. Both the simulated location and the
permission were reset. The runtime revealed an English purpose string inside the
Czech dialog; `2f1d36f` localized it through genuinely bundled
`cs/en InfoPlist.strings`. Simulator build 33 with Sentry and Rybbit showed the
Czech sentence; after obtaining the fix the flow was cancelled before the second
POST and the test state was cleaned up again. A physical Android/iOS location is
still missing. macOS has the required location purpose string, the sandbox
entitlement and a pinned `geolocator_apple` pod; a live desktop flow is not
documented yet.
