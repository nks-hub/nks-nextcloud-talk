# Message translation

State as of 31 August 2026. The capability and the client flow are verified
against the Nextcloud Talk server `f2958bb25be6604240c58a3faf9a2033a30d20e5` and
its OCS Translation API. The Flutter implementation is capability-first and uses
no translation provider or proxy of its own.

## Capability gate

- The Translate action only appears with the boolean capability
  `spreed.config.chat.has-translation-providers`.
- The gate is account-scoped. Before every request the service reloads the
  authenticated capabilities and verifies that the exact conversation exists.
- A missing account, credential or conversation, a mismatched room token or
  invalid room JSON fails closed without sending the text.
- The reference instance does not provide the capability, so the action stays
  correctly hidden there. A successful live translation is not claimed for that
  instance.

## Endpoints

The list of supported language pairs:

```text
GET /ocs/v2.php/translation/languages?format=json
```

Translating text:

```text
POST /ocs/v2.php/translation/translate?format=json
Content-Type: application/json

{
  "text": "Message text",
  "fromLanguage": null,
  "toLanguage": "cs"
}
```

`fromLanguage=null` is only offered when the server returns
`languageDetection=true`. The target language is chosen only from the pairs the
server returned.

## Boundary validation

- The request text is at most 1 MiB of characters and must not be empty after
  trimming.
- A language identifier is 1 to 32 characters and may only contain letters,
  digits, `_` and `-`. The source and the target must not be the same.
- The response is limited to 2 MiB and at most 4096 unique language pairs.
- Success requires HTTP 200 as well as OCS `status=ok` and `statuscode=200`.
- 400 is invalid input, 401 requires a new login, 404/412 means translation is
  unavailable, 429 a rate limit and 500/503 an unavailable service. Other
  statuses are rejected as unsupported.
- Logs and `toString` never print the original or the translated text.

## Flutter behaviour

The action in the message menu opens a dialog, loads the language pairs and
offers server-side detection or a specific source language. The translated result
is rendered by the same Rich Object Strings renderer as the original message, so
it preserves safe mentions and other parameters. The dialog warns that the
translation was produced by AI and allows copying the plain translated text.

Both loading the languages and translating can be retried after an error. Closing
the dialog aborts the transport and a generation guard ignores the late
completion of an older request. Switching the account or the room cannot redirect
a running translation into a different scope.

## Evidence

- Pure Dart translation contract: 13/13.
- The affected Flutter suite of the service, the dialog and the message menu:
  60/60.
- All of `talk_protocol`: 946/946. The whole mobile suite: 1493 passing and four
  credential-gated skips; `flutter analyze` with no findings.
- The release APK passed the build and the license gate 140/111. An update
  install on Android 14 preserved the account, and the server hid the action for
  lack of the capability.
- A real screenshot of the menu is available locally at
  `.artifacts/nks-translation-menu.png`.

Still missing: a server with an active translation provider for a successful live
round trip, a real provider error state, the iOS runtime and a pixel check of the
dialog in both themes.
