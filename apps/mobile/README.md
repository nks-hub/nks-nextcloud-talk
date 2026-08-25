# NKS Talk Flutter client

Původní multi-server a multi-account Flutter klient kompatibilní s Nextcloud
Talk. Jeden zdrojový strom vytváří aplikaci pro Android, iOS, Windows, macOS a
Linux pod identitou `com.nkshub.nextcloudtalk`.

## Aktuálně implementováno

- normalizace Nextcloud URL, status, Login Flow v2 a authenticated capabilities;
- uložení app passwordu přes platformní secure storage;
- account-scoped Drift databáze a přepínání více účtů;
- capability-first synchronizace seznamu konverzací přes conversation v4;
- cache-first root chat a vlákna přes produkční cestu
  `ChatRoomPane → ChatService → HTTP → Drift → Riverpod → UI`;
- account/room/thread-scoped history a future synchronizace s izolací rootu a
  vláken a foreground pollingem `0 → 30 → 0`;
- textový composer a send s `referenceId`, potvrzeným výsledkem a explicitním
  stavem pro nejednoznačné odeslání s rizikem duplicity;
- otevření existujícího i zatím prázdného vlákna, GFM/Rich Object obsah,
  odkazy, obrázky, reakce a náhled odpovědi;
- účastnické avatary ze stejného server originu s bezpečným lokálním fallbackem;
- jediný editovatelný composer semantics node a přímo v Android runtime
  ověřený platformní název přes `AccessibilityNodeInfo.getHintText`; XML
  `NAF=true` je false positive, protože `hintText` neserializuje;
- česká a anglická lokalizace, světlý a tmavý motiv;
- kompaktní telefonní shell a adaptivní tablet/desktop shell;
- Android a Windows debug build; aktuální APK má příchozí Android thread smoke,
  starší APK oddělený historický obousměrný thread E2E a aktuální runtime
  ověření threadu v obou motivech i při 200% velikosti textu.

Celý Talk klient ještě hotový není. Samostatný runtime důkaz stále potřebují
root history/read-unread, restart outboxu, přílohy, voice, Giphy, push, hovory,
iOS/macOS/Linux, zvukové ověření TalkBacku a širší screen-reader audit.
Přítomnost tlačítka nebo platformní složky se nepovažuje za dokončenou funkci.

## Adaptivní rozložení

<!-- markdownlint-disable MD013 -->

| Šířka | Rozložení |
| --- | --- |
| méně než 720 logical px | horní lišta, přepínač účtu a seznam konverzací; detail se otevírá jako další route |
| 720 až 1099 logical px | 88px account rail, 330px seznam a samostatný detail |
| 1100 logical px a více | 88px account rail, 390px seznam a rozšířený detail |

<!-- markdownlint-enable MD013 -->

Onboarding se od 900 logical px skládá do dvou sloupců. Změna velikosti okna
přepočítá rozložení bez změny datového nebo navigačního modelu.

## Lokální ověření

~~~console
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter build windows --debug
~~~

Build macOS a iOS vyžaduje macOS/Xcode. Linux build se ověřuje na Linux hostu.
Android nepoužívá `google-services.json`; cílový Web Push tok se registruje za
běhu podle capabilities konkrétního Nextcloud serveru.

Podrobná evidence je v
[dokumentu Flutter foundation](../../docs/architecture/flutter-foundation.md)
a v [auditu dokončení](../../docs/architecture/completion-audit.md).

## Licence

Zdrojový kód je dostupný pod `GPL-3.0-or-later`; kanonický text je v kořenovém
souboru [LICENSE](../../LICENSE).
