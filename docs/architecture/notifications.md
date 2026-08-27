# Notifikace

Aplikace běží na Androidu, iOS, Windows a macOS a na každé z těch platforem
doručuje notifikace jinudy. Tenhle dokument popisuje, kudy, proč zrovna tak,
a hlavně co je pevně dané platformou a nedá se to obejít.

## Tři kanály, ne jeden

| kanál | platforma | probudí zavřenou aplikaci | co potřebuje |
| --- | --- | --- | --- |
| push v2 přes vlastní proxy | Android, iOS | ano | proxy a token od FCM/APNs |
| Web Push přes UnifiedPush | Android | ano | VAPID na serveru |
| Nextcloud Client Push (`notify_push`) | všechny | ne | `notify_push` na serveru |

Na Androidu existují dvě cesty současně a uživatel mezi nimi přepíná
v Nastavení → Push notifikace, bez nového buildu. Cílový nativní stav je
proxy; výchozí hodnota je zatím Web Push, protože jen ta je prokázaná
reálným během. Podrobnosti níž v „Dvě cesty na Androidu".

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

Web Push větev se nemaže. Je ověřená naživo a je to jediná cesta, která dnes
prokazatelně probudí ukončený proces, takže zůstává jako záloha za přepínačem
a je to i výchozí hodnota. Výchozí hodnota se překlopí na proxy až ve chvíli,
kdy proxy cesta zaregistruje skutečné zařízení — nasadit neověřenou výchozí
cestu by znamenalo vzít notifikace jediné platformě, kde dnes fungují.

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

### Co ještě chybí

Proxy cesta zatím **nic neregistruje**, protože aplikace nemá odkud vzít FCM
token — Firebase projekt ještě není zapojený. Bez tokenu naplánuje
`planNextPushEffect` nulu efektů (`runtime_effects.dart`, podmínka
`providerToken == null`), takže se nevytvoří ani klíč zařízení. Do zprovoznění
patří:

- FCM projekt, `google-services.json` a `FirebaseMessagingService`, který
  token předá do `installToken`,
- dešifrování doručeného `subject` privátním klíčem z Keystore a zobrazení
  notifikace,
- doplnění `release-licenses/components.tsv` o nové runtime závislosti,
  jinak `generateReleaseLicenseAssets` shodí release build.

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

## Jen Talk, nic jiného

Nextcloud posílá na registrované zařízení notifikace **všech** aplikací, ne
jen Talku, takže karta z Decku dorazí na stejný kanál jako zpráva. Pole `app`
v payloadu je proto brána: zobrazí se jen `spreed`. Payload bez `app` se za
Talk nepovažuje — nehádá se.
