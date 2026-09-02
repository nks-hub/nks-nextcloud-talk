# Rozvaha: kolik místa smí zabrat desktopové chrome

Stav k 2. 9. 2026, měřeno na kódu `_ExpandedShell`
(`features/conversations/conversation_workspace.dart`) a na běžícím buildu 45
na `windows-test-vm`.

## Co se dnes kreslí

Široké rozvržení je `Row` s pěti pevnými pásy zleva doprava:

| pás | šířka | zdroj |
| --- | --- | --- |
| `_AccountRail` | **88 px napevno** | `conversation_account_chrome.dart:23` |
| `VerticalDivider` | 1 px | |
| seznam konverzací | **300 px** na desktopu | `AppMetrics.listPaneWidth` |
| `VerticalDivider` | 1 px | |
| chat | zbytek | `Expanded` |
| detail konverzace | `clamp(300, 27vw, 500)` | volitelný, přepínatelný |

Než začne chat, je tedy **390 px spotřebováno vždy**, bez ohledu na to, co
v těch pásech je. Na okně 1400 px je to 28 % šířky; na 1024 px, což je pořád
běžný notebook, **38 %**.

## Naměřený rozpočet šířky

Změřeno vykreslením skutečného `ConversationWorkspace` na čtyřech šířkách okna;
`chrome` je rail plus seznam, tedy všechno vlevo od konverzace.

| okno | účty | rail | seznam | konverzace | chrome | podíl |
| ---: | ---: | ---: | -----: | ---------: | -----: | ----: |
| 1024 | 1 | 0 | 330 | 693 | 330 | **32,2 %** |
| 1024 | 2 | 88 | 330 | 604 | 418 | **40,8 %** |
| 1280 | 1 | 0 | 390 | 889 | 390 | 30,5 % |
| 1280 | 2 | 88 | 390 | 800 | 478 | 37,3 % |
| 1400 | 1 | 0 | 390 | 1009 | 390 | 27,9 % |
| 1400 | 2 | 88 | 390 | 920 | 478 | 34,1 % |
| 1920 | 1 | 0 | 390 | 1529 | 390 | 20,3 % |
| 1920 | 2 | 88 | 390 | 1440 | 478 | 24,9 % |

Dvě věci z té tabulky stojí za pozornost.

Zaprvé, **rail je nejdražší přesně tam, kde je místa nejmíň**: na 1024 px stojí
8,6 procentního bodu, na 1920 px jen 4,6. Chrome s pevnou šířkou zdražuje, čím
menší je okno — a notebook s 1024 px není okrajový případ.

Zadruhé, čísla jsou z widget testu, kde platí **dotyková** `VisualDensity`,
takže seznam vychází 330–390 px. Na skutečném desktopu je 300 px, takže reálný
podíl je o něco nižší; poměry mezi řádky ale platí.

## Co v tom railu doopravdy je

Obsah `_AccountRail` shora dolů: `BrandMark` 44 px, oddělovač, `ListView`
avatarů účtů po 56 px, a dole dvě tlačítka — přidat účet a nastavení.

U **jednoho účtu** to znamená 88 px na celou výšku okna pro:

1. logo aplikace, které nic nedělá,
2. avatar jediného účtu, na který nejde kliknout (`onTap: isSelected ? null`),
3. dvě tlačítka.

Přepínač, který nemá mezi čím přepínat, není navigace — je to dekorace se
šířkou. A že jde o dekoraci, dokazuje kód sám: `onTap` je u vybraného účtu
`null`, takže jediná položka seznamu je mrtvý terč.

## Klíčové zjištění: správný vzor v repu už je

Kompaktní rozvržení tentýž problém řeší od začátku a řeší ho dobře.
`_AccountMenu` (`conversation_account_chrome.dart:100`) je `PopupMenuButton`,
jehož ikonou je avatar aktuálního účtu a jehož nabídka nese **přesně tytéž tři
věci**: seznam účtů k přepnutí, „Přidat účet" a „Nastavení". Zabírá jedno
tlačítko v hlavičce.

Široký rail tedy není jiná funkce. Je to **trvale rozbalená kopie menu, které
už existuje**, a rozbalená je i tehdy, když je seznam jednoprvkový.

## Rozhodnutí

**D-041: chrome, které nemá mezi čím přepínat, se nekreslí.**

`_AccountRail` se v širokém rozvržení vykreslí, jen když `accounts.length > 1`.
S jediným účtem jeho místo zabere `_AccountMenu` v hlavičce seznamu
konverzací — stejné tlačítko, stejná nabídka, stejné akce jako na mobilu.

Získá se **89 px** (rail i jeho oddělovač) pro obsah. Na okně 1024 px to je
skoro devět procent šířky vrácených chatu.

Proč ne jinak:

- *Zúžit rail* — 88 px je Material rozměr pro dotykový terč 56 px
  s odsazením; zúžení by rozbilo terč, ne problém.
- *Nechat rail a jen skrýt logo* — zůstane pás pro dva knoflíky.
- *Skrývat rail ručně přepínačem* — přidá stav a další ovládací prvek kvůli
  něčemu, co si aplikace umí odvodit sama z počtu účtů.

**D-042: seznam konverzací jde schovat.**

Detail konverzace se přepínat dá (`detailsOpen`), seznam ne, přestože je
širší a při čtení delší konverzace stejně zbytečný. Přibývá přepínač
v hlavičce chatu, který seznam složí. Stav nedrží rozvržení — to je špatné
místo pro stav, který samo při resize zahodí — ale předvolba, viz D-043.

Skládá se na nulu, ne na ikonový proužek. Proužek je třetí šířkový režim
navíc, a to jen proto, aby se ušetřilo jedno kliknutí zpět.

**D-043: složení seznamu si aplikace pamatuje.**

Stav fold přežije restart. Desktopová aplikace, která si rozvržení nepamatuje,
se skládá znovu při každém spuštění. Ukládá se do souboru vedle volby motivu,
tedy NE per účet: fold je vlastnost toho, jak člověk používá tohle okno, a
přepnutí účtu není důvod ho rozbalit.

Nečitelná předvolba spadne na „zobrazeno". Ten směr je schválně: omylem skrytý
seznam vypadá jako ztracené konverzace, omylem zobrazený stojí jedno kliknutí.

## Co se vědomě nemění

- **Multi-server zůstává.** Je to důvod existence tohoto klienta. Mění se jen
  to, že za něj neplatí místem ten, kdo ho nepoužívá.
- **Šířka seznamu 300 px** je převzatá z navigační kolony Nextcloudu a zůstává.
- **Dotykové rozvržení** se nemění vůbec; tam rail nikdy nebyl.
