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

## Postup

```sh
flutter config --no-enable-swift-package-manager
rm -rf ios/Flutter/ephemeral
flutter build ios --release --no-codesign

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

## Zbývá

- `MinimumOSVersion` je 13.0; od jara 2027 Apple vyžaduje 15.0.
- macOS distribuce: buď Mac App Store, nebo Developer ID Application
  s notarizací přes `notarytool` a staplingem.
- `macos/Runner/Release.entitlements` má jen
  `files.user-selected.read-only`; ukládání příloh bude potřebovat
  read-write.
- Apple push vrstva v repozitáři vůbec není.
