from __future__ import annotations

import base64
import binascii
import json
import sys
from copy import deepcopy
from pathlib import Path
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa, utils
from jsonschema import Draft202012Validator, FormatChecker
from openapi_spec_validator import validate_spec


CONTRACT_ROOT = Path(__file__).resolve().parent
FIXTURE_ROOT = CONTRACT_ROOT / "fixtures"
MANIFEST_PATH = FIXTURE_ROOT / "manifest.json"
REQUIRED_FIXTURE_IDS = {
    "mobile-envelope",
    "registration-request",
    "registration-response",
    "wake-up-ambiguous",
    "wake-up-delete-all",
    "wake-up-delete-multiple",
    "wake-up-delete-one",
    "wake-up-normal",
}


class ContractValidationError(RuntimeError):
    pass


def reject_duplicate_members(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ContractValidationError(f"JSON contains duplicate member {key!r}")
        value[key] = item
    return value


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle, object_pairs_hook=reject_duplicate_members)
    if not isinstance(value, dict):
        raise ContractValidationError(f"{path.name} must contain a JSON object")
    return value


def resolve_pointer(document: dict[str, Any], reference: str) -> Any:
    if not reference.startswith("#/"):
        raise ContractValidationError(
            f"Only local references are supported: {reference}"
        )
    current: Any = document
    for raw_part in reference[2:].split("/"):
        part = raw_part.replace("~1", "/").replace("~0", "~")
        try:
            current = current[part]
        except (KeyError, TypeError) as error:
            raise ContractValidationError(
                f"Unresolvable reference: {reference}"
            ) from error
    return current


def expand_references(
    value: Any,
    document: dict[str, Any],
    reference_stack: tuple[str, ...] = (),
) -> Any:
    if isinstance(value, list):
        return [expand_references(item, document, reference_stack) for item in value]
    if not isinstance(value, dict):
        return value
    if "$ref" in value:
        reference = value["$ref"]
        if reference in reference_stack:
            raise ContractValidationError(f"Circular reference: {reference}")
        target = deepcopy(resolve_pointer(document, reference))
        siblings = {key: item for key, item in value.items() if key != "$ref"}
        if siblings:
            if not isinstance(target, dict):
                raise ContractValidationError(
                    f"Reference siblings require an object: {reference}"
                )
            target.update(siblings)
        return expand_references(target, document, reference_stack + (reference,))
    return {
        key: expand_references(item, document, reference_stack)
        for key, item in value.items()
    }


def decode_canonical_base64(value: str, field_name: str) -> bytes:
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ContractValidationError(
            f"{field_name} is not canonical Base64"
        ) from error
    if base64.b64encode(decoded).decode("ascii") != value:
        raise ContractValidationError(f"{field_name} is not canonical Base64")
    return decoded


def load_rsa_public_key(public_key_pem: str, field_name: str) -> rsa.RSAPublicKey:
    try:
        public_key = serialization.load_pem_public_key(public_key_pem.encode("ascii"))
    except (UnicodeEncodeError, ValueError, TypeError) as error:
        raise ContractValidationError(f"{field_name} is not a public key") from error
    if not isinstance(public_key, rsa.RSAPublicKey) or public_key.key_size != 2048:
        raise ContractValidationError(f"{field_name} must be an RSA-2048 public key")
    if public_key.public_numbers().e != 65537:
        raise ContractValidationError(f"{field_name} must use exponent 65537")
    return public_key


def verify_device_identity(registration_envelope: dict[str, Any]) -> None:
    try:
        data = registration_envelope["ocs"]["data"]
        public_key_pem = data["publicKey"]
        identifier_text = data["deviceIdentifier"]
        signature_text = data["signature"]
    except (KeyError, TypeError) as error:
        raise ContractValidationError(
            "Registration response shape is invalid"
        ) from error
    public_key = load_rsa_public_key(public_key_pem, "publicKey")
    identifier = decode_canonical_base64(identifier_text, "deviceIdentifier")
    signature = decode_canonical_base64(signature_text, "signature")
    if len(identifier) != 64 or len(signature) != 256:
        raise ContractValidationError("Device identity has an invalid RSA-2048 size")
    try:
        public_key.verify(
            signature,
            identifier,
            padding.PKCS1v15(),
            utils.Prehashed(hashes.SHA512()),
        )
    except InvalidSignature as error:
        raise ContractValidationError(
            "Device identity signature verification failed"
        ) from error


def verify_envelope_signature(
    public_key: rsa.RSAPublicKey,
    ciphertext: bytes,
    signature: bytes,
) -> None:
    try:
        public_key.verify(signature, ciphertext, padding.PKCS1v15(), hashes.SHA512())
    except InvalidSignature as error:
        raise ContractValidationError("Envelope signature is invalid") from error


def ephemeral_crypto_proof(
    document: dict[str, Any] | None = None,
) -> dict[str, int]:
    if document is None:
        document = load_json(CONTRACT_ROOT / "openapi.json")
    try:
        raw_envelope_schema = document["components"]["schemas"]["MobilePushEnvelope"]
    except KeyError as error:
        raise ContractValidationError("MobilePushEnvelope schema is missing") from error
    envelope_schema = expand_references(raw_envelope_schema, document)
    user_private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    device_private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
    )
    wrong_device_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
    )
    plaintext = json.dumps(
        {
            "app": "spreed",
            "id": "rooma123",
            "nid": 1337,
            "subject": "Synthetic wake-up",
            "type": "chat",
        },
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    variants: tuple[tuple[str, padding.AsymmetricPadding], ...] = (
        (
            "oaep-sha1",
            padding.OAEP(
                mgf=padding.MGF1(algorithm=hashes.SHA1()),
                algorithm=hashes.SHA1(),
                label=None,
            ),
        ),
        ("pkcs1-v1_5", padding.PKCS1v15()),
    )
    negative_checks = 0
    schema_validations = 0
    for name, encryption_padding in variants:
        ciphertext = device_private_key.public_key().encrypt(
            plaintext,
            encryption_padding,
        )
        signature = user_private_key.sign(
            ciphertext,
            padding.PKCS1v15(),
            hashes.SHA512(),
        )
        if len(ciphertext) != 256 or len(signature) != 256:
            raise ContractValidationError(f"{name} did not produce RSA-2048 material")
        subject_text = base64.b64encode(ciphertext).decode("ascii")
        signature_text = base64.b64encode(signature).decode("ascii")
        envelope = {"signature": signature_text, "subject": subject_text}
        schema_errors = sorted(
            Draft202012Validator(
                envelope_schema,
                format_checker=FormatChecker(),
            ).iter_errors(envelope),
            key=lambda error: list(error.absolute_path),
        )
        if schema_errors:
            raise ContractValidationError(
                f"{name} envelope failed MobilePushEnvelope: {schema_errors[0].message}"
            )
        schema_validations += 1
        decoded_ciphertext = decode_canonical_base64(subject_text, f"{name}.subject")
        decoded_signature = decode_canonical_base64(
            signature_text,
            f"{name}.signature",
        )
        verify_envelope_signature(
            user_private_key.public_key(),
            decoded_ciphertext,
            decoded_signature,
        )
        decrypted = device_private_key.decrypt(
            decoded_ciphertext,
            encryption_padding,
        )
        if decrypted != plaintext:
            raise ContractValidationError(f"{name} plaintext round trip failed")

        tampered_signature = bytearray(decoded_signature)
        tampered_signature[-1] ^= 1
        try:
            verify_envelope_signature(
                user_private_key.public_key(),
                decoded_ciphertext,
                bytes(tampered_signature),
            )
        except ContractValidationError:
            negative_checks += 1
        else:
            raise ContractValidationError(f"{name} accepted a tampered signature")

        try:
            foreign_plaintext = wrong_device_key.decrypt(
                decoded_ciphertext,
                encryption_padding,
            )
        except ValueError:
            negative_checks += 1
        else:
            if foreign_plaintext == plaintext:
                raise ContractValidationError(f"{name} decrypted with a foreign key")
            negative_checks += 1
    return {
        "decryptions": len(variants),
        "negativeChecks": negative_checks,
        "schemaValidations": schema_validations,
        "signatures": len(variants),
        "variants": len(variants),
    }


def validate_fixture(
    document: dict[str, Any],
    fixture: dict[str, Any],
) -> tuple[bool, bool]:
    fixture_file = fixture.get("file")
    schema_name = fixture.get("schema")
    if not isinstance(fixture_file, str) or not isinstance(schema_name, str):
        raise ContractValidationError("Fixture file and schema must be strings")
    fixture_path = (FIXTURE_ROOT / fixture_file).resolve()
    if fixture_path.parent != FIXTURE_ROOT or fixture_path.suffix != ".json":
        raise ContractValidationError(f"Invalid fixture path: {fixture_file}")
    instance = load_json(fixture_path)
    try:
        raw_schema = document["components"]["schemas"][schema_name]
    except KeyError as error:
        raise ContractValidationError(
            f"Unknown fixture schema: {schema_name}"
        ) from error
    schema = expand_references(raw_schema, document)
    errors = sorted(
        Draft202012Validator(
            schema,
            format_checker=FormatChecker(),
        ).iter_errors(instance),
        key=lambda error: list(error.absolute_path),
    )
    expected_valid = fixture.get("valid") is not False
    if expected_valid == bool(errors):
        detail = errors[0].message if errors else "schema accepted the fixture"
        raise ContractValidationError(f"{fixture_file}: {detail}")
    identity_checked = False
    if expected_valid and fixture.get("verifyDeviceIdentity") is True:
        verify_device_identity(instance)
        identity_checked = True
    if schema_name == "MobilePushEnvelope" and expected_valid:
        if len(decode_canonical_base64(instance["subject"], "subject")) != 256:
            raise ContractValidationError("Envelope subject is not RSA-2048 ciphertext")
        if len(decode_canonical_base64(instance["signature"], "signature")) != 256:
            raise ContractValidationError("Envelope signature is not RSA-2048 material")
    return expected_valid, identity_checked


def scan_for_private_keys(root: Path = CONTRACT_ROOT) -> int:
    forbidden_labels = (
        "PRIVATE KEY",
        "ENCRYPTED PRIVATE KEY",
        "RSA PRIVATE KEY",
        "DSA PRIVATE KEY",
        "EC PRIVATE KEY",
        "OPENSSH PRIVATE KEY",
    )
    files = [path for path in root.rglob("*") if path.is_file()]
    for path in files:
        if path.suffix.lower() in {".key", ".p12", ".pfx"}:
            raise ContractValidationError(f"Private-key file is forbidden: {path.name}")
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if any(
            "-----BEGIN " + label + "-----" in content for label in forbidden_labels
        ):
            raise ContractValidationError(f"Private key is forbidden: {path.name}")
    return len(files)


def validate_contract() -> dict[str, int]:
    manifest = load_json(MANIFEST_PATH)
    contract_path = (FIXTURE_ROOT / manifest.get("contract", "")).resolve()
    if contract_path.parent != CONTRACT_ROOT or contract_path.name != "openapi.json":
        raise ContractValidationError("Manifest contract must resolve to openapi.json")
    document = load_json(contract_path)
    validate_spec(document)

    fixtures = manifest.get("fixtures")
    if not isinstance(fixtures, list):
        raise ContractValidationError("Manifest fixtures must be an array")
    fixture_ids: set[str] = set()
    listed_files: set[str] = set()
    valid_fixtures = 0
    identity_checks = 0
    for raw_fixture in fixtures:
        if not isinstance(raw_fixture, dict):
            raise ContractValidationError("Fixture entries must be objects")
        fixture_id = raw_fixture.get("id")
        fixture_file = raw_fixture.get("file")
        if not isinstance(fixture_id, str) or fixture_id in fixture_ids:
            raise ContractValidationError("Fixture IDs must be unique strings")
        if not isinstance(fixture_file, str) or fixture_file in listed_files:
            raise ContractValidationError("Fixture files must be unique strings")
        fixture_ids.add(fixture_id)
        listed_files.add(fixture_file)
        valid, identity_checked = validate_fixture(document, raw_fixture)
        valid_fixtures += int(valid)
        identity_checks += int(identity_checked)
    if fixture_ids != REQUIRED_FIXTURE_IDS:
        raise ContractValidationError(
            "Fixture coverage does not match the required set"
        )
    actual_files = {
        path.name
        for path in FIXTURE_ROOT.glob("*.json")
        if path.name != MANIFEST_PATH.name
    }
    if actual_files != listed_files:
        raise ContractValidationError("Fixture manifest does not match fixture files")

    crypto = ephemeral_crypto_proof(document)
    scanned_files = scan_for_private_keys()
    return {
        "cryptoNegativeChecks": crypto["negativeChecks"],
        "cryptoVariants": crypto["variants"],
        "ephemeralDecryptions": crypto["decryptions"],
        "ephemeralSchemaValidations": crypto["schemaValidations"],
        "ephemeralSignatures": crypto["signatures"],
        "fixtures": len(fixtures),
        "identityChecks": identity_checks,
        "openapiDocuments": 1,
        "scannedFiles": scanned_files,
        "validFixtures": valid_fixtures,
    }


def main() -> int:
    try:
        result = validate_contract()
        print(
            "Validated 1 OpenAPI document, "
            f"{result['fixtures']} fixtures ({result['validFixtures']} valid), "
            f"{result['identityChecks']} device identity, "
            f"{result['cryptoVariants']} ephemeral RSA-2048 padding variants, "
            f"{result['ephemeralSchemaValidations']} schema-valid envelopes, "
            f"{result['ephemeralSignatures']} SHA-512 signatures, "
            f"{result['ephemeralDecryptions']} decryptions and "
            f"{result['cryptoNegativeChecks']} negative crypto checks; "
            "no private key was persisted."
        )
        return 0
    except (
        ContractValidationError,
        KeyError,
        OSError,
        TypeError,
        json.JSONDecodeError,
    ) as error:
        print(f"Contract validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
