# Shared items

State as of 31 August 2026. The wire behaviour is verified against the Nextcloud
Talk server `f2958bb25be6604240c58a3faf9a2033a30d20e5` and by a read-only run
against the reference instance. The Flutter slice is server-authoritative; the
local message cache does not decide which categories or items exist.

## Capability gates

- The entry point only appears with the Talk capability
  `rich-object-list-media`.
- A federated room additionally requires `federated-shared-items`.
- The gate in the detail view uses the account-scoped capability snapshot. Before
  the request the service re-verifies the current authenticated capabilities and
  the room token.
- A missing account, credential or conversation, or invalid room JSON, fails
  closed.

## Endpoints

An overview of the available categories:

```text
GET /ocs/v2.php/apps/spreed/api/v1/chat/{token}/share/overview
    ?format=json&limit=7
```

One page of a single category:

```text
GET /ocs/v2.php/apps/spreed/api/v1/chat/{token}/share
    ?format=json
    &objectType={type}
    &lastKnownMessageId={cursor}
    &limit=28
```

The supported wire types are `audio`, `deckcard`, `file`, `location`, `media`,
`other`, `pinned`, `poll`, `recording` and `voice`. An unknown future category is
safely ignored in the overview; a known category is never inferred from the
contents of the local cache.

## Response validation

- The transport accepts only 200, 401, 404, 412, 429 and 503, and the body is
  limited to 8 MiB.
- 401 means a new login, 404 a missing room, 412 waiting in the lobby, 429 a rate
  limit and 503 a temporarily unavailable service. Error statuses do not require
  a JSON body.
- OCS success requires both `status=ok` and `statuscode=200`.
- Every message must belong to the exact room token of the request. The map key
  of a page must equal its message ID and IDs must not repeat.
- `X-Chat-Last-Given` is the minimum of the returned message IDs. The next page
  may only contain IDs lower than the previous cursor. An empty page has no
  cursor and ends the pagination.

## Flutter behaviour

The conversation detail opens a separate screen with horizontally scrollable
ChoiceChip categories and a lazy message list. The first page is only loaded
after the overview. The next page has a visible button, an error keeps the
already loaded items and offers a retry. Switching the category as well as
closing the screen aborts the transport, and a generation guard ignores a late
response.

An item reuses the existing safe Rich Object Strings renderer and the
account-authenticated opening of attachments. Tapping a card opens the exact
source message. For a reply or a named thread the canonical root is first looked
up through the existing chat sync, and only then is the correct thread scope
opened.

## Evidence

- Pure Dart shared-items contract: 13/13.
- The affected Flutter suite of the service, the UI, message navigation and Room
  Details: 89/89.
- All of `talk_protocol`: 933/933. The whole mobile suite: 1478 passing and four
  credential-gated skips; `flutter analyze` with no findings.
- Live read-only server: room list 200, overview 200 with the categories `file`
  and `media`, page 200 with a single item and `X-Chat-Last-Given` present.
- Android 14 release APK, update install with the account preserved: the entry in
  Room Details, both `file` and `media`, several real images, switching the
  category and jumping back to the source message. Logcat had no Flutter or
  AndroidRuntime error.
- Real light, dark and 200% screenshots are available locally in `.artifacts`;
  SHA-256 light
  `841c0f974472dc312afd98048cd7a842178677009625d12a04ad23494fc2a2d5`, dark
  `fcbd9cbb2f51dbd01ea40d124c06db8083fb41a2b41e4a67f1d146e3d8d82e9f` and
  200% `06dfa103d4c6bc424d614f05d876c2ec73234db043fade7bf681ffbd7478e4eb`.
- Pixel pairs from the real screenshots: light primary 16.37:1, secondary 8.96:1,
  chip 7.25:1 and outline 3.28:1; dark primary 15.39:1, secondary 11.74:1,
  chip 7.25:1 and outline 3.54:1.

Still missing: a live page longer than 28 items, lobby 412, a federated room, the
iOS simulator on the current SHA and a physical Android/iOS device. The local
release APK was not shipped to testers.
