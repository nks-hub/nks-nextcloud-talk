# Changelog

Vydání, která se dostala k testerům. Čísla v závorce jsou build number, tedy
`versionCode` na Androidu a `CFBundleVersion` na Apple platformách; obě strany
drží stejné číslo, aby se hlášení od testerů daly spárovat napříč platformami.

Zdrojem pravdy o verzi je `apps/mobile/pubspec.yaml`; `apps/mobile/lib/core/app_version.dart`
ji zrcadlí a test hlídá, aby se ty dvě nerozešly.

Buildy 1 a 3 vznikly ještě před uzavřeným testováním na Play a šly jen na
TestFlight. Jejich obsah se nedá rozepsat po položkách: v té době se číslo
buildu nezvedalo commitem, takže k nim nevede hranice v historii. Uvedené je
proto jen to, co je doložitelné z App Store Connect.

## 0.1.0 (11) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- Vlákna v seznamu se jmenují podle zprávy, ze které vznikla. Vlákno bez
  názvu se doteď jmenovalo jen „Vlákno", takže dvě vlákna v jedné konverzaci
  nešla od sebe rozeznat.
- Seznam vláken už netvrdí, že žádná nejsou, dokud se nezeptá serveru.
  Načítání se pouštělo až po prvním vykreslení, takže obrazovka odpověděla
  dřív, než se stačila zeptat.
- Výpadek sítě při probuzení na notifikaci se přestal hlásit jako pád
  aplikace. Sync se v takové chvíli běžně nepovede, protože se zařízení
  teprve připojuje; druhá probouzecí cesta to tak brala odjakživa.

## 0.1.0 (10) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- Seznam vláken ukazuje i vlákna, která vznikla odpovídáním. Server v seznamu
  hlásí jen pojmenovaná vlákna, takže konverzace plná odpovědí vypadala prázdně.
  Aplikace teď doplní ta, která zná ze svých uložených zpráv.

## 0.1.0 (9) — 29. 8. 2026

Play: odesláno ke kontrole. TestFlight: build `VALID`, obě skupiny.

- Odkaz na konverzaci už aplikaci neshodí. Odkaz dorazil dvakrát: jednou naším
  kanálem, který ho vyhodnotí proti přihlášeným účtům, a podruhé jako
  pojmenovaná trasa od systému. Na tu druhou aplikace neměla čím odpovědět
  a padala na každém otevřeném odkazu. Nahlásila to telemetrie ze skutečného
  zařízení.

## 0.1.0 (8) — 29. 8. 2026

Play: publikováno 29. 8. 9:29. TestFlight: build `VALID`, obě skupiny.

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

## 0.1.0 (3) — 28. 8. 2026

Jen TestFlight, build `VALID` od 28. 8., přiřazený do interní i externí skupiny.
První build, který dostal české poznámky pro testery.

## 0.1.0 (2) — 28. 8. 2026

Play: publikováno 28. 8. 23:10, první vydání dostupné testerům.

- Notifikace chodí i uživateli, který má vedle toho oficiální aplikaci Talk.
  Registrace push zařízení posílá správný User-Agent, podle kterého server
  určuje typ aplikace.
- Obrázky se nedeformují ani v náhledu, ani po rozkliknutí.
- Bundle přestal žádat oprávnění k fotkám a videím, která aplikace nepoužívá.

## 0.1.0 (1) — 27. 8. 2026

Jen TestFlight, build `VALID` od 27. 8. První build aplikace, který se vůbec
dostal k testerům. Cestu k němu a čtyři blokády, které přitom padly, popisuje
`docs/architecture/apple-distribution.md`.
