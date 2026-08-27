# Telemetrie

Klient hlásí pády a anonymní použití obrazovek do vlastní self-hosted Sentry
a Rybbit instance. Rozsah je záměrně užší, než co obě SDK umí; tento dokument
je závazný popis toho, co smí opustit zařízení.

## Zapnuto jen v našich buildech

Konfigurace přichází výhradně přes `--dart-define`, nikdy ze souboru, který
aplikace čte za běhu, a nikdy z repozitáře — DSN i Rybbit host jsou interní
adresy a tento repozitář je veřejný.

```sh
cp apps/mobile/telemetry.env.example apps/mobile/telemetry.env
flutter build apk --dart-define-from-file=telemetry.env
```

`telemetry.env` je v `.gitignore`. Build bez tohoto souboru dostane prázdné
hodnoty a pak se **žádné SDK vůbec neinicializuje**: `TelemetryConfig`
v `apps/mobile/lib/core/telemetry.dart` vyžaduje u Sentry DSN ve tvaru URL
a u Rybbitu zároveň host i site id. To je výchozí stav pro kohokoli, kdo si
klient sestaví proti vlastnímu Nextcloudu — jde o obecného multi-server
klienta, ne o white-label aplikaci, takže cizí build nesmí hlásit k nám.

| Proměnná | Význam | Prázdná hodnota |
| --- | --- | --- |
| `SENTRY_DSN` | DSN self-hosted Sentry | bez hlášení pádů |
| `RYBBIT_HOST` | adresa Rybbit instance | bez analytiky |
| `RYBBIT_SITE_ID` | site id v Rybbitu | bez analytiky |
| `TELEMETRY_ENVIRONMENT` | odliší testovací build od produkce | `development` |

## Co se posílá

- **Pády a chyby bez obsahu.** Stack trace a typ výjimky. Každý text projde
  `TelemetryScrubber`: absolutní URL se zkrátí na `schéma://<host>`, takže
  zmizí i server i room token v `…/call/<token>`, a cokoli ve tvaru
  `Authorization:`, `Bearer …` nebo `Basic …` se nahradí `<redacted>`.
  `SentryEvent.request` se zahazuje celý.
- **Anonymní použití obrazovek.** Jen jména rout (`/settings`,
  `/conversation/details`, …) z `RouteSettings`. Žádné id účtu, room token ani
  název konverzace se do jména routy nedostane.
- **Náhodné id instalace.** 128 bitů z `Random.secure()` v souboru
  `telemetry_installation_id.txt` vedle ostatních lokálních předvoleb. Není
  odvozené z účtu, serveru ani vlastnosti zařízení, takže ho nelze spojit
  s osobou ani s tím, jaký Nextcloud kdo používá. Přežije restart, ne
  přeinstalaci.

Rybbit navíc sám doplňuje model zařízení, verzi OS, verzi aplikace a přibližnou
polohu odvozenou z IP adresy. Nic z toho neposílá klient a nedá se to vypnout
na naší straně; je to standardní chování serveru.

## Co se neposílá

`sendDefaultPii`, `attachScreenshot` i performance tracing jsou vypnuté. Obsah
zpráv, jména konverzací, přihlašovací údaje, push identita ani adresa serveru
se neodesílají. `Rybbit.init` běží s `autoTrackErrors: false` — chyby patří
Sentry, které je nejdřív pročistí, a vlastní handler Rybbitu by navíc převzal
`FlutterError.onError` pod Sentry integrací.

Ani jedno SDK nesmí shodit start aplikace: telemetrie je diagnostika, ne
funkce, o kterou uživatel žádal. Selhání `Rybbit.init` se spolkne a aplikace
běží dál bez analytiky.

## Verze Sentry

`sentry_flutter` je držené na 8.x. Od 9.0 SDK závisí na balíku `jni`, který se
hlásí jako ffi plugin i pro Windows a Linux, takže jeho CMake volá
`find_package(JNI)` a desktop build bez JDK skončí chybou. Windows je tady
cílová platforma s vlastním C++ runnerem, takže požadavek na JDK jen kvůli
telemetrii je horší obchod než starší major SDK.

## Ověření

Živě na Android emulátoru proti `com.nkshub.nextcloudtalk`, build `e5f893d`
s `--dart-define-from-file=telemetry.env`:

- **Rybbit ověřen (L).** Site `com.nkshub.nextcloudtalk` (org NKS Apps) přijal
  `app_open` s `environment=development` a pageviews `/` → `/search/messages`
  → `/`. Žádný token, id účtu ani název konverzace v payloadu není. Soubor
  `telemetry_installation_id.txt` (32 znaků) vznikl v `files/` aplikace.
- **Sentry ověřeno jen po inicializaci.** SDK i sentry-native nastartují
  (`sentry-native: starting backend` v logcatu), ale event z instance
  nedorazil: Relay na `sentry.example.invalid` v tu dobu nedokázal načíst
  project config (`error fetching project state …: deadline exceeded`) pro
  ~230 klíčů, tedy pro celou instanci. `POST /api/43/store/` vrací HTTP 200,
  přesto nevznikne issue. Je to provozní stav instance, ne chyba integrace —
  ověření end-to-end zbývá zopakovat, až Relay poběží.

Testy:

- `apps/mobile/test/telemetry_test.dart` — brána konfigurace, scrubber
  a formát id instalace.
- `apps/mobile/test/telemetry_bootstrap_test.dart` — zahození
  `SentryEvent.request` a pročištění zpráv, výjimek a breadcrumbs.
