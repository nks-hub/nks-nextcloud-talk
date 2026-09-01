# Audit závislostí a assetů

Datum poslední kontroly: 27. srpna 2026.

Tento dokument je průběžná distribuční brána pro projekt licencovaný pod
`GPL-3.0-or-later`. Evidence vychází z konkrétního lockfilu a licenčního souboru
staženého balíku; popis balíku nebo štítek na webu sám nestačí.

## Přímé runtime závislosti `talk_protocol`

<!-- markdownlint-disable MD013 -->

| Komponenta | Verze a integrita | Licence a notice | Použití | Stav |
| --- | --- | --- | --- | --- |
| [`punycoder`](https://pub.dev/packages/punycoder) | 0.3.0; SHA-256 `982734df864d9588eb13e28ac1c5a46b57e22117b3696032ac58739966cec190` v `packages/talk_protocol/pubspec.lock` | MIT; Copyright 2025 dropbear-software; notice musí zůstat v distribučních materiálech | RFC 3492/IDNA převod Unicode hostname na kanonický ASCII tvar | Kompatibilní s GPL-3.0-or-later; zdrojový balík a lokální LICENSE ověřeny |
| [`markdown`](https://pub.dev/packages/markdown) | 7.3.1; archive SHA-256 `ee85086ad7698b42522c6ad42fe195f1b9898e4d974a1af4576c1a3a176cada9` v `packages/talk_protocol/pubspec.lock`; lokální LICENSE SHA-256 `0aa335b5e036b9efbb35ad7a35835cd32e4eb656c08bfe040550a9f6fa84fcc7` | BSD-3-Clause; Copyright 2012, the Dart project authors; notice a disclaimer musí zůstat ve zdrojové i binární distribuci | GFM AST pro převod zprávy do vlastního bezpečného Rich Object semantic tree | Kompatibilní s GPL-3.0-or-later; zdrojový balík a lokální LICENSE ověřeny |
| [`xml`](https://pub.dev/packages/xml) | 7.0.1; archive SHA-256 `67f0aff7be013d107995e9b75bf4e7f2c3ef2dfdb2c8e68024bba0a7fd5756a4` v `packages/talk_protocol/pubspec.lock`; lokální LICENSE SHA-256 `0be767174b97278f17da4923a74169e8645631f03ea3d8482ec3523c9b1a0dd3` | MIT; Copyright 2006–2026 Lukas Renggli; notice musí zůstat ve všech podstatných kopiích | Namespace-aware WebDAV multistatus parser za vlastní UTF-8, DTD/entity a resource budget hranicí | Kompatibilní s GPL-3.0-or-later; zdrojový balík a lokální LICENSE ověřeny |

<!-- markdownlint-enable MD013 -->

## Přímé Flutter runtime závislosti

Následujících dvacet pět hostovaných balíků je přímo deklarovaných v
`apps/mobile/pubspec.yaml`. Verze a archive SHA-256 jsou z
`apps/mobile/pubspec.lock`; licence a jejich SHA-256 byly ověřené v odpovídajícím
staženém balíku v lokální Pub cache.

<!-- markdownlint-disable MD013 -->

| Komponenta | Verze a integrita | Licence a notice | Použití |
| --- | --- | --- | --- |
| [`app_badge_plus`](https://pub.dev/packages/app_badge_plus) | 1.3.4; archive SHA-256 `a22719127af1b80c6d5803fb80c02b600ceb14f726210c12b6198fe11b8bc025`; LICENSE SHA-256 `23f2a5ed6e28c323d4cfa58fb051da600c32d5fa715c11bdaefa629d8f656093` | MIT; Copyright 2024 LioLin | Nastavení počtu na unread badge ikony aplikace (Android/iOS/macOS); zvolen pro MIT licenci, aktivní údržbu a `isSupported()` API, díky kterému launcher bez podpory zůstane no-op |
| [`audioplayers`](https://pub.dev/packages/audioplayers) | 6.8.1; archive SHA-256 `2ba4bb2944baacbdd5372ff8254a8e7feb8c10d7739545e392f5605a8f618745`; LICENSE SHA-256 `d6c0bdbc83e6bb5f02eed5caf25e6edf174cb56d0ecd6fe19a2cd05b62bbda41` | MIT; Copyright 2017 Blue Fire | Přehrávání lokálně připravených hlasových zpráv |
| [`crypto`](https://pub.dev/packages/crypto) | 3.0.7; archive SHA-256 `c8ea0233063ba03258fbcf2ca4d6dadfefe14f02fab57702265467a19f27fadf`; LICENSE SHA-256 `ad6a71997da90924b2cfb1fb47ec46537f70faf469efe016168794ae45ed6888` | BSD-3-Clause; Copyright 2015, the Dart project authors | SHA-256 integrita durable kopie přílohy |
| [`cupertino_icons`](https://pub.dev/packages/cupertino_icons) | 1.0.9; archive SHA-256 `41e005c33bd814be4d3096aff55b1908d419fde52ca656c8c47719ec745873cd`; LICENSE SHA-256 `310d6ab6483280280c9db122bded0a63c09558bc5743720f61dbcbb494db370a` | MIT; Copyright 2016 Vladimir Kharlampidi | Cupertino icon font pro iOS vzhled |
| [`emojis`](https://pub.dev/packages/emojis) ([upstream](https://github.com/i-Naji/emojis)) | 3.2.0; archive SHA-256 `36d382349255a3d90a33fa5e01b57b5213578d90a493aad98d2955dac79df74f`; LICENSE SHA-256 `9f2d0499872d61cb552aad0fafa912711b0fd83f855ef3ce28f0359240f5ec2b` | BSD-3-Clause; Copyright 2020 Naji; notice a disclaimer musí zůstat ve zdrojové i binární distribuci | Úplný katalog Unicode 17.0 pro vyhledávání a kategorie emoji pickeru |
| [`file_selector`](https://pub.dev/packages/file_selector) | 1.1.0; archive SHA-256 `bd15e43e9268db636b53eeaca9f56324d1622af30e5c34d6e267649758c84d9a`; LICENSE SHA-256 `420f7739f169097f0aad1242045169cd643c8f1d94e62866fad265ae4c369b7d` | BSD-3-Clause; Copyright 2013 The Flutter Authors | Platformní výběr obrázkové přílohy |
| [`desktop_drop`](../../packages/desktop_drop/UPSTREAM.md) | Lokální desktop-only `0.8.3+nks.1`; upstream 0.8.3 archive SHA-256 `4c639b4cb80780d1cb94c3252309772e5e68522372181497bc9cd2fbd973aec1`; LICENSE SHA-256 `54bb187c3c4d8d9e74475f69b63a70798fb80581c334b2da487d1c4c70f68155` | Apache-2.0; upstream copyright a plný text zachovaný v balíku | Přetažení souboru do otevřené konverzace na macOS, Linuxu a Windows; Android/web targety jsou záměrně vynechané |
| [`flutter_riverpod`](https://pub.dev/packages/flutter_riverpod) | 2.6.1; archive SHA-256 `9532ee6db4a943a1ed8383072a2e3eeda041db5657cdf6d2acecf3c21ecbe7e1`; LICENSE SHA-256 `757d9c09a9a2a701144328c0fd596234ea287ff62952b39cd22f9ad4caed1171` | MIT; Copyright 2020 Remi Rousselet | Account-scoped application a UI state |
| [`http`](https://pub.dev/packages/http) | 1.6.0; archive SHA-256 `87721a4a50b19c7f1d49001e51409bddc46303966ce89a65af4f4e6004896412`; LICENSE SHA-256 `3c32b53167c7dae9190c38dab5dd9fe1789c53623ebc7d1babcb29914c5b3f16` | BSD-3-Clause; Copyright 2014, the Dart project authors | Nextcloud HTTP transport |
| [`mime`](https://pub.dev/packages/mime) | 2.0.0; archive SHA-256 `41a20518f0cb1256669420fdba0cd90d21561e560ac240f26ef8322e45bb7ed6`; LICENSE SHA-256 `ff15faa32a2e638107b7789592b14426162a75ba620044ee2340a20ec6ce5e73` | BSD-3-Clause; Copyright 2015, the Dart project authors | Ověření MIME typu vybrané přílohy |
| [`path`](https://pub.dev/packages/path) | 1.9.1; archive SHA-256 `75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5`; LICENSE SHA-256 `3c32b53167c7dae9190c38dab5dd9fe1789c53623ebc7d1babcb29914c5b3f16` | BSD-3-Clause; Copyright 2014, the Dart project authors | Bezpečná práce s názvy a cestami durable příloh |
| [`path_provider`](https://pub.dev/packages/path_provider) | 2.1.6; archive SHA-256 `a7f4874f987173da295a61c181b8ee71dab59b332a486b391babf26a1b884825`; LICENSE SHA-256 `420f7739f169097f0aad1242045169cd643c8f1d94e62866fad265ae4c369b7d` | BSD-3-Clause; Copyright 2013 The Flutter Authors | Aplikační adresář pro durable kopie médií |
| [`record`](https://pub.dev/packages/record) | 7.1.1; archive SHA-256 `82539d1372e23cf51375fdfcba084f39912bcbf9a953b75d56596691f8f11c0f`; LICENSE SHA-256 `5a21ee0d2585baccfde18aeb045037701172460213db723e9d189ca1922aaf79` | BSD-3-Clause; Copyright 2022 openapi4j authors, jak uvádí balík | Platformní záznam hlasové zprávy |
| [`url_launcher`](https://pub.dev/packages/url_launcher) | 6.3.2; archive SHA-256 `f6a7e5c4835bb4e3026a04793a4199ca2d14c739ec378fdfe23fc8075d0439f8`; LICENSE SHA-256 `89519eca6f7b9529b35bdddd623a58c3af06a88c458dbd6531ddb4675acf75a9` | BSD-3-Clause; Copyright 2013 The Flutter Authors | Systémové otevření Login Flow a bezpečných odkazů |
| [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage) | 11.0.0; archive SHA-256 `15e8c8fe269fdf7d469b23008ab3df521c8b826ed345820532364c31bdebace6`; LICENSE SHA-256 `55dafb084270616f95b9bea53654adda8bdcad95c022a83c4cf8769073f829fa` | BSD-3-Clause; Copyright 2017 German Saprykin | Keystore/Keychain-backed uložení app passwordu |
| [`flutter_svg`](https://pub.dev/packages/flutter_svg) | 2.3.0; archive SHA-256 `35882981abcbfb8c15b286f0cd690ff25bac12d95eff3e25ee207f37d4c42e7f`; LICENSE SHA-256 `dc54ae36c905edfbf3c6678ee34d8da5989d7ccc7b993857a9d89db06a67eb18` | MIT; Copyright 2018 Dan Field | Bezpečné zobrazení podporovaných SVG médií |
| [`drift`](https://pub.dev/packages/drift) | 2.34.3; archive SHA-256 `3a3f1f6f905037d7426e4c445854139fd6a3d592135f7c96d7931682b73d16f4`; LICENSE SHA-256 `31f84e4edff98f0238a5bef1c2ce754e401fbab149782f0ff4dc9b68fd086f75` | MIT; Copyright 2021 Simon Binder | Typované account-scoped SQLite repository a transakce |
| [`drift_flutter`](https://pub.dev/packages/drift_flutter) | 0.3.1; archive SHA-256 `91acf4bee7c3c84467cba46455aa70e5292a3b889f4582645d74f2e5a8c106f2`; LICENSE SHA-256 `7cf86321e740e4ff631ab6d00962c2d65fa85e4163bdd89334f1d22354ab0306` | MIT; Copyright 2024 Simon Binder | Flutter platformní otevření Drift databáze |
| [`uuid`](https://pub.dev/packages/uuid) | 4.6.0; archive SHA-256 `9b129329f58692f6e6578329498a8fe9fbe98f090beb764ffbb8ee2eadd01dcd`; LICENSE SHA-256 `ad3e5523e51004e94ba9ce728805b1b4242dbccdb65e62b523800e35a8a7cfdc` | MIT; Copyright 2021 Yulian Kuncheff | Náhodné lokální account a operation identity |
| [`connectivity_plus`](https://pub.dev/packages/connectivity_plus) | 7.3.1; archive SHA-256 `762c99f890ca8bf87f7337236f99edd42793843bc6c3631da294a76653a54bd0`; LICENSE SHA-256 `3b38d48befd0af70b892e13d10c9e34679416c24a9277f962629951c64d71f4c` | BSD-3-Clause; Copyright 2017 The Chromium Authors | Rozpoznání návratu konektivity jako wake source pro polling a resync |
| [`open_filex`](https://pub.dev/packages/open_filex) | 4.7.0; archive SHA-256 `9976da61b6a72302cf3b1efbce259200cd40232643a467aac7370addf94d6900`; LICENSE SHA-256 `15fead662602c03b70cedc27bb301ca0722648fbc222dd3d7d06d9dd3c3fc2ad` | BSD-3-Clause; Copyright 2018 crazecoder | Otevření již stažené přílohy v systémové aplikaci přes Android FileProvider |
| [`gal`](https://pub.dev/packages/gal) | 2.3.3; archive SHA-256 `f71e79840fe023a21f2f949771375444b6efcd34b9e625d5f4f5504971380a77`; LICENSE SHA-256 `4a963156383f276c9214aed3beee1a57e12947c63b58dae134fdae6abd01b3da` | MIT; Copyright 2023 Midori Design Studio | Uložení přílohy do systémové galerie (MediaStore, PHPhotoLibrary) |
| [`share_plus`](https://pub.dev/packages/share_plus) | 13.3.0; archive SHA-256 `34f00f9becd2743c1fb05363d624f9f70d37f7ccdcdda47450bc0b8c9d327b8c`; LICENSE SHA-256 `eb9741a672906ebd01fd9b3bef38f6c82eff250e91149cf404539ee7981079fd` | BSD-3-Clause; Copyright 2017, the Flutter project authors | Systémový share sheet (ACTION_SEND, UIActivityViewController) |
| [`image_picker`](https://pub.dev/packages/image_picker) | 1.2.3; archive SHA-256 `d8402284df184bc05f4a2210c6c23983b0720f4cd87cbd05c5390a78af602667`; LICENSE SHA-256 `8e22fae63e4e8ac897f0cb3018ed94ed730b3e5da5d42c6856a26ba524f0fd88` | BSD-3-Clause; Copyright 2013 The Flutter Authors | Pouze zdroj „fotoaparát“ (ACTION_IMAGE_CAPTURE, UIImagePickerController) |
| [`sentry_flutter`](https://pub.dev/packages/sentry_flutter) | 9.27.0; archive SHA-256 `ec89cc6ba939ca19155ea83900d9740a36544f50b3b6baf265518e3348fb0f50`; LICENSE SHA-256 `a324d0c2ce63dbdce9e77cbd06a13ad77006d6bf3f82ad3affe03b64e27e83d6` | MIT; Copyright 2019 Sentry | Hlášení pádů pouze v našich buildech; bez `SENTRY_DSN` se SDK vůbec neinicializuje |
| [`rybbit_flutter_sdk`](https://pub.dev/packages/rybbit_flutter_sdk) | 0.3.0; archive SHA-256 `96581119b39b195690b4cd9a88283293d0bd7efc82aefce817750ec7924761fe`; LICENSE SHA-256 `e57f1c320b8cf8798a7d2ff83a6f9e06a33a03585f6e065fea97f1d86db84052` | GPL-3.0; Copyright Free Software Foundation text, vlastní kód nks-hub; shodná licence jako projekt | Anonymní použití obrazovek pouze v našich buildech; bez `RYBBIT_HOST` a `RYBBIT_SITE_ID` se SDK vůbec neinicializuje |

<!-- markdownlint-enable MD013 -->

Všechny uvedené licence jsou permisivní a kompatibilní s distribucí aplikace
pod `GPL-3.0-or-later`; jejich copyright notice a disclaimer musí zůstat ve
výsledném third-party notice.

Tabulka je úplná pro aktuální přímé hostované Flutter balíky. Android release
artefakt je navíc pokrytý automatickou bránou popsanou níže. Pro iOS musí stejná
artefaktová evidence teprve vzniknout; tento stav proto ještě není úplná
multi-platform release clearance.

Přímé SDK závislosti `flutter` a `flutter_localizations` jsou z Flutter 3.44.4,
revision `ad70ec4617166f1c38e5d2bfd388af71fda14f06`. Kořenový Flutter `LICENSE`
je BSD-3-Clause se SHA-256
`a3a9fd82f800a47377f7d3f60c60a5c91cae0495be8f329031e1448ce0f5dab9`.
`talk_protocol` je interní workspace balík pod stejnou projektovou licencí, ne
cizí distribuční závislost.

## Přímé Android runtime závislosti pro Web Push

Následující artefakty jsou z aktuálního `debugRuntimeClasspath`. SHA-256 patří
skutečně staženému AAR/JAR v lokální Gradle cache; SHA-256 licence patří souboru
na přesném upstream tagu.

<!-- markdownlint-disable MD013 -->

| Komponenta | Verze a integrita | Licence a notice | Použití | Stav |
| --- | --- | --- | --- | --- |
| [`org.unifiedpush.android:connector`](https://codeberg.org/UnifiedPush/android-connector/src/tag/3.3.5) | 3.3.5; tag/commit `04820c8cfe11fe283da50c1a990529fb167eac9d`; AAR SHA-256 `fa017cdfabbdc9af021e1f8c8eff2c8098e701d7a2c599937dce0b4ecf1e929b`; tag LICENSE SHA-256 `65e7ce63d83ef0a5aa7b8a568f0524b7d0943179257f4ba086c4a126d57f08fa` | Apache-2.0; Maven POM a tag LICENSE se shodují | UnifiedPush registrační a callback API | Kompatibilní s GPL-3.0-or-later; zachovat Apache licenci a notices |
| [`org.unifiedpush.android:embedded-fcm-distributor`](https://codeberg.org/UnifiedPush/android-embedded_fcm_distributor/src/tag/3.1.0) | 3.1.0; AAR SHA-256 `a2e730e33c54a5d59141ac6657b6969375c91e27f64ae9299fab2275e4707291`; tag LICENSE SHA-256 `620e35bd6e6066ee0376391296ff595459584fe135853d8f60434d38693f06cb` | Tag obsahuje plný LGPL-2.1 text, zatímco publikovaný Maven POM odlišně deklaruje Apache-2.0 | Vestavěné získání FCM Web Push endpointu bez druhé aplikace | LGPL text není sám o sobě v konfliktu s GPL-3.0-or-later, ale před release je povinný explicitní notice, corresponding-source/relink audit a vyřešení rozporu metadat; nelze jej zatím evidovat jako Apache-2.0 |
| [`com.google.crypto.tink:tink`](https://github.com/tink-crypto/tink-java/tree/v1.23.0) | 1.23.0; tag/commit `7d41a6435667e6ec543e49ac544ff599b72601c9`; JAR SHA-256 `5bcdc8798ce106f5145acb4a0e993c5e5861337b1e75ca88ceb6ab9da10fa512`; tag LICENSE SHA-256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` | Apache-2.0 | Transitivní Web Push kryptografie connectoru | Kompatibilní s GPL-3.0-or-later; zachovat Apache licenci a notices |

<!-- markdownlint-enable MD013 -->

`flutter_secure_storage` 11.0.0 přivádí nepoužitý `tink-android` 1.23.0. Jeho
třídy se překrývají s Tink Core 1.23.0 vyžadovaným connectorem a sestavení by
selhalo na duplicitních třídách. Aplikační Gradle konfigurace proto vylučuje jen
`tink-android`; aktuální dependency graph potvrzuje jediný Tink Core 1.23.0.
Zdroj Android části `flutter_secure_storage` Tink API neimportuje.

Další transitivní JVM závislosti connectoru (`gson`, `protobuf-java`, `jsr305`,
Error Prone annotations) jsou pokryté přesným Android release classpathem,
CycloneDX SBOM a notice vloženým do APK. Samotná přítomnost LGPL textu ale
nenahrazuje finální corresponding-source/relink clearance distributora.

## Android release artefaktová brána

Commit `94a0987` přidal fail-closed generování z přesného
`releaseRuntimeClasspath` a `pubspec.lock`. Každý Maven artefakt musí být v
`release-licenses/components.tsv`, každý Pub balík musí být buď v generovaném
Flutter `NOTICES.Z`, nebo v samostatném manifestu, a každý ručně dodaný notice
je svázaný SHA-256. Build vloží do release APK CycloneDX 1.6 `SBOM.json` a
`THIRD_PARTY_NOTICES.txt`; finalizer `assembleRelease` znovu otevře skutečný APK
a ověří úplnost, SPDX identifikátory, duplicity, integritu notice i shodu s
plugin metadata.

Commit `105302e` navíc váže Gradle task na obsah `android-classes-jar` i přesné
Maven souřadnice runtime graphu. Přidání nebo změna závislosti tak invaliduje
vygenerované assety i při nezměněném manifestu. Regresní běh nejdřív prokázal
fail-closed chybějící `play-services-location:21.2.0`, poté invalidaci umělou
změnou graphu a nakonec dva správné `UP-TO-DATE` běhy stabilního graphu.

Build 33 prošel se 145 Flutter balíky a 112 Android runtime komponentami.
Validator má 17/17 unit testů, `bundleRelease` prošel 721 tasky a vložený SBOM
obsahuje `pkg:maven/com.google.android.gms/play-services-location@21.2.0`.
Brána je Android-only; iOS artefakt a jeho nativní dependency graph zatím
nepokrývá.

## Transitivní runtime závislosti

<!-- markdownlint-disable MD013 -->

| Komponenta | Verze a integrita | Licence a notice | Důvod v artefaktu | Stav |
| --- | --- | --- | --- | --- |
| [`petitparser`](https://pub.dev/packages/petitparser) | 7.0.2; archive SHA-256 `91bd59303e9f769f108f8df05e371341b15d59e995e6806aefab827b58336675` v `packages/talk_protocol/pubspec.lock`; lokální LICENSE SHA-256 `d2e8ffdbe89acbc10d5d1f2b03e7dbddf0a9f1742e809176682b62ef3d573b3e` | MIT; Copyright 2006–2024 Lukas Renggli; notice musí zůstat ve všech podstatných kopiích | Parser runtime vyžadovaný balíkem `xml`; projekt jej přímo nevolá | Kompatibilní s GPL-3.0-or-later; zdrojový balík a lokální LICENSE ověřeny |
| [`sentry`](https://pub.dev/packages/sentry) | 9.27.0; archive SHA-256 `c2ecd8abe82e63cdcb6947f71320612ced56e10ba94db7529d85cc02be47cb3b`; lokální LICENSE SHA-256 `9873d81def9cebb9598b4a2d0a1ad062b17781c35c25cc04b75a0f62fc8667fd` | BSD-3-Clause; Copyright 2014 The Chromium Authors | Dart jádro vyžadované balíkem `sentry_flutter`; projekt jej volá jen přes něj | Kompatibilní s GPL-3.0-or-later; zdrojový balík a lokální LICENSE ověřeny |
| [`hive`](https://pub.dev/packages/hive) | 2.2.3; archive SHA-256 `8dcf6db979d7933da8217edcec84e9df1bdb4e4edc7fc77dbd5aa74356d6d941`; lokální LICENSE SHA-256 `343c59f5d64c33a9dad6c7a87d9b4b1c3c6ce628f41b85d9e25ef5f960b8f28e` | Apache-2.0; jednosměrně kompatibilní s GPL-3.0-or-later | Offline fronta balíku `rybbit_flutter_sdk` pro události odeslané bez konektivity | Kompatibilní s GPL-3.0-or-later; zdrojový balík a lokální LICENSE ověřeny |
| [`device_info_plus`](https://pub.dev/packages/device_info_plus) | 13.2.0; archive SHA-256 `0891702f96b2e465fe567b7ec448380e6b1c14f60af552a8536d9f583b6b8442`; lokální LICENSE SHA-256 `3b38d48befd0af70b892e13d10c9e34679416c24a9277f962629951c64d71f4c` | BSD-3-Clause; Copyright 2017 The Chromium Authors | Model zařízení a verze OS v analytics payloadu balíku `rybbit_flutter_sdk` | Kompatibilní s GPL-3.0-or-later; zdrojový balík a lokální LICENSE ověřeny |
| [`package_info_plus`](https://pub.dev/packages/package_info_plus) | 10.2.1; archive SHA-256 `127e1751e37ffb2ff4658beeaca77bad0c27bf5f932bd3a501c2296926d4b481`; lokální LICENSE SHA-256 `3b38d48befd0af70b892e13d10c9e34679416c24a9277f962629951c64d71f4c` | BSD-3-Clause; Copyright 2017 The Chromium Authors | Verze aplikace v analytics payloadu; verze je vynucená `dependency_overrides` v `apps/mobile/pubspec.yaml`, protože `rybbit_flutter_sdk` 0.3.0 zastropuje major 9 a tím i `win32` pod 6, který `share_plus` 13.3 vyžaduje. SDK z balíku volá jen `PackageInfo.fromPlatform()`, nezměněné napříč majory 8–10 | Kompatibilní s GPL-3.0-or-later; zdrojový balík a lokální LICENSE ověřeny |

<!-- markdownlint-enable MD013 -->

## Vývojové závislosti

<!-- markdownlint-disable MD013 -->

| Komponenta | Verze a integrita | Licence a notice | Rozsah |
| --- | --- | --- | --- |
| [`build_runner`](https://pub.dev/packages/build_runner) | 2.15.1; archive SHA-256 `5367e521935b102bdf1e735d2aab461e36b2edca6517662d088dd04cc39f8d16`; LICENSE SHA-256 `a4b5d7d31626e90b77e8696f1c47643aa31f52e17c1907c1ab60b068110e6e10` | BSD-3-Clause; Copyright 2016, the Dart project authors | Generování Drift kódu; není runtime dependency |
| [`drift_dev`](https://pub.dev/packages/drift_dev) | 2.34.5; archive SHA-256 `735aad3c34215805c66bd518c8812fa4f83b5534b2c13c4092c970c04a7e9983`; LICENSE SHA-256 `31f84e4edff98f0238a5bef1c2ce754e401fbab149782f0ff4dc9b68fd086f75` | MIT; Copyright 2021 Simon Binder | Drift build-time generátor; není runtime dependency |
| [`flutter_lints`](https://pub.dev/packages/flutter_lints) | 6.0.0; archive SHA-256 `3105dc8492f6183fb076ccf1f351ac3d60564bff92e20bfc4af9cc1651f4e7e1`; LICENSE SHA-256 `89519eca6f7b9529b35bdddd623a58c3af06a88c458dbd6531ddb4675acf75a9` | BSD-3-Clause; Copyright 2013 The Flutter Authors | Statická pravidla; není runtime dependency |

<!-- markdownlint-enable MD013 -->

`flutter_test` pochází ze stejného Flutter SDK a v aplikaci je pouze dev
závislost. `lints` 6.1.0 a `test` 1.31.2 z `talk_protocol` používají
BSD-3-Clause licenci Dart projektu; přesné transitivní verze drží příslušný
lockfile.

## Nástroj pro pixelovou evidenci

`apps/mobile/tool/requirements.txt` přesně připíná `Pillow==12.1.0`, ale zatím
neobsahuje hash pin. Ověřený PyPI wheel
`pillow-12.1.0-cp312-cp312-win_amd64.whl` má SHA-256
`d70534cea9e7966169ad29a903b99fc507e932069a881d0965a1a84bb57f6c6d`.
Jeho metadata deklarují `MIT-CMU`; přiložený `LICENSE` má SHA-256
`926df5f888a7337fd4126a435202edf2847312be81a167df91a6d70cfa3f2ed3`
a zachovává notices PIL, Secret Labs, Fredrika Lundha a Pillow contributorů.
Pillow slouží jen host-side screenshot/WCAG harnessu a není součástí mobilního
ani desktopového runtime artefaktu.

## Nástroje executable kontraktů

`contracts/push-client` znovu používá stejné přesně připnuté Python nástroje
jako existující `contracts/push-gateway`; nepřidává mobilní runtime závislost.
Lokálně nainstalovaná metadata 23. srpna 2026 potvrzují:

- `cryptography` 50.0.0: `Apache-2.0 OR BSD-3-Clause`;
- `jsonschema` 4.26.0: `MIT`;
- `openapi-spec-validator` 0.9.0: `Apache-2.0`.

Tyto balíky slouží pouze lokálnímu a CI generování a ověření syntetických
fixture. Nejsou součástí budoucího Android/iOS artefaktu. Jejich přesné verze
jsou v `contracts/push-client/requirements.txt` a
`contracts/push-gateway/requirements.txt`. Čistá instalace obou shodných sad a
`pip-audit` 23. srpna 2026 nenašly známou zranitelnost. Release notice se bude
tvořit z finálních distribuovaných artefaktů, nikoli z globálního Python
prostředí.

## Assety a převzatý kód

Nebyl přidán žádný obrázek, font, zvuk ani implementační kód z oficiálních Talk
klientů. Platformní scaffold ale obsahuje standardní Flutter assety, které je
nutné evidovat:

- všech 31 PNG/ICO ikon a launch image v Android, iOS, macOS a Windows targetu
  je podle SHA-256 byte-for-byte shodných se zdrojem ve Flutter SDK 3.44.4 nebo
  v jeho přesně připnutém balíku `flutter_template_images` 5.0.0;
- `flutter_template_images` 5.0.0 má archive SHA-256
  `0120589a786dbae4e86af1f61748baccd8530abd56a60e7a13479647a75222fe`
  a BSD-3-Clause `LICENSE` SHA-256
  `89519eca6f7b9529b35bdddd623a58c3af06a88c458dbd6531ddb4675acf75a9`;
- Android launch XML, iOS storyboard a ostatní generated platformní soubory
  pocházejí ze stejné Flutter template revision, nikoli z Talk klientů;
- zdrojový `CupertinoIcons.ttf` z `cupertino_icons` má SHA-256
  `67c44fe9183b002e79dde7f6977e2988661c9a3e4a3c5fce968787efdbed823c`
  a řídí se MIT licencí balíku uvedenou výše;
- `uses-material-design: true` používá SDK zdroj `MaterialIcons-Regular.otf` se
  SHA-256
  `d9865b671a09d683d13a863089d8825e0f61a37696ce5d7d448bc8023aa62453`;
  přiložený CC-BY-4.0 text má SHA-256
  `be698262aecd042c0de6f886cc0af622f8def446462026992cc530275d8a9e74`
  a jeho atribuční podmínky musí release notice zachovat.

Vlastní značka je kreslená aplikačním kódem a nepřidává samostatný binární
asset. Debug/release build může nepoužité ikony nebo font glyphy tree-shakovat;
skutečný obsah a notices se proto znovu odvodí z finálních artefaktů. Kořenový
GPL text se nemění.

## Brána pro další změny

Každá nová přímá závislost nebo asset musí před commitem doložit:

1. přesnou verzi a integritu z lockfilu;
2. celý licenční text z reálně staženého artefaktu;
3. GPL kompatibilitu a povinný copyright/notice;
4. zda je součástí distribuovaného runtime, pouze build nástroj, nebo dev test;
5. původ assetu a povolené úpravy nebo redistribuci.

Před release se z finálního Android a iOS artefaktu vytvoří úplný third-party
notice. Tento průběžný soubor nenahrazuje kontrolu transitive runtime závislostí
ani výsledného binárního balíku.
