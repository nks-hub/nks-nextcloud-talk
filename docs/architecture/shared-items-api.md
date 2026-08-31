# Sdílené položky

Stav k 31. srpnu 2026. Wire chování je ověřené proti Nextcloud Talk serveru
`f2958bb25be6604240c58a3faf9a2033a30d20e5` a read-only během proti referenční
instanci. Flutter řez je serverově autoritativní; lokální cache zpráv neurčuje,
které kategorie ani položky existují.

## Capability brány

- Vstup se ukáže pouze s Talk capability `rich-object-list-media`.
- Federovaná místnost navíc vyžaduje `federated-shared-items`.
- Brána v detailu používá account-scoped capability snapshot. Služba před
  requestem znovu ověří aktuální autentizované capabilities a room token.
- Chybějící účet, credential, konverzace nebo neplatný room JSON selže zavřeně.

## Endpointy

Přehled dostupných kategorií:

```text
GET /ocs/v2.php/apps/spreed/api/v1/chat/{token}/share/overview
    ?format=json&limit=7
```

Stránka jedné kategorie:

```text
GET /ocs/v2.php/apps/spreed/api/v1/chat/{token}/share
    ?format=json
    &objectType={type}
    &lastKnownMessageId={cursor}
    &limit=28
```

Podporované wire typy jsou `audio`, `deckcard`, `file`, `location`, `media`,
`other`, `pinned`, `poll`, `recording` a `voice`. Neznámá budoucí kategorie se
v overview bezpečně ignoruje; známá kategorie se nikdy neodvozuje z obsahu
lokální cache.

## Ověřování odpovědi

- Transport přijme pouze 200, 401, 404, 412, 429 a 503 a tělo je omezené na
  8 MiB.
- 401 znamená nové přihlášení, 404 chybějící místnost, 412 čekání v lobby,
  429 rate limit a 503 dočasně nedostupnou službu. Chybové statusy nevyžadují
  JSON tělo.
- OCS success vyžaduje současně `status=ok` a `statuscode=200`.
- Každá zpráva musí patřit přesnému room tokenu requestu. Mapový klíč stránky
  se musí rovnat jejímu message ID a ID se nesmí opakovat.
- `X-Chat-Last-Given` je minimum vrácených message ID. Další stránka smí
  obsahovat pouze ID menší než předchozí cursor. Prázdná stránka cursor nemá a
  stránkování ukončí.

## Flutter chování

Detail konverzace otevírá samostatnou obrazovku s horizontálně posuvnými
ChoiceChip kategoriemi a lazy seznamem zpráv. První stránka se načítá až po
overview. Další stránka má viditelné tlačítko, chyba zachová už načtené položky
a nabízí opakování. Přepnutí kategorie i zavření obrazovky abortuje transport a
generation guard ignoruje pozdní odpověď.

Položka znovu používá existující bezpečný renderer Rich Object Strings a
account-authenticated otevírání příloh. Klepnutí na kartu otevře přesnou
zdrojovou zprávu. U odpovědi nebo pojmenovaného vlákna se nejdřív přes
existující chat sync dohledá kanonický root a pak se otevře správný thread
scope.

## Důkazy

- Pure Dart shared-items kontrakt: 13/13.
- Dotčená Flutter sada služby, UI, message navigation a Room Details: 89/89.
- Celý `talk_protocol`: 933/933. Celá mobilní sada: 1478 úspěšných a čtyři
  credential-gated skipy; `flutter analyze` bez nálezu.
- Živý read-only server: room list 200, overview 200 s kategoriemi `file` a
  `media`, stránka 200 s jednou položkou a přítomným `X-Chat-Last-Given`.
- Android 14 release APK, aktualizační instalace se zachovaným účtem: entry v
  Room Details, `file` i `media`, více skutečných obrázků, přepnutí kategorie a
  skok zpět na zdrojovou zprávu. Logcat neměl Flutter ani AndroidRuntime chybu.
- Reálné light, dark a 200% snímky jsou lokálně v `.artifacts`; SHA-256 light
  `841c0f974472dc312afd98048cd7a842178677009625d12a04ad23494fc2a2d5`, dark
  `fcbd9cbb2f51dbd01ea40d124c06db8083fb41a2b41e4a67f1d146e3d8d82e9f` a
  200% `06dfa103d4c6bc424d614f05d876c2ec73234db043fade7bf681ffbd7478e4eb`.
- Pixelové páry z reálných snímků: light primary 16,37:1, secondary 8,96:1,
  chip 7,25:1 a outline 3,28:1; dark primary 15,39:1, secondary 11,74:1,
  chip 7,25:1 a outline 3,54:1.

Zbývá živá stránka delší než 28 položek, lobby 412, federovaná místnost, iOS
simulátor na aktuálním SHA a fyzické Android/iOS zařízení. Lokální release APK
nebyl vydán testerům.
