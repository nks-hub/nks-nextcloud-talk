# Apple distribuce

Podepsaný iOS build se staví na build-mac přes RemoteCmd. Tenhle dokument je
záznam funkčního postupu a hlavně čtyř blokád, které cestou padly — každá
z nich se tvářila jako něco jiného, než čím byla.

## Účet a identita

- Tým `TEAMID0000`. Na `developer.apple.com` je nutné přihlášení jako
  **account holder**; běžný ASC Admin na portál týmu nevidí.
- App ID `com.nkshub.nextcloudtalk` („NKS Talk") s capability Push
  Notifications.
- App Store Connect záznam id `6805831712`, platformy iOS i macOS.
- `DEVELOPMENT_TEAM = TEAMID0000` je v `ios/Runner.xcodeproj` a
  v `macos/Runner/Configs/AppInfo.xcconfig`.
- Aktualizovanou Apple Developer Program License Agreement musí odsouhlasit
  account holder ručně. Dokud to neudělá, nejde odeslat nic nového.

## Universal Links

Runner má `com.apple.developer.associated-domains` pro
`applinks:cloud.example.invalid`. Autoritativní AASA dokument je verzovaný v
`deploy/reference-server/apple-app-site-association`; povoluje pouze
`/call/*` a `/index.php/call/*` pro
`TEAMID0000.com.nkshub.nextcloudtalk`.

Referenční server jej servíruje exact-path Apache aliasem z Git checkoutu
commitu `2f1d36f`, ne ručně vloženým souborem v Nextcloud webrootu. Veřejná
kontrola 1. září 2026 vrátila 200, `application/json`, 419 B, žádný redirect a
SHA-256 `0e3b890f8f0d38878f520fa63f8822a50ba31837e1a76a5cbab707d0c8f78e68`.
Apple developer fetch vrací stejný dokument. Produkční Apple CDN v té chvíli
ještě držela předchozí 404; TestFlight/runtime Universal Link se nesmí označit
za hotový, dokud cache neobnoví a přímý odkaz neotevře room bez Safari.

## Postup

```sh
flutter config --no-enable-swift-package-manager
flutter clean
flutter pub get
flutter build ios --release --no-codesign --build-number <build> \
  --dart-define-from-file=telemetry.env

xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath <archiv> archive \
  -allowProvisioningUpdates \
  -authenticationKeyPath <p8> -authenticationKeyID <id> \
  -authenticationKeyIssuerID <issuer> \
  DEVELOPMENT_TEAM=TEAMID0000

xcodebuild -exportArchive -archivePath <archiv> \
  -exportOptionsPlist <plist s method=app-store-connect> \
  -exportPath <out> -allowProvisioningUpdates <klíč jako výše>

xcrun altool --upload-app -t ios -f "<out>/NKS Talk.ipa" \
  --apiKey <id> --apiIssuer <issuer>
```

Celé to musí běžet jako přihlášený uživatel, ne jako root:
`launchctl asuser <uid> sudo -u <user> <skript>`.

## Blokády, na které se dá narazit znovu

1. **Cíle pluginů přes Swift Package Manager ignorují `DEVELOPMENT_TEAM`
   z příkazové řádky.** Projeví se jako `Signing for "<plugin>" requires
   a development team` pro každý plugin zvlášť. Řeší přepnutí na CocoaPods,
   ty tým z příkazové řádky přebírají.
2. **`conflicting code signing identity`.** Nepřipínat `CODE_SIGN_IDENTITY`
   proti automatickému podepisování; předat jen tým.
3. **`The specified item could not be found in the keychain`.** Build běžel
   jako root, ale privátní klíč certifikátu je v login keychainu uživatele.
4. **`Permission denied` při čtení `~/.pub-cache`.** Root tam předtím zapsal
   soubory; vrátit vlastnictví uživateli.
5. **Xcode ukazuje iOS SDK, ale `Any iOS Device` je ineligible.** Na Xcode
   26.3 s macOS 15.7.4 po odebrání runtime 26.2 zůstal
   `iphoneos26.2.sdk`, přesto archive hlásil `iOS 26.2 is not installed`.
   `xcodebuild -downloadPlatform iOS` stáhl nejnovější 26.3.1, který tuto
   přesnou závislost nenahradil, a historickou verzi už standardní katalog
   nenabízel. Ověřená obnova používá `xcodes runtimes` a jednoznačný runtime
   build: `xcodes runtimes install 23C54 --architecture arm64`. Po registraci
   `xcodebuild -showdestinations` znovu nabídl `Any iOS Device`. Dočasný
   `xcodes` i chybný runtime 26.3.1 se po buildu odstranily; 26.2 zůstává jako
   nutná součást toolchainu.

## Past, která stojí za samostatnou zmínku

`UPLOAD SUCCEEDED` z `altool` **není** důkaz, že build dorazil do
TestFlightu. Znamená jen, že binárka doputovala k Apple. Validace běží až
potom a její výsledek je vidět v App Store Connect pod *TestFlight → Build
Uploads* jako `Processing`, `Failed` nebo `Valid`, případně v API jako
`processingState`.

Dvě nahrání takhle skončila jako `Failed` s

> `90683: Missing purpose string in Info.plist` — chybí
> `NSPhotoLibraryUsageDescription`

přestože upload hlásil úspěch. Proto `apps/mobile/test/ios_app_icon_metadata_test.dart`
kontroluje všechny purpose stringy proti pluginům, které je potřebují,
i `CFBundleIconName`: příští chybějící klíč má být padající test, ne
zamítnutý upload.

Hlásit „je to v TestFlightu" se smí až podle stavu záznamu, ne podle
výstupu uploadu.

## Ověření buildu 25

Build 25 vznikl 2026-08-31 z přesného commitu `175b721`. Archive i export
prošly, IPA má SHA-256
`9D8D42A57FF74F076FC82D2F64656683CBC6DFBCB9A1047CF7A5E091F1CDE485`.
App Store Connect API následně potvrdilo `processingState=VALID`,
`usesNonExemptEncryption=false` a minimum iOS 15.0. Build má české poznámky,
beta review je schválené a interní i externí skupina hlásí
`IN_BETA_TESTING`.

## Ověření buildu 26

Build 26 vznikl 2026-08-31 z přesného commitu `3dd373e`. Android Publishing
API přijalo `versionCode=26`, commitnulo uzavřený `alpha` track a nový edit
vrací `(26) 0.1.0` ve stavu `completed`. AAB má SHA-256
`034D499C55CA61BAAABCB1A46484094DBC3736843675781B90C5242AE7FEED49`.

iOS archive i export prošly po obnovení runtime 26.2. IPA má SHA-256
`40716A6719562217DE9F3798306C695E4F173BCDD28EB7EA53AEE6E87479801D`.
App Store Connect API potvrdilo `processingState=VALID`, minimum iOS 15.0,
`usesNonExemptEncryption=false`, české poznámky a
`internalBuildState=externalBuildState=IN_BETA_TESTING`. Stejný bundle se
spustil na zachovaném iPhone 16 Pro Max / iOS 18.6 simulátoru jako build 26;
účet zůstal přihlášený a po serverovém refreshi zmizely všechny dočasné room
fixture.

Po ověření se z build-mac odstranil 1,7GB build strom, dočasný nástroj `xcodes`,
chybný runtime 26.3.1 a nepoužívané tvOS, watchOS a visionOS runtime. Zůstaly
jen nutné iOS 18.6 a iOS 26.2 a 41 GiB volného místa.

## Ověření buildu 31

Build 31 vznikl 2026-09-01 z přesného commitu `5c52469` s telemetrickými
define pro Sentry i Rybbit. Archive, export a `altool` upload prošly; IPA má
29 724 195 B a SHA-256
`<fingerprint>`.
App Store Connect API potvrdilo `processingState=VALID`, minimum iOS 15.0,
`usesNonExemptEncryption=false`, české poznámky a interní i externí skupinu
`IN_BETA_TESTING`; beta review je `APPROVED`.

Stejný commit prošel na zachovaném iOS 18.6 simulátoru s reálným PHPicker
assetem i starším vyčerpaným `retryable` jobem bez timeru. Novější upload
skončil `completed`, starší job zůstal pro ruční řešení a serverový context
request potvrdil vytvořenou zprávu. Testovací zprávy a lokální fixture byly po
důkazu odstraněné.

## Ověření buildu 32

Build 32 vznikl 2026-09-01 z přesného commitu `a2cd037` s telemetrickými
define pro Sentry i Rybbit. Archive, export a `altool` upload prošly; IPA má
29 760 109 B a SHA-256
`<fingerprint>`.
App Store Connect API potvrdilo `processingState=VALID`, minimum iOS 15.0,
`usesNonExemptEncryption=false`, přesnou českou poznámku, obě skupiny
`IN_BETA_TESTING` a beta review `APPROVED`.

Stejný commit se aktualizačně nainstaloval na zachovaný iPhone 16 Pro Max /
iOS 18.6 simulátor. Účet zůstal přihlášený; runtime ukázal sponku, Giphy,
emoji, mikrofon a Odeslat od levého okraje, capability-bound Anketu, skutečný
seznam konverzací pod interaktivním edge swipe a tři stejná vlákna po dvou
pull-refresh gestech. Po ověření se odstranily archive, export, build,
DerivedData, logy i screenshoty; data simulátoru zůstala zachovaná.

## Export compliance

Build s `usesNonExemptEncryption = null` visí v TestFlightu jako **Missing
Compliance** a nejde předat testerovi. iOS build používá systémové HTTPS,
Keychain a platformní push API, ne vlastní neosvobozenou kryptografii.
Odpověď je tedy `false` a je natrvalo v `Info.plist` jako
`ITSAppUsesNonExemptEncryption`, takže se otázka u dalších buildů neobjeví.
Existující build se dá dorovnat i přes API:

```http
PATCH /v1/builds/<id>  {"data":{"type":"builds","id":"<id>",
  "attributes":{"usesNonExemptEncryption":false}}}
```

Pokud aplikace někdy dostane vlastní šifrování (třeba E2EE hovorů), tohle
tvrzení přestane platit a musí se přehodnotit.

## Zbývá

- macOS distribuce: buď Mac App Store, nebo Developer ID Application
  s notarizací přes `notarytool` a staplingem.
- `macos/Runner/Release.entitlements` má jen
  `files.user-selected.read-only`; ukládání příloh bude potřebovat
  read-write.
- PushKit, CallKit a ReplayKit pro plnou paritu hovorů zůstávají samostatný
  otevřený řez.
