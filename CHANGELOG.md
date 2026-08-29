# Changelog

Vydání, která se dostala k testerům. Čísla v závorce jsou build number, tedy
`versionCode` na Androidu a `CFBundleVersion` na Apple platformách; obě strany
drží stejné číslo, aby se hlášení od testerů daly spárovat napříč platformami.

Zdrojem pravdy o verzi je `apps/mobile/pubspec.yaml`; `apps/mobile/lib/core/app_version.dart`
ji zrcadlí a test hlídá, aby se ty dvě nerozešly.

## 0.1.0 (8) — 29. 8. 2026

Play: odesláno ke kontrole. TestFlight: build `VALID`, obě skupiny.

- Prázdný seznam vláken už neplete. Odpověď na zprávu vlákno nezaloží, což
  obrazovka doteď zamlčovala a vypadalo to, že aplikace zatajuje odpovědi,
  které uživatel prokazatelně má.

## 0.1.0 (7) — 29. 8. 2026

Play: publikováno 29. 8. 6:36. TestFlight: build `VALID`, obě skupiny.

- Čtení historie už nic neruší. Zpráva, která dorazí, když jste zanoření ve
  starších zprávách, vás nechá přesně tam, kde jste. Doteď vás odsunula o výšku
  své bubliny. Časová osa je nově `CustomScrollView` s `center` klíčem, takže
  jeden konec seznamu nepřeindexuje druhý.
- Animovaný GIF se dekóduje na velikost, ve které se opravdu kreslí, místo
  napevno zadaných 1080 pixelů.

## 0.1.0 (6) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- Tažením od levého kraje se vrátíte na seznam konverzací. V kompaktním
  rozvržení se konverzace nepushuje jako route, takže systémové gesto nemělo co
  vyhodit ze zásobníku a nedělalo nic.
- Tiché odeslání platí i pro psanou zprávu, ne jen pro přílohy. Server bez
  `silent-send` požadavek odmítne, místo aby ho poslal nahlas.
- Windows si drží jednu instanci a přidává ikonu do systémové lišty.

## 0.1.0 (5) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- Druhá fajfka u přečtené zprávy se po návratu do konverzace neztrácí.
  Agregovaný read marker nebyl zapnutý na žádném serveru, protože profil
  schopností ho měl natvrdo vypnutý.
- Reakce ostatních dorazí do otevřené konverzace. Doteď šly vidět jen ty
  přidané z tohoto zařízení.
- Odeslaná zpráva zmizí z psacího pole hned. Když se během odesílání psalo dál,
  zůstávala tam a šla omylem poslat podruhé.
- Skok na konec konverzace po zanoření do historie.
- Odpověď tahem za bublinu.
- Samotné emoji ve zprávě i v reakci se vykreslí větší.

## 0.1.0 (4) — 29. 8. 2026

Jen TestFlight; na Play se toto číslo nedostalo, protože Apple už měl obsazené
buildy 1 až 3 a čísla se sjednocovala.

- Stejný obsah jako 0.1.0 (2) plus telemetrie zkompilovaná do buildu.

## 0.1.0 (2) — 28. 8. 2026

Play: publikováno 28. 8. 23:10, první vydání dostupné testerům.

- Notifikace chodí i uživateli, který má vedle toho oficiální aplikaci Talk.
  Registrace push zařízení posílá správný User-Agent, podle kterého server
  určuje typ aplikace.
- Obrázky se nedeformují ani v náhledu, ani po rozkliknutí.
- Bundle přestal žádat oprávnění k fotkám a videím, která aplikace nepoužívá.
