# Provoz Go push gateway

Datum posledního ověření: 23. srpna 2026.

Stav: runtime v [`services/push_gateway`](../../services/push_gateway/) je
implementovaný a lokálně ověřený. Dockerfile existuje, ale container build a
restart smoke zatím neproběhly, protože v ověřovacím prostředí není funkční
Docker ani Podman. Skutečné FCM doručení také čeká na Firebase projekt
vydavatele, Application Default Credentials a fyzické Android zařízení.

## Role a trust hranice

Jedna veřejná aplikace používá jeden Firebase projekt a gateway vydavatele pro
všechny podporované Nextcloud servery. Správce běžného Nextcloudu neposkytuje
Firebase credential a mobilní aplikace nestahuje cizí Firebase konfiguraci.

Gateway zveřejňuje Notifications-compatible `POST /devices`, `DELETE /devices`
a `POST /notifications`. Provozní endpointy `GET /health/live`,
`GET /health/ready` a `GET /metrics` nemají aplikační autentizaci. Reverzní proxy
nebo síťová politika je proto musí zpřístupnit jen monitoringu a orchestrátoru.

Proces sám neterminuje TLS. Veřejný provoz musí ukončit důvěryhodná reverzní
proxy a směrem ke gateway použít privátní síť nebo jinak chráněný transport.
Rate limit používá přímo TCP peer z `RemoteAddr` a záměrně nedůvěřuje
`X-Forwarded-For`. Za jednou proxy proto všechny požadavky sdílejí jeden bucket;
změna této vlastnosti vyžaduje explicitní trusted-proxy návrh a test.

## Runtime požadavky

- PostgreSQL. Integrační běh je ověřený na PostgreSQL 18; minimální podporovaná
  produkční verze zatím není samostatně stanovena.
- Firebase projekt vydavatele s povoleným Cloud Messaging API.
- Application Default Credentials dostupné procesu. Preferovaný je workload
  identity mechanismus platformy. Soubor service account se nesmí přidat do
  repozitáře, image ani logu.
- Pro build ze zdrojů Go 1.25.0. Produkční binárka je bez CGO.

## Povinná konfigurace

- `PUSH_GATEWAY_LISTEN_ADDRESS`: explicitní adresa ve tvaru host:port.
- `PUSH_GATEWAY_DATABASE_URL`: PostgreSQL URL. Obsahuje-li credential, jde o
  secret a nesmí se logovat ani ukládat do obrazu.
- `PUSH_GATEWAY_TOKEN_ENCRYPTION_KEY`: kanonický Base64 přesně 32 náhodných
  bytů pro AES-256-GCM šifrování provider tokenů.
- `PUSH_GATEWAY_FIREBASE_PROJECT_ID`: ID Firebase projektu vydavatele.

Gateway aktuálně neumí číst předchozí a nový token-encryption key současně.
Klíč se proto nesmí prostě vyměnit: existující registrace by nešlo dešifrovat.
Rotace vyžaduje předem implementovanou a otestovanou re-encryption migraci nebo
novou registraci všech zařízení.

## Volitelná konfigurace

<!-- markdownlint-disable MD013 -->

| Proměnná | Výchozí hodnota | Povolený rozsah |
| --- | --- | --- |
| `PUSH_GATEWAY_WORKER_COUNT` | `4` | 1 až 64 |
| `PUSH_GATEWAY_CLAIM_SIZE` | `32` | 1 až 500 |
| `PUSH_GATEWAY_QUEUE_MAX_DEPTH` | `100000` | 1 až 10000000 |
| `PUSH_GATEWAY_LEASE_DURATION` | `30s` | 5s až 10m |
| `PUSH_GATEWAY_PROVIDER_TIMEOUT` | `10s` | 1s až lease duration |
| `PUSH_GATEWAY_SHUTDOWN_TIMEOUT` | `20s` | 1s až 2m |
| `PUSH_GATEWAY_DEDUPE_RETENTION` | `168h` | 1h až 2160h |
| `PUSH_GATEWAY_RATE_LIMIT_PER_MINUTE` | `600` | 1 až 100000 |
| `PUSH_GATEWAY_RATE_LIMIT_BURST` | `100` | 1 až per-minute limit |

<!-- markdownlint-enable MD013 -->

Musí platit `provider timeout < shutdown timeout < lease duration`. Neplatná,
prázdná nebo whitespace-ohraničená hodnota ukončí start bez vypsání secretu.

## Start, migrace a readiness

Při startu proces v tomto pořadí:

1. načte a zvaliduje prostředí;
2. vytvoří token cipher a smaže dočasnou kopii klíče z konfigurace;
3. připojí a pingne PostgreSQL;
4. pod advisory lockem aplikuje vložené dopředné migrace a kontroluje jejich
   SHA-256 checksum;
5. vytvoří Firebase Admin klienta přes Application Default Credentials;
6. provede úvodní cleanup fronty, spustí pevný worker pool a HTTP listener.

`/health/live` potvrzuje pouze běžící HTTP proces. `/health/ready` vrací úspěch,
jen když worker dokončil úvodní cleanup, PostgreSQL odpovídá a počet zapsaných
migrací odpovídá binárce. Readiness neprovádí síťový FCM send a sama proto
neprokazuje dostupnost Firebase.

Starší binárka nemusí být ready nad schématem s novějšími migracemi. Rollback
binárky je bezpečný pouze po ověření obousměrné schema kompatibility; před
produkční migrací je nutný obnovitelný databázový snapshot.

## Bounded provozní chování

- Nejvýše 1024 současných TCP spojení a 256 současně obsluhovaných API requestů
  na proces; další API request dostane `503 GATEWAY_BUSY`.
- Nejvýše 1000 notifikací v batchi a 8 KiB na jednu JSON obálku.
- Fronta se přijímá až po PostgreSQL commitu a globální maximum se kontroluje v
  serializované enqueue transakci.
- Worker claimuje pouze tolik jobů, kolik má volných slotů, přes
  `FOR UPDATE SKIP LOCKED`.
- Timeout, 408, 429, síťová chyba a 5xx používají exponential backoff s jitterem,
  nejvýše osm pokusů a delay nejvýše pět minut. `Retry-After` je také omezený.
- FCM `UNREGISTERED` a FCM-specifický invalid argument atomicky revokují jen
  odpovídající generaci registrace. Permanentní chyba obálky ukončí jen job.
- Pád po FCM ACK a před DB commitem může doručit stejnou opaque obálku podruhé.
  To je očekávané at-least-once chování, ne chyba vydávaná za exactly-once.

Více replik může sdílet jednu databázi; lease a `SKIP LOCKED` oddělují claimy.
HTTP rate limit a počitadla jsou per-process, zatímco queue maximum a job stav
jsou globální v PostgreSQL.

## Metriky a logy

`/metrics` vrací Prometheus text s bounded labely:

- readiness;
- request count podle pevné šablony endpointu a status class;
- provider outcome;
- počet aktivních delivery;
- počet jobů podle pevného queue stavu.

Log requestu obsahuje jen interně generované request ID, HTTP metodu, pevnou
šablonu endpointu, status class a dobu. Nesmí obsahovat Authorization, cookies,
provider token, device identifier, cloudId, hostname, ciphertext ani obsah
zprávy. Metrics endpoint při nedostupné DB vrátí 503 a záměrně nevypisuje queue
hodnoty.

## Graceful shutdown a incidenty

`SIGTERM` nebo interrupt zastaví příjem nových requestů a nechá aktivní joby
dokončit v bounded shutdown okně. Nedokončený lease po pádu expiruje a jiná
replika jej znovu claimne.

Při incidentu sleduj zejména:

- `push_gateway_ready`;
- růst `push_gateway_queue_jobs{state="pending"}`;
- `retry_timeout`, `retry_rate_limited` a `retry_server`;
- `invalid_token` a permanentní provider chyby;
- PostgreSQL dostupnost a aktuálnost migrací.

Do incidentního ticketu ani veřejného issue nekopíruj DSN, ADC, tokeny, opaque
payloady nebo identifikátory zařízení. Diagnostika musí zůstat pouze v bounded
kategoriích a agregovaných počtech.

## Ověřovací příkazy

Z adresáře `services/push_gateway`:

```text
go mod verify
go test ./...
go test -tags=integration -count=1 ./internal/store
go test -race -count=1 ./...
go vet ./...
go build -trimpath ./cmd/push-gateway
govulncheck ./...
```

Race detector na Windows vyžaduje funkční CGO C toolchain. Container smoke a
skutečný FCM smoke jsou samostatné povinné brány a uvedené příkazy je
nenahrazují.
