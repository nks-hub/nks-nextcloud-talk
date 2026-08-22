# Rozhodnutí a otevřené volby

Stavy:

- **Přijato**: uživatel rozhodl nebo jde o nutnou protokolovou invariantu.
- **Doporučeno**: analýza má preferovanou variantu, čeká na potvrzení.
- **Otevřeno**: bez volby se příslušný scaffold nebo feature nesmí uzamknout.
- **Odloženo**: není v prvním release, ale architektura zachovává hranici.

## Přijatá rozhodnutí

### D-001: Multi-server produkt

Stav: Přijato.

Klient není white-label pro jeden server. Referenční instance slouží pouze k
testování.

Důsledek: žádná produkční URL, capability nebo účet nesmí být globální
konstanta.

### D-002: Multi-account izolace

Stav: Přijato jako nutný důsledek multi-server produktu.

Credentials, cache, push identity, connections, badge a deep links se scopují
accountId.

### D-003: Capability-first

Stav: Přijato jako protokolová invarianta.

Číslo Talk release není feature flag. Resolver kombinuje globální,
features-local a room-scoped capabilities.

### D-004: Žádné fake subsystémy

Stav: Přijato podle projektových pravidel.

Call preparation znamená funkční signaling state machine a contract testy, ne
neaktivní tlačítko nebo interface vracející OK.

### D-005: Jedna veřejná push identita

Stav: Přijato jako důsledek veřejného multi-server produktu.

Jeden store build používá jeden applicationId/bundle ID, Firebase projekt a
gateway vydavatele pro všechny podporované Nextcloud servery. Klient při
runtime registraci předá gateway URL do Notifications API v2. Správce serveru
nepotřebuje Firebase credential ani rebuild.

Firebase konfigurace se nesmí načítat z libovolného připojeného Nextcloudu.
Plně nezávislý Firebase/APNs projekt je možný pouze pro samostatně podepsaný
vlastní build.

### D-006: Outbox jen s ověřeným replay kontraktem

Stav: Přijato jako datová a bezpečnostní invarianta.

Lokální operationId, referenceId ani HTTP metoda samy neprokazují serverovou
idempotenci. Každý operationKind se smí zařadit do durable outboxu až po
capability/SHA-bound kontraktu, který popíše bezpečný retry před odesláním,
reconciliation nejednoznačného výsledku, terminální odpovědi, compensation a
uživatelskou akci. Neověřená operace se nesmí vydávat za offline podporovanou.

## Doporučená rozhodnutí

### D-007: Modulární klient

Stav: Doporučeno.

Pure Dart talk_protocol + Flutter app + samostatná push gateway. Storage a sync
zůstávají uvnitř app, dokud další skutečná implementace neodůvodní package.

### D-008: Standardní Notifications app

Stav: Doporučeno.

Vlastní gateway zachová Notifications v2 protokol. Nový Talk event listener se
nevytváří, protože by nepokryl úplnou notification a markProcessed semantiku.

### D-009: Relační SQLite store

Stav: Doporučeno.

Message, thread, parent, room a read marker vyžadují atomické transakce.
Preferovaný Dart kandidát je Drift; verze a platformní kompatibilita se ověří
před implementací.

### D-010: Riverpod pro application/UI state

Stav: Doporučeno.

Chatujme poskytuje ověřený lokální vzor a Riverpod umožní account-scoped
providery. Databázový stav však zůstává zdrojem pravdy; provider nesmí duplikovat
sync store.

## Otevřené volby

### Q-001: Licence

Možnosti:

1. GPL-3.0-or-later pro rychlejší věrný port s odpovídajícím zveřejněním zdroje.
2. Skutečný clean-room protokolový vývoj pod vlastní licencí.

Bez rozhodnutí se nevytváří produkční Flutter kód.

### Q-002: Minimální platformy

Je nutné určit Android minSdk a minimální iOS. Upstream minima jsou pouze vstup
do rozhodnutí, ne automatická volba.

### Q-003: Identita aplikace a signing

Chybí finální applicationId, bundle ID, jeden Firebase projekt vydavatele,
Android signing owner a Apple/APNs signing workflow.

### Q-004: Offline scope prvního release

Možnosti:

1. Cache historie + textový outbox.
2. Plný outbox včetně upload resume od prvního release.

Architektura podporuje obě, ale acceptance scope a pořadí řezů se liší.

### Q-005: Giphy režim

Možnosti:

1. Poslat URL a použít Talk Reference Provider, stejně jako upstream iOS.
2. Stáhnout GIF a uložit jako Nextcloud attachment.

První varianta je doporučená kvůli shodě se serverovým web/iOS chováním a menší
spotřebě úložiště.

### Q-006: Podporované serverové řady

Je nutné určit minimální Nextcloud/Talk řadu. Multi-server neznamená automaticky
podporu všech historických verzí.

### Q-007: Gateway implementační stack

Volba přijde po contract prototypu. Kritéria:

- ověřená FCM HTTP v1 knihovna;
- RSA/SHA-512 a key parsing;
- bounded concurrency a retry;
- bezpečný secret management;
- snadné nasazení a observability;
- dlouhodobá údržba.

Stack se nemá vybrat podle osobní preference bez prototypu kontraktu.

## Odložená rozhodnutí

### D-011: Plná call parity

Stav: Odloženo za chat a push parity.

Architektura zachovává signaling, coordinator, platform a media hranice.
Konkrétní WebRTC balík se vybere až po internal/HPB signaling prototypu a
Android/iOS lifecycle spike.

### D-012: Share Extension a App Intents

Stav: Odloženo.

Datový a deep-link model s nimi počítá, ale první implementace je nesmí
předstírat.
