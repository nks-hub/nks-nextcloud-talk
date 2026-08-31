# Sdílení aktuální polohy

Stav k 31. srpnu 2026. Wire tok odpovídá Talk serveru
`f2958bb25be6604240c58a3faf9a2033a30d20e5` a Android klientu `5428960`.

Akce se nabízí pouze za capability `geo-location-sharing`, v zapisovatelné
místnosti a v root nebo pojmenovaném thread scope. Obyčejná reply větev ji
nenabízí, protože rich-object endpoint přijímá jen named `threadId`.

Klient po výslovné akci uživatele požádá jen o foreground oprávnění, získá
jednu aktuální polohu s 15sekundovým limitem a před odesláním ukáže souřadnice
k potvrzení. Background location se nepoužívá.

```text
POST /ocs/v2.php/apps/spreed/api/v1/chat/{token}/share
objectType=geo-location
objectId=geo:{latitude},{longitude}
metaData={...}
referenceId={uuid}
threadId={named-thread-id}  # pouze pojmenované vlákno
```

Request validuje finite souřadnice v rozsahu ±90/±180, bounded jméno,
account/server/room/credential/capability binding a u named scope i cached
canonical root. Odpověď musí být HTTP/OCS 201 a vrátit zprávu stejné místnosti
a vlákna. 400/413, 401, 403, 404, 429 a 5xx zůstávají odlišené.

Automatizované důkazy: location contract 5/5, service a permission/fallback
12/12, composer 4/4, platformní metadata a oba analyzátory bez nálezu. Tok je
vázaný na generation původní místnosti; její změna před potvrzením zruší zápis.
Timeout, síťová ztráta, nečitelná 201 a 5xx po dispatchi jsou `ambiguous`, ne
bezpečně opakovatelný neúspěch. Release APK prošlo licenční bránou se 145
Flutter balíky a 111 Android komponentami.

Android 14 emulátor živě získal foreground GPS fix, zobrazil přesné souřadnice
k potvrzení a server vytvořil zprávu 78017. Klient ji vykreslil jako Sdílenou
polohu; screenshot je `.artifacts/nks-location-live.png` a PID log po úspěšném
průchodu neměl Flutter ani HTTP výjimku. Testovací zpráva byla poté přes klienta
serverově smazána a lokální autoritativní projekce potvrdila `deleted=1`.
Menu a potvrzení mají skutečné light/dark snímky v `.artifacts`. Pixelové
minimum textu je 4,567:1 light a 8,5054:1 dark; minimum ikon je 8,4713:1 light
a 10,3081:1 dark. Tlačítko potvrzení má 6,4986:1 light a 9,6541:1 dark.
První pokus skončil systémovým `DeadSystemException` spolu s pádem Chrome a
Android UI; po úplném startu emulátoru stejný tok prošel. iOS odesílací runtime
a fyzická Android/iOS poloha zbývají. macOS má požadovaný location purpose
string, sandbox entitlement a zamknutý `geolocator_apple` pod; živý desktopový
tok zatím doložený není.
Nový distribuční build se kvůli tomuto jedinému bodu nevydává.
