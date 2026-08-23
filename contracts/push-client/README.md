# Klientský push kontrakt

Tento adresář je spustitelná hranice mezi Nextcloud Notifications v2,
Notifications-compatible gateway a mobilním klientem. Popisuje klientskou
registraci, přijatou šifrovanou obálku a všechny podporované wake-up payloady.
Serverová gateway má samostatný kontrakt v
[`contracts/push-gateway`](../push-gateway/).

## Obsah

- `openapi.json` obsahuje OpenAPI 3.1 schémata OCS registrace, mobilní obálky a
  wake-up payloadů;
- `fixtures/manifest.json` eviduje 8 fixtures, z toho 7 platných a 1 záměrně
  neplatnou;
- `validate_contract.py` validuje OpenAPI, schémata a skutečné kryptografické
  operace;
- `test_validate_contract.py` ověřuje pozitivní i negativní chování validátoru;
- `requirements.txt` fixuje Python závislosti kontraktu.

Validátor při každém běhu vytvoří pouze v paměti nové RSA-2048 identity. Ověří
SHA512withRSA podpisy, OAEP SHA-1/MGF1 SHA-1 i kompatibilní PKCS#1 v1.5
encrypt/decrypt, poškozený podpis a cizí klíč. Každou takto vytvořenou obálku
navíc přímo validuje proti `MobilePushEnvelope`. Jde o ephemeral crypto proof;
uložená `mobile-envelope.json` dokládá pouze wire tvar a sama neprokazuje vztah
mezi podpisem, ciphertextem a klíči. Private key se nezapisuje do fixture ani na
disk. Scanner odmítá běžné PKCS#8, šifrované PKCS#8, RSA, DSA, EC i OpenSSH
private-key hlavičky.

## Ověření

Z kořene repozitáře:

```powershell
rtk proxy python contracts\push-client\validate_contract.py
rtk proxy python -m unittest discover -s contracts\push-client -p test_*.py
rtk proxy python -m ruff check contracts\push-client
```

Očekávaný souhrn validátoru:

```text
1 OpenAPI
8 fixtures, 7 valid
1 device identity
2 RSA padding variants
2 schema-valid ephemeral envelopes
2 signatures
2 decryptions
4 negative crypto checks
```

Dart test `packages/talk_protocol/test/push_contract_test.dart` načítá přímo
stejný manifest a všech 8 fixtures. Tím se odděleně neudržuje druhá kopie
registračních nebo payload dat.

## Hranice důkazu

Kontrakt neprokazuje Firebase delivery, Android Keystore, iOS Keychain,
platformní background lifecycle, produkční gateway ani lokální notifikaci. Tyto
důkazy vyžadují skutečný Flutter build, `chatujmePixel` E2E a pro
background/killed FCM také fyzické Android zařízení.
