# NKS Nextcloud Talk

Původní Flutter klient kompatibilní s Nextcloud Talk. Jeden build umí připojit
více účtů na více Nextcloud serverech a používá jednu codebase pro Android,
iOS, Windows, macOS a Linux.

Nejde o pixelovou kopii oficiálních klientů. Upstream Android a iOS aplikace
slouží jako SHA-bound reference chování a kompatibility; UI, datový model a
implementace jsou vlastní a licencované pod
[`GPL-3.0-or-later`](LICENSE).

## Aktuální stav

Repozitář už obsahuje spustitelnou aplikaci v [`apps/mobile`](apps/mobile):

- Nextcloud status, Login Flow v2 a authenticated capabilities;
- secure uložení app passwordu a account-scoped Drift databázi;
- více účtů, conversation-v4 full/delta sync a cache-first seznam;
- českou a anglickou lokalizaci, světlý a tmavý motiv;
- telefonní stack a adaptivní třípanelové rozložení pro tablet a desktop;
- Android debug build a nativní runnery pro Android, iOS, Windows, macOS a
  Linux. Runnery uzavírá commit `cf13cce`.

Čerstvý automatizovaný stav je `flutter analyze` bez nálezu, 354 úspěšných
Flutter testů s jedním credential-gated live skipem a 569/569 testů balíku
`talk_protocol` po opravě `d0660cc`. Attachment runtime a jeho dokumentovaný
stav uzavírá commit `61decfb`. Nativní Android Web Push uzavírá commit
`3c74165`; Kotlin unit gate prošel 16/16 a connected gate na emulátoru
`chatujmePixel` 15/15.

Finální debug APK této session je v
`apps\mobile\build\app\outputs\flutter-apk\app-debug.apk` se SHA-256
`ce6d29b5c5748454f9b23df5d5cc034432a754e90eee647e3cdb12ac749ab924`.
Stejný hash má aktuálně nainstalovaný `base.apk` na `emulator-5554`. Instalace a
instrumentace ale nejsou přihlášený live Talk smoke: čerstvé přihlášení,
conversations a otevření room na tomto APK zatím nejsou prokázané.

Windows release EXE má SHA-256
`afe945cbce39151ae44761c88bbe76938e0c80eca71057ca35e3d514e2110afd`.
Vývojový počítač je ale ve Visual Studio pending-reboot stavu, takže tento
artefakt není důkazem opakovatelného čistého buildu přes výchozí toolchain před
restartem počítače.

Pure Dart balík [`talk_protocol`](packages/talk_protocol) navíc implementuje a
testuje bootstrap, conversations, chat, rich chat, attachment, signaling
preparation a původní Notifications push-v2 wire modely. Tyto protokolové řezy
neznamenají, že jejich Flutter UI nebo platformní lifecycle už jsou hotové.

Chat a thread obrazovka, persistentní plain/reply/named-thread text send, Rich
Object renderer, obrázky, reakce a avatary už v aplikaci jsou. Attachment má
bezpečný OCS/WebDAV transport, durable Drift service, image picker/viewer a
voice record/preview/submit tok; jejich aktuální live server E2E ještě chybí.
Příchozí live thread aktualizaci a obousměrný send prokazují starší APK;
named-thread send zatím nemá zařízení round trip. Giphy trending/search, výběr,
serverový send a inline animované vykreslení jsou také prokázané na starším
Android live APK. Aplikace vykresluje skutečný animovaný GIF přímo ve zprávě.
Odesílaná URL je pouze interní Talk wire reference: nesmí se zobrazit jako text
zprávy, není klikací a GIF se neposílá jako attachment. Jediný viditelný externí
GIPHY odkaz je attribution v pickeru. Root history/read-unread, live
process-death outboxu, přílohy, voice, skutečný push delivery a hovory zůstávají
samostatnými nedokončenými řezy.
Přesný stav vede
[průběžný stav vývoje](docs/architecture/development-status-2026-08-25.md) a
[audit dokončení](docs/architecture/completion-audit.md).

## Push bez per-server rebuildu

Android cílí na Notifications Web Push v Nextcloud 34+ přes UnifiedPush
connector a vestavěný FCM distributor. Veřejný Android build proto nebude mít
publisher Firebase projekt, `google-services.json`, vlastní mobilní gateway ani
rebuild pro každý Nextcloud server. VAPID klíč a Web Push subscription se
vyjednají za běhu s konkrétním serverem.

Nativní Android push implementaci v commitu `3c74165` uzavřelo bezpečnostní
review, striktní parser, account-bound one-time tap token a čerstvé Kotlin testy.
Jde o implementovaný a automatizovaný platformní řez, ne o hotové live push
doručení. Skutečný Nextcloud → FCM → background/killed tok na fyzickém zařízení
je stále otevřený.

Na všech platformách navíc běží **Nextcloud Client Push** (`notify_push`) —
websocket, který Nextcloud sám nabízí v capabilities. Doručí zprávu okamžitě,
dokud aplikace běží, a nepotřebuje k tomu nic navíc.

iOS je odlišná platformní hranice a stojí za to říct proč přesně. Nextcloud do
APNs neumí; `apps/notifications/lib/Push.php` jen seskupí notifikace podle
sloupce `proxyserver` a pošle je na tu adresu. Doručení do APNs obstarává až
ona. Oficiální aplikace Talk míří na `push-notifications.nextcloud.com`, což
je služba Nextcloud GmbH podepisující **jejich** Apple certifikátem pro
**jejich** bundle id — do klienta třetí strany přes ni nedorazí nic. Ta adresa
tedy **není součástí self-hosted Nextcloudu** a v jeho administraci se
nenastavuje; volí ji klient při registraci zařízení parametrem `proxyServer`.

Kompletní popis všech tří kanálů, kontraktu s Nextcloudem a toho, co je pevně
dané platformou, je v [dokumentu o notifikacích](docs/architecture/notifications.md).
Starší analýza je v [push analýze](docs/research/push-fcm.md).

## Dokumentace

- [Rozcestník dokumentace](docs/README.md)
- [Flutter aplikační základ](docs/architecture/flutter-foundation.md)
- [Požadavky a důkaz dokončení](docs/architecture/requirements.md)
- [Systémový návrh](docs/architecture/system-design.md)
- [Notifikace na všech platformách](docs/architecture/notifications.md)
- [Implementační řezy a testovací brány](docs/architecture/delivery-plan.md)
- [Rozhodnutí a otevřené volby](docs/architecture/decisions.md)
- [Výzkum oficiálních klientů](docs/research/README.md)
