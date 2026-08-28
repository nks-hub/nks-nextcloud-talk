# Notifikace

Aplikace běží na Androidu, iOS, Windows a macOS a na každé z těch platforem
doručuje notifikace jinudy. Tenhle dokument popisuje, kudy, proč zrovna tak,
a hlavně co je pevně dané platformou a nedá se to obejít.

## Tři kanály, ne jeden

| kanál | platforma | probudí zavřenou aplikaci | co potřebuje |
| --- | --- | --- | --- |
| push v2 přes vlastní proxy | Android, iOS, macOS | ano | proxy a token od FCM/APNs |
| Web Push přes UnifiedPush | Android | ano | VAPID na serveru |
| Nextcloud Client Push (`notify_push`) | všechny | ne | `notify_push` na serveru |

Na Androidu existují dvě cesty současně a uživatel mezi nimi přepíná
v Nastavení → Push notifikace, bez nového buildu. Výchozí je proxy, Web Push
zůstává jako záloha. Podrobnosti níž v „Dvě cesty na Androidu".

Nejsou to alternativy k výběru: doplňují se. Živý kanál doručuje okamžitě,
dokud aplikace běží, a to úplně všude. Probudit ukončenou aplikaci umí jen
Web Push na Androidu a APNs na Apple zařízeních.

## Web Push (Android)

Registrace jde na `/ocs/v2.php/apps/notifications/api/v2/webpush`, což je
novější endpoint notifikační aplikace bez prostředníka. Klient si vyzvedne
VAPID veřejný klíč a založí odběr; doručení obstarává UnifiedPush s
distributorem zabaleným v aplikaci, takže uživatel nic dalšího neinstaluje.
Šifrovaný obsah rozbaluje nativní vrstva.

Kudy ta zpráva doopravdy teče, je ale potřeba říct přesně, protože zabalený
distributor není totéž co přímé spojení. Knihovna
`org.unifiedpush.android:embedded-fcm-distributor` nepoužívá Firebase SDK a
nepotřebuje `google-services.json`; mluví s Google Play Services přes staré
C2DM broadcasty (`com.google.android.c2dm.intent.RECEIVE`). Jako endpoint
odběru registruje `https://fcm.distributor.unifiedpush.org/wpfcm`, veřejnou
přepisovací bránu projektu UnifiedPush, která Web Push požadavek převede na
FCM zprávu. V cestě tedy stojí dvě cizí infrastruktury, UnifiedPush a Google.
Obsah je pro obě nečitelný — Web Push payload je šifrovaný `aes128gcm` klíči
z odběru, které brána nemá — ale metadata (čas, cílové zařízení, frekvence)
jim viditelná jsou. Kdo tohle nechce, musí si postavit vlastní bránu nebo
sáhnout po samostatném distributoru.

Probudit ukončenou aplikaci to umí, protože zprávu doručuje broadcast a
transport drží Play Services, ne naše aplikace. Tři meze to ale má:

- **Force stop** (Nastavení → Vynutit ukončení, agresivní OEM správci baterie
  na Xiaomi, Huawei nebo Samsungu) uvede aplikaci do „stopped state" a Android
  jí broadcasty nedoručí, dokud ji uživatel sám nespustí. Platformní pravidlo,
  platí i pro oficiální Talk s FCM.
- **Bez Google Play Services** zabalený distributor nefunguje —
  `AndroidWebPushChannel.ensureEmbeddedDistributor()` vyhodí
  `embedded_distributor_unavailable`. Na GrapheneOS bez sandboxed Play, na
  Huawei nebo /e/OS je nutný samostatný distributor (ntfy).
- **Doze** odloží zprávy s normální prioritou do údržbového okna. Vysoká
  priorita, kterou `Push::getNotifTopicAndUrgency` nastavuje hovorům a
  zmínkám, jím projde okamžitě.

Na iOS se tahle cesta použít nedá: Web Push v nativní aplikaci neexistuje a
UnifiedPush je Android-only, protože iOS nedovolí držet spojení na pozadí.

## Dvě cesty na Androidu a přepínač mezi nimi

Nativní cestou Androidu je naše vlastní proxy, tedy přesně ten kontrakt, který
používá iOS: `POST /ocs/v2.php/apps/notifications/api/v2/push` s
`proxyServer: https://push.example.invalid` a pak registrace u proxy na
`/devices`. Serverová strana se tím nemění vůbec — `Push.php` platformu
nerozlišuje, seskupuje podle sloupce `proxyserver` a rozhodnutí, jestli
notifikaci poslat do APNs nebo do FCM, dělá až proxy podle formátu tokenu.
Tím se z cesty vyřadí `fcm.distributor.unifiedpush.org`.

Web Push větev se nemaže. Zůstává jako záloha za přepínačem pro případ, že by
proxy cesta dělala potíže.

Kód je proto rozdělený takhle:

| soubor | co dělá |
| --- | --- |
| `push_registration_coordinator.dart` | platformně neutrální smyčka nad `talk_protocol` push-v2 automatem |
| `android_push_device_key_store.dart` + `AndroidPushDeviceKeyStore.kt` | RSA-2048 klíč zařízení v Android Keystore, jeden na účet |
| `android_push_coordinator.dart` | stávající Web Push cesta, beze změny až na `revokeAllRegistrations()` |
| `android_push_transport.dart` | volba cesty, její uložení a čisté přepnutí |

Přepínač je soubor v adresáři aplikace, stejný mechanismus jako volba motivu,
takže se mění za běhu bez nového buildu. Pořadí při přepnutí je to důležité:
Nextcloud si registraci klíčuje podle zařízení, ne podle cesty, takže se
**nejdřív odregistruje stará cesta** u Nextcloudu i u své brány a teprve
potom se uloží nová volba. Když odregistrace selže, volba se nezmění a
uživatel to uvidí; zařízení tak zůstane registrované postaru místo aby
nezůstalo registrované nikde.

Klíč zařízení je per účet: handle je SHA-256 z `accountId` a push automat
odmítne klíč, který už drží jiný účet, takže jeden účet nikdy nemůže
dešifrovat notifikaci druhého.

Notifikaci na Androidu vyrábí **výhradně nativní vrstva** z push transportu.
Aplikace nemá žádný balíček na lokální notifikace a v Dartu se notifikace
neposílá nikde; Client Push po websocketu jen spouští synchronizaci. Běžící
aplikace tedy nemůže dostat tutéž událost dvakrát viditelně, i když dorazí
po websocketu i z FCM — není druhý zdroj, který by ji zobrazil. Opakované
doručení téže zprávy druhou notifikaci nevytvoří: platformní ID je stabilní
podle `(accountId, nid)`, takže se první přepíše.

Nerozšifrovatelná zpráva se zahazuje beze stopy — nezobrazí se nic, nikam se
to nezapisuje a nepočítá. Který klíč sedl je totiž samo o sobě informace
o tom, komu zpráva patří, a zpráva, kterou neotevře žádný klíč, patří účtu,
který na zařízení už není.

### Doručení

`NksFirebaseMessagingService` dostane od proxy `data`-only zprávu s jediným
klíčem `nc-subject`, což je base64 RSA ciphertextu tak, jak ho vyrobil
Nextcloud. Rozšifruje ho privátním klíčem z Android Keystore (RSA, PKCS#1 v1.5
— Nextcloud má v appconfigu ten default) a výsledek pustí do **téhož**
`AndroidWebPushPayloadParser` a `AndroidSystemNotifications.apply`, které
používá Web Push. Druhá zobrazovací vrstva tedy neexistuje.

Který účet zprávu dostane, se pozná podle toho, který klíč ji otevře — token
je jeden na zařízení, klíče jsou per účet. Seznam přihlášených účtů posílá
Dart nativní straně (`setAccounts`), protože doručení může probudit mrtvý
proces.

Živý průchod 27. srpna 2026 na Androidu 14 prokázal celý primární řetěz
Nextcloud → vlastní proxy → FCM → ukončený proces. Balíček nebyl ve stavu
force-stop, ale proces neběžel. Notifikace zobrazila skutečný obsah, klepnutí
otevřelo správný účet a místnost, Reply vytvořilo právě jednu serverovou
zprávu a Mark as read posunulo serverový read marker. Web Push byl potom
samostatně ověřen jako funkční záloha včetně přepnutí oběma směry.

Commit `18bb4f0` uzavírá chybové stavy předání mezi transporty: volba se načte
před startem koordinátoru, souběžná přepnutí se serializují a selhaný zápis
nové volby znovu obnoví už odregistrovanou původní cestu. Uživatel tak po
neúspěšném přepnutí nezůstane bez registrace.

### Kdy notifikace dorazí okamžitě a kdy ne

Talk má u Nextcloudu vždy vysokou naléhavost, i běžná zpráva —
`Push.php` nastaví `urgency = high` pro `spreed`, `talk`
i `admin_notification_talk`. Proxy to mapuje jedna ku jedné na
`android.priority: high`.

ZMĚŘENO 2026-08-27 na `chatujmePixel` (Android 14) přes
`RemoteMessage.getOriginalPriority()` a `getPriority()`, dočasnou
instrumentací, která ve stromě nezůstala. Obojí vrátilo `1`, tedy
`PRIORITY_HIGH`, a to i ve stavu, který prioritu měl podle očekávání srazit:
aplikace odebraná z výjimek úsporného režimu, standby bucket `RESTRICTED`
(45) a zařízení ve `deviceidle` stavu `IDLE`. Zpráva dorazila za 471 ms od
`sentTime`. **Vysokou prioritu tedy nese celý řetěz správně a Android ji
nesnižuje ani v hlubokém úsporném režimu**; App Standby Buckets jako
vysvětlení odpadají.

Zdržení, které jsme přesto pozorovali, mělo jinou příčinu: na emulátoru po
delší nečinnosti zvětrá spojení Play Services a zprávy se nakupí, dokud ho
něco neprobudí. Nic se přitom neztratí — když se spojení obnovilo, dorazily
i všechny odložené zprávy. Log proxy to potvrdil z druhé strany: šest
odeslání, šest `200 OK` od Googlu.

Praktický důsledek: **hlášení „notifikace chodí pozdě" nehledejte v našem
kódu.** Priorita je správně od Nextcloudu až po `getPriority()` na zařízení.
Před testováním push na emulátoru ho vytáhněte z úsporného režimu
(`adb shell cmd deviceidle unforce`, případně balíček na whitelist), jinak
měříte Googlův plánovač, ne naši cestu. Fyzické zařízení se takhle nechová.

## Client Push (`notify_push`) — všechny platformy

Nextcloudem navržený živý kanál. Server ho nabízí v capabilities:

```
notify_push.type      → ["files", "activities", "notifications"]
notify_push.endpoints → { websocket: "wss://…/push/ws", pre_auth: "https://…" }
```

Že posílá i notifikace, ne jen změny souborů, plyne z toho, že
`apps/notify_push/lib/Listener.php` implementuje `INotifier` a volá
`$this->queue->push('notify_notification', …)`.

Postup klienta:

1. `POST` na `pre_auth` přes autentizované HTTPS → jednorázový token.
   **Route je POST**; `GET` server odmítne s `405` a socket pak token nikdy
   nedostane. Kanál se v takovém případě tiše nepřipojí a aplikace se tváří
   normálně — proto to hlídá test.
2. Připojit `wss://…/push/ws`, poslat **prázdné uživatelské jméno** a pak ten
   token. Heslo aplikace po socketu necestuje.
3. Server odpoví `authenticated`, pak posílá rámce. `notify_notification`
   znamená „něco přišlo, synchronizuj".

Implementace: protokol v `packages/talk_protocol/lib/src/client_push/`,
spojení a koordinace v `apps/mobile/lib/features/push/client_push_*.dart`.
Endpoint z capabilities musí patřit témuž hostu jako účet, jinak se token
nikam neposílá; `ws` bez TLS se odmítá a rámce doručené před přijetím tokenu
se zahazují.

Ověření, že kanál skutečně běží, se dělá ze serveru, ne z logu aplikace:

```sh
occ notify_push:metrics   # Active connection count / Active user count
```

## APNs (iOS, macOS) a proč k tomu je potřeba proxy

Tohle je část, která překvapí, takže je popsaná podrobně.

Nextcloud **do APNs neumí**. V `apps/notifications/lib/Push.php` není jediná
zmínka o Apple; server jen seskupí notifikace podle sloupce `proxyserver` a
udělá `POST <proxyServer>/notifications`. Doručení do APNs obstarává až ta
adresa.

Oficiální aplikace Nextcloud Talk pro iOS proto míří na
`https://push-notifications.nextcloud.com` — službu, kterou provozuje
Nextcloud GmbH a která notifikaci podepíše **jejich** Apple certifikátem pro
**jejich** bundle id. Dokumentace `nextcloud/notifications/docs/push-v2.md`
to říká přímo: klíče a certifikáty nemohou být součástí serveru, jinak by je
měl každý; proxy notifikaci ověří veřejným klíčem uživatele a pak ji
„signs with Google or Apple Developer certificate".

Z toho plyne, co platí i pro nás:

- Proxy **není součástí self-hosted Nextcloudu**. Váš server na ni jen posílá
  odchozí požadavek.
- Do aplikace s jiným bundle id přes ni notifikace nedorazí, protože ji
  Nextcloud svým certifikátem podepsat nemůže.
- Adresu si volí **klient** při registraci zařízení, ne administrátor.
  `PushController::registerDevice` přijme parametr `proxyServer` a jen ho
  zvaliduje (platná URL do 256 znaků, `https://`, pro test i `localhost` a
  `*.internal` / `*.local`). V UI Nextcloudu se nenastavuje nikde — admin
  sekce notifikací vystavuje jen `setting_batchtime`.

Náš klient tedy posílá vlastní adresu; pole je v
`packages/talk_protocol/lib/src/push/effects.dart`:

```dart
Map<String, String> get formFields => <String, String>{
  'pushTokenHash': providerToken.sha512,
  'devicePublicKey': key.publicKey.pem,
  'proxyServer': context.gateway.value,
};
```

Co server na tu adresu pošle:

```
POST <proxyServer>/notifications
{"notifications": [{deviceIdentifier, pushTokenHash, subject,
                    signature, priority, type}, …]}
```

`subject` je payload zašifrovaný veřejným klíčem zařízení. Proxy ho
**nedešifruje a nemůže** — rozbalí ho až Notification Service Extension přímo
v telefonu. `pushTokenHash` je SHA-512 skutečného push tokenu, takže proxy
potřebuje vlastní registraci, kde si klient uloží dvojici hash → token.

Registrace u proxy navíc výslovně nese `pushProvider=apns|fcm`. Provider se
ukládá k zařízení a proxy podle něj volí odesílací větev; tvar tokenu není
autoritativní. APNs registrace musí nést také
`pushEnvironment=development|production`, zatímco FCM tuto hodnotu odmítá.
Debug Apple build používá development, Profile a Release production. Proxy
drží oba APNs klienty současně a endpoint vybírá per zařízení, takže souběžný
simulátorový a TestFlight provoz si navzájem nemaže platné registrace.

Na straně Apple je k tomu potřeba:

| položka | hodnota |
| --- | --- |
| Tým | `TEAMID0000` |
| App ID | `com.nkshub.nextcloudtalk` s capability Push Notifications |
| App ID rozšíření | `com.nkshub.nextcloudtalk.NotificationService` |
| App Group | `group.com.nkshub.nextcloudtalk` |
| APNs klíč | token-based `.p8`, Sandbox i Production |

Rozšíření má vlastní App ID a přes App Group se dostane k privátnímu klíči,
kterým notifikaci dešifruje. Certifikáty potřeba nejsou, `.p8` je nahrazuje a
nevyprší.

Stejně jako na Androidu (výš) je i tady notifikaci schopen zobrazit jen jeden
zdroj: `pubspec.yaml` neobsahuje balíček na lokální notifikace a Dart nikde
nevolá nic, co by notifikaci vyrobilo — Client Push po websocketu jen spustí
`ConversationSyncService.sync`. Banner na obrazovce vzniká výhradně z toho, co
sestaví Notification Service Extension z APNs payloadu. Běžící aplikace tedy
nemůže dostat tutéž zprávu viditelně dvakrát, i kdyby jí Client Push i APNs
oznámily prakticky současně — druhý zobrazovací zdroj neexistuje, není co
deduplikovat.

### Stav implementace: iOS hotové a živě ověřené přes vlastní proxy

HOTOVO A OVĚŘENO v `d75d0b8` (build přes `flutter run` + `xcodebuild test`,
ne jen `analyze`), stav 2026-08-27/28:

- Notification Service Extension jako vlastní Xcode target (dva reálné
  build-blocking bugy v ručně psaném `project.pbxproj` nalezené a opravené
  skutečným buildem, ne čtením — chybějící `XCBuildConfiguration`/
  `XCConfigurationList` a chybějící `PBXSourcesBuildPhase` objekt).
- Dešifrování `nc-subject` (`PushEnvelopeDecryptor`, PKCS#1 v1.5 nejdřív,
  OAEP-SHA1 jako Nextcloudova jediná alternativa), ciphertext se odmítne,
  pokud není přesně 256 B (RSA-2048 modulus) — kontrola proběhne ještě před
  prvním `SecKeyCreateDecryptedData`, ne až po něm. Payload musí nést `app`
  jako neprázdný string, samotné „je to JSON objekt" nestačí.
- Přepis title/body a `content.categoryIdentifier` pro Reply/Mark as Read.
  Titulek je shodný s Androidem: `app == "spreed"` → lokalizovaný název
  aplikace, jinak raw `app` id — přepnutí mezi zařízeními nesmí ukázat jiný
  text pro tutéž zprávu.
- Rozklik i notifikační akce nesou účet **přímo od dešifrujícího klíče**
  (Keychain label, `PushDeviceKeyStore.setAccount`/`allKeys()`), ne
  rekonstruovaný z hostitele serveru. Nezávislý audit (Codex) na tohle
  upozornil jako na vážný nález: dva účty na stejném serveru by si jinak
  mohly poslat rozklik nebo odpověď z notifikace pod cizí identitou.
  `ApplePushNotificationOpenDelivery` nese `{accountId, roomToken}` stejným
  tvarem fronty jako `AppleDeepLinkDelivery`, ale je to samostatný
  mechanismus — zrcadlí Androidí `AndroidNotificationOpen`, který taky nejde
  přes deep-link resolver.
- `ApplePushRegistrationCoordinator.dispose()` čeká na rozdělaný `_drain()`
  před zavřením gateway klienta — dřív mohl přerušit mid-flight
  register/unregister a nechat zařízení zaregistrované jen na Nextcloudu,
  nebo jen na proxy. Ověřeno i obráceně: test bez opravy padá přesně na
  „dispose must wait for the in-flight drain".
- Foreground dedup Client Push vs. APNs byl postavený a pak **zrušený** —
  ověřeno (grep), že druhý zobrazovací zdroj vůbec neexistuje (viz odstavec
  výš), takže nebylo co deduplikovat.

Živý APNs development průchod přes vlastní proxy prokázal doručení při
ukončeném procesu, dešifrování v Notification Service Extension a studený
Open do správného účtu a místnosti. Reply vytvořilo právě jednu zprávu pod
účtem určeným dešifrujícím klíčem a Mark as read posunulo serverový marker.
Účet se nikde nedohledává podle hostitele. Pod-wired iOS XCTest skončil
`TEST SUCCEEDED`.

### Stav implementace: macOS production ověřeno

Podepsaný Universal Release z 28. srpna 2026 se přes vlastní proxy registroval
jako `apns/production`. Při ukončeném procesu prošel celý tok Nextcloud → proxy
→ APNs production → macOS Notification Service Extension. NSE dešifrovalo
obsah a systém zobrazil skutečnou kartu NKS Talk. Cold Open otevřel správný účet
a místnost, Reply vytvořilo právě jednu serverovou zprávu pod příjemcem a Mark
as Read skončilo s `lastReadMessage == lastMessage.id` a nulovým počtem
nepřečtených. Commity `9d8e7ac` a `5f8ee50` navíc hlídají, že NSE nelinkuje
Runner pody a deklaruje macOS `NSExtensionService_Subsystem`.

## Windows: běžící aplikace ano, zavřená ne

Na Windows notifikaci ukazuje sama aplikace, dokud běží. Client Push vyvolá
synchronizaci a nová Talk zpráva se zobrazí jako WinRT `ToastGeneric`.
Notifikace nabízí explicitní akce Open, Reply a Mark as read.

**Současný nepackagovaný build neumí probudit ukončený proces.** Takové
doručení vyžaduje Windows Notification Service, packaged identitu z Microsoft
Store a out-of-process COM aktivátor. Dokud aplikaci distribuujeme mimo Store,
je běžící proces záměrná platformní hranice, ne předstíraně hotová funkce.

Toast XML neobsahuje `accountId` ani room token. Nativní vrstva pro každou
notifikaci vytvoří náhodný opaque GUID a drží bounded mapu nejvýše 64 tras.
Aktivace předá do Dartu teprve odpovídající `{accountId, roomToken}`; fronta
rozkliků v Dartu má nejvýše 32 položek. Reply se zařadí do stejného durable
outboxu jako odpověď z aplikace a Mark as read používá stejný account-scoped
read service. Dva účty na stejném serveru se proto nerozlišují hostitelem.

Obsah se nikde nedotahuje znovu. Skládá se z řádků, které už zapsala
synchronizace a které renderuje seznam konverzací, a spouštěčem je vzestup
počtu nepřečtených. První načtení se jen zapamatuje: jinak by po každém startu
vyletěla dávka notifikací na všechno dávno nepřečtené. Filtr na Talk je
splněný konstrukcí — v `cachedConversations` jsou výhradně Talk konverzace,
karta z Decku se do té tabulky nedostane.

Živý průchod na Windows 11 nad commity `ef80b04` a `ea63609` prokázal release
build, doručení do Notification Center, jednu serverovou zprávu po Reply,
serverový `unreadMessages=0` po Mark as read a explicitní Open do správného
účtu a místnosti. Focused Windows sada prošla 12/12, integrační testy 2/2 a
`flutter analyze` bez nálezu.

## Jen Talk, nic jiného

Nextcloud posílá na registrované zařízení notifikace **všech** aplikací, ne
jen Talku, takže karta z Decku dorazí na stejný kanál jako zpráva. Pole `app`
v payloadu je proto brána: zobrazí se jen `spreed`. Payload bez `app` se za
Talk nepovažuje — nehádá se.

## VoIP push a proč tu zatím není

Hovory potřebují na iOS druhý, oddělený kanál: PushKit s VoIP tokenem. Apple
u něj vynucuje, že každý doručený VoIP push musí skončit voláním
`reportNewIncomingCall`, jinak systém aplikaci zabije — takže se ten kanál
nedá použít na běžné notifikace a naopak.

Upstream to řeší způsobem, který je dobré znát dřív, než se to začne stavět:
iOS klient posílá proxy **jeden řetězec se dvěma tokeny oddělenými mezerou**,
`"<běžný hex> <voip hex>"`, a `pushTokenHash` pro Nextcloud počítá SHA-512
právě z toho spojeného tvaru (`NCKeyChainController.m`). Naše proxy tenhle
tvar dnes nepřijme: `token_kind()` uznává jen čistý hex nebo base64url a
mezera neprojde ani jednou maskou, takže by registrace skončila na
`INVALID_PUSH_TOKEN`. Databáze proxy má navíc jediný sloupec `push_token`,
takže i kdyby prošla, není kam VoIP token uložit.

Mapování `type: "voip"` na topic s příponou `.voip` v proxy hotové je,
chybí tedy jen ta identita a schéma. Na straně Applu k tomu bude potřeba
VoIP entitlement, který v tabulce výš není.

Nejsme vázaní upstream tvarem — proxy i klient jsou naše, takže dvojice
tokenů může jít dvěma poli místo jednoho řetězce s mezerou. Rozhodne se to,
až se budou stavět hovory; do té doby je tohle jen zapsaný nález, ne plán.
