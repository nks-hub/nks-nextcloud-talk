# Překlad zpráv

Stav k 31. srpnu 2026. Capability a klientský tok jsou ověřené proti
Nextcloud Talk serveru `f2958bb25be6604240c58a3faf9a2033a30d20e5` a jeho
OCS Translation API. Flutter implementace je capability-first a nepoužívá
žádného vlastního překladového poskytovatele ani proxy.

## Capability brána

- Akce Přeložit se ukáže pouze při booleovské capability
  `spreed.config.chat.has-translation-providers`.
- Brána je account-scoped. Služba před každým requestem znovu načte
  autentizované capabilities a ověří existenci přesné konverzace.
- Chybějící účet, credential, konverzace, neshodný room token nebo neplatný
  room JSON selže zavřeně bez odeslání textu.
- Referenční instance capability neposkytuje, proto na ní zůstává akce správně
  skrytá. Úspěšný live překlad se pro tuto instanci netvrdí.

## Endpointy

Seznam podporovaných jazykových párů:

```text
GET /ocs/v2.php/translation/languages?format=json
```

Překlad textu:

```text
POST /ocs/v2.php/translation/translate?format=json
Content-Type: application/json

{
  "text": "Text zprávy",
  "fromLanguage": null,
  "toLanguage": "cs"
}
```

`fromLanguage=null` se nabízí pouze tehdy, když server vrátí
`languageDetection=true`. Cílový jazyk se vybírá jen z párů vrácených
serverem.

## Ověřování hranice

- Request text má nejvýše 1 MiB znaků a nesmí být po ořezání prázdný.
- Identifikátor jazyka má 1 až 32 znaků a smí obsahovat pouze písmena, čísla,
  `_` a `-`. Zdroj a cíl nesmějí být stejné.
- Odpověď je omezena na 2 MiB a nejvýše 4096 jedinečných jazykových párů.
- Úspěch vyžaduje HTTP 200 i OCS `status=ok` a `statuscode=200`.
- 400 je neplatný vstup, 401 vyžaduje nové přihlášení, 404/412 znamená
  nedostupný překlad, 429 rate limit a 500/503 nedostupnou službu. Ostatní
  statusy se odmítnou jako nepodporované.
- Logy a `toString` nikdy nevypisují původní ani přeložený text.

## Flutter chování

Akce v nabídce zprávy otevře dialog, načte jazykové páry a nabídne serverovou
detekci nebo konkrétní zdrojový jazyk. Přeložený výsledek se vykreslí stejným
Rich Object Strings rendererem jako původní zpráva, takže zachová bezpečné
zmínky a další parametry. Dialog upozorní, že překlad vytvořila AI, a dovolí
zkopírovat prostý přeložený text.

Načítání jazyků i překlad lze opakovat po chybě. Zavření dialogu abortuje
transport a generation guard ignoruje pozdní dokončení staršího requestu.
Přepnutí účtu nebo místnosti nemůže přesměrovat rozběhnutý překlad do jiného
scope.

## Důkazy

- Pure Dart translation kontrakt: 13/13.
- Dotčená Flutter sada služby, dialogu a nabídky zprávy: 60/60.
- Celý `talk_protocol`: 946/946. Celá mobilní sada: 1493 úspěšných a čtyři
  credential-gated skipy; `flutter analyze` bez nálezu.
- Release APK prošel sestavením a licenční bránou 140/111. Aktualizační
  instalace na Android 14 zachovala účet a server bez capability akci skryl.
- Reálný snímek nabídky je lokálně v `.artifacts/nks-translation-menu.png`.

Zbývá server s aktivním překladovým poskytovatelem pro úspěšný live round trip,
reálný chybový stav poskytovatele, iOS runtime a pixelová kontrola dialogu v
obou tématech.
