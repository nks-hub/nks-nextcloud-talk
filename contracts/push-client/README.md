# Client push contract

This directory is the runnable boundary between Nextcloud Notifications v2, a
Notifications-compatible gateway and the mobile client. It describes the client
registration, the received encrypted envelope and every supported wake-up
payload. The server gateway has a separate contract in
[`contracts/push-gateway`](../push-gateway/).

## Contents

- `openapi.json` holds the OpenAPI 3.1 schemas of the OCS registration, the
  mobile envelope and the wake-up payloads;
- `fixtures/manifest.json` records 8 fixtures, of which 7 are valid and 1 is
  deliberately invalid;
- `validate_contract.py` validates the OpenAPI, the schemas and real
  cryptographic operations;
- `test_validate_contract.py` verifies both the positive and the negative
  behaviour of the validator;
- `requirements.txt` pins the Python dependencies of the contract.

On every run the validator creates fresh RSA-2048 identities in memory only. It
verifies SHA512withRSA signatures, OAEP SHA-1/MGF1 SHA-1 as well as compatible
PKCS#1 v1.5 encrypt/decrypt, a corrupted signature and a foreign key. Every
envelope created this way is additionally validated directly against
`MobilePushEnvelope`. This is an ephemeral crypto proof; the stored
`mobile-envelope.json` only documents the wire shape and does not by itself prove
the relation between the signature, the ciphertext and the keys. The private key
is never written into a fixture or to disk. The scanner rejects the usual PKCS#8,
encrypted PKCS#8, RSA, DSA, EC and OpenSSH private-key headers.

## Verification

From the repository root:

```powershell
rtk proxy python contracts\push-client\validate_contract.py
rtk proxy python -m unittest discover -s contracts\push-client -p test_*.py
rtk proxy python -m ruff check contracts\push-client
```

The expected validator summary:

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

The Dart test `packages/talk_protocol/test/push_contract_test.dart` loads the
same manifest and all 8 fixtures directly. That way no second copy of the
registration or payload data is maintained separately.

## Boundary of the evidence

The contract does not prove Firebase delivery, the Android Keystore, the iOS
Keychain, the platform background lifecycle, a production gateway or a local
notification. Those pieces of evidence require a real Flutter build, a
`chatujmePixel` E2E, and for background/killed FCM also a physical Android
device.
