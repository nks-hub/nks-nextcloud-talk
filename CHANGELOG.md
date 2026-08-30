# Changelog

Vydání, která se dostala k testerům. Čísla v závorce jsou build number, tedy
`versionCode` na Androidu a `CFBundleVersion` na Apple platformách; obě strany
drží stejné číslo, aby se hlášení od testerů daly spárovat napříč platformami.

Zdrojem pravdy o verzi je `apps/mobile/pubspec.yaml`; `apps/mobile/lib/core/app_version.dart`
ji zrcadlí a test hlídá, aby se ty dvě nerozešly.

Buildy 17 až 19 tag nemají, a mít ho nebudou: na Play je nahradil build 20
ještě před schválením a na TestFlight se vůbec nedostaly. Tag drží jen to,
co se opravdu dostalo k testerům.

Buildy 1 a 3 vznikly ještě před uzavřeným testováním na Play a šly jen na
TestFlight. Jejich obsah se nedá rozepsat po položkách: v té době se číslo
buildu nezvedalo commitem, takže k nim nevede hranice v historii. Uvedené je
proto jen to, co je doložitelné z App Store Connect.

## Připraveno pro další build

- Když na iOS nezačne nahrávání hlasové zprávy, čekání po 10 sekundách skončí
  chybou a aplikace zůstane použitelná. Další pokus už neblokuje předchozí
  nativní nahrávání.
- Česká chybová hláška hlasové zprávy se vejde do spodní lišty i se všemi
  akcemi. Dříve přetékala mimo obrazovku.
- Z obrazovky nové konverzace lze vytvořit prázdnou skupinovou nebo veřejnou
  místnost bez hledání a pozvání prvního účastníka.
- V otevřené konverzaci se ukáže, kdo právě píše. Více píšících lidí se sloučí
  do jednoho řádku; indikátor zmizí po ukončení psaní nebo po výpadku spojení a
  respektuje nastavení soukromí Nextcloud Talk. Vlastní indikátor se správně
  odešle i po obnovení signalingu; starý neprázdný koncept jej sám znovu
  nespustí.
- GIF přijatý ze serveru bez aktivní Giphy integrace už nenabízí nefunkční
  opakování. Místo něj ukáže, že GIFy na serveru nejsou dostupné; samotný odkaz
  přitom nezobrazí.
- Moderátor může v detailu podporované konverzace zapnout telefonické a SIP
  připojení s osobním PINem, bez PINu nebo jej vypnout. Volby se zobrazí jen
  tehdy, když je server i účet skutečně podporují. Po zapnutí uvidí každý
  účastník serverové pokyny, ID schůzky a případně svůj osobní PIN.

## 0.1.0 (23) — 30. 8. 2026

Play: odesláno ke kontrole. TestFlight: build `VALID`, obě skupiny.

- Opraven pád, který mohl nastat při otevření konverzace z notifikace nebo
  odkazu ve chvíli, kdy se hlavní obrazovka právě zavírala. Rozpracovaná
  navigace se nyní bezpečně ukončí.

## 0.1.0 (22) — 30. 8. 2026

Play: publikováno 30. 8. 14:39, k dispozici testerům, 177 zemí.
TestFlight: build `VALID`, obě skupiny.

- „Vybrat obrázek“ na iOS otevírá knihovnu Fotek. Dříve tato volba omylem
  otevřela prohlížeč dokumentů, takže screenshot uložený jen ve Fotkách nešel
  k zprávě přiložit.

## 0.1.0 (21) — 30. 8. 2026

Play: publikováno 30. 8. 13:36, k dispozici testerům, 177 zemí.
TestFlight: build `VALID`, obě skupiny.

- Při tažení otevřené konverzace zpět je nově vidět skutečný seznam
  konverzací pod ní. Dříve se chat sice posouval správně, ale odkrýval jen
  prázdné pozadí.

## 0.1.0 (20) — 30. 8. 2026

Play: publikováno 30. 8. 8:51, k dispozici testerům, 177 zemí.
TestFlight: build `VALID`, obě skupiny.

- Emoji jako obrázek konverzace si můžete obarvit. K výběru emoji přibyla
  řada barev pozadí. Ve výchozím stavu se barva neposílá vůbec, takže se
  pozadí řídí světlým nebo tmavým režimem, jak to dělal doteď.

Tento build zároveň přináší všechno z buildů 17 až 19, které Play nestihl
schválit a nahradil je:

- Hledat jde i uvnitř jedné konverzace. V její liště přibyla lupa, která
  prohledá jen ji; hledání ze seznamu konverzací zůstává přes všechny.
- Stav si můžete nechat vymazat sám: za 30 minut, za hodinu, za 4 hodiny,
  dnes nebo tento týden.
- Na zprávu ve skupině jde odpovědět soukromě.

## 0.1.0 (19) — 30. 8. 2026

Play: odesláno ke kontrole, ještě před schválením nahrazeno buildem 20.
TestFlight: přeskočeno, nahradil ho build 20.

- Hledat jde i uvnitř jedné konverzace. V její liště přibyla lupa, která
  prohledá jen ji; hledání ze seznamu konverzací zůstává přes všechny.
  Aplikace to uměla odjakživa, ale nikde se na to nedalo kliknout.

## 0.1.0 (18) — 30. 8. 2026

Play: odesláno ke kontrole, ještě před schválením nahrazeno buildem 20.
TestFlight: přeskočeno, nahradil ho build 20.

- Stav si můžete nechat vymazat sám. K poli se zprávou přibyla volba
  „Vymazat stav": za 30 minut, za hodinu, za 4 hodiny, dnes nebo tento
  týden. Doteď šel stav nastavit, ale ne zrušit časem, takže „Jsem na
  obědě" viselo u jména do večera.
- „Dnes" končí o půlnoci a „Tento týden" v neděli, obojí podle času
  vašeho telefonu.

## 0.1.0 (17) — 30. 8. 2026

Play: odesláno ke kontrole, ještě před schválením nahrazeno buildem 18.
TestFlight: přeskočeno, nahradil ho build 20.

- Na zprávu ve skupině jde odpovědět soukromě. V nabídce u cizí zprávy
  přibylo „Odpovědět soukromě": napsaná odpověď se odešle do vaší
  soukromé konverzace s autorem a nese s sebou odkaz na původní zprávu,
  takže druhá strana vidí, čeho se týká. Konverzace se založí sama,
  pokud ještě neexistuje.
- Soukromá odpověď by přitom doteď neprošla vůbec. Aplikace čekala, že
  server pojmenuje soukromou konverzaci seznamem obou účastníků, jenže
  ten posílá jméno druhého člověka. Ověřování tak selhalo pokaždé.

## 0.1.0 (16) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- V nastavení přibyly licence knihoven, ze kterých je aplikace složená.
  Najdete je v Lokální diagnostice. Aplikace stojí na 171 balíčcích
  a jejich licence vyžadují, aby jejich znění šlo s programem — dosud
  se v aplikaci nedalo dostat nikam, kde by bylo k přečtení.

## 0.1.0 (15) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- Napsaný text se odešle jako popisek přílohy. Když máte něco rozepsaného
  a připnete obrázek nebo soubor, text půjde s ním místo aby zůstal
  v poli. Prázdné pole popisek neposílá a hlasovka ho nebere.

## 0.1.0 (14) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- Ztracené spojení s notifikačním kanálem se přestalo hlásit jako pád
  aplikace. Když systém uspí telefon a spojení zahodí, jeho zavírání
  selže — to je běžný konec spojení, ne havárie.
- Aplikace se při tom navíc přestala zasekávat: úklid toho spojení
  v takovém případě nikdy nedoběhl.

## 0.1.0 (13) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- Moderátor může smazat i zprávu, kterou nenapsal. Server to dovoluje
  odjakživa, aplikace ale nabízela mazání jen u vlastních zpráv, takže
  moderátor s nevhodným příspěvkem nemohl udělat nic.

## 0.1.0 (12) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- Konverzace, do které psát nesmíte, už nenabízí psací pole. Doteď šlo
  zprávu napsat a odeslat a teprve pak přišlo odmítnutí. Týká se dvou
  případů, které aplikace neuměla rozlišit: moderátor vám v konverzaci vzal
  právo psát, nebo konverzace ještě nezačala a čekáte v čekárně. Místo pole
  je teď zámek, který řekne, o který z nich jde.
- Přeposlat zprávu nejde do konverzace, kde byste ji stejně neodeslali.

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
