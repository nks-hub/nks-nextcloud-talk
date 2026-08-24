from __future__ import annotations

import base64
import hashlib
import json
import re
import sys
from copy import deepcopy
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlencode

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa, utils
from jsonschema import Draft202012Validator, FormatChecker
from openapi_spec_validator import validate_spec


CONTRACT_ROOT = Path(__file__).resolve().parent
FIXTURE_ROOT = CONTRACT_ROOT / "fixtures"
MANIFEST_PATH = FIXTURE_ROOT / "manifest.json"


class ContractValidationError(RuntimeError):
    pass


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
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
            raise ContractValidationError(
                f"Circular reference is not supported: {reference}"
            )
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


def find_operation(document: dict[str, Any], operation_id: str) -> dict[str, Any]:
    for path_item in document.get("paths", {}).values():
        for method, operation in path_item.items():
            if method.lower() not in {"get", "post", "put", "patch", "delete"}:
                continue
            if operation.get("operationId") == operation_id:
                return operation
    raise ContractValidationError(f"Unknown operationId: {operation_id}")


def request_schema(
    document: dict[str, Any],
    operation: dict[str, Any],
    fixture: dict[str, Any],
) -> dict[str, Any]:
    location = fixture.get("location")
    if location == "body":
        media_type = fixture.get("mediaType")
        request_body = expand_references(operation.get("requestBody", {}), document)
        try:
            return request_body["content"][media_type]["schema"]
        except KeyError as error:
            raise ContractValidationError(
                f"Operation {fixture['operationId']} has no {media_type} request body"
            ) from error

    if location == "query":
        properties: dict[str, Any] = {}
        required: list[str] = []
        for parameter_reference in operation.get("parameters", []):
            parameter = expand_references(parameter_reference, document)
            if parameter.get("in") != "query":
                continue
            name = parameter["name"]
            properties[name] = parameter["schema"]
            required.append(name)
        return {
            "type": "object",
            "additionalProperties": False,
            "properties": properties,
            "required": required,
        }

    raise ContractValidationError(f"Unsupported request location: {location}")


def response_schema(
    document: dict[str, Any],
    operation: dict[str, Any],
    fixture: dict[str, Any],
) -> dict[str, Any]:
    status = fixture.get("status")
    media_type = fixture.get("mediaType")
    response = expand_references(
        operation.get("responses", {}).get(status, {}), document
    )
    try:
        return response["content"][media_type]["schema"]
    except KeyError as error:
        raise ContractValidationError(
            f"Operation {fixture['operationId']} status {status} has no {media_type} schema"
        ) from error


def validate_json_schema(
    instance: dict[str, Any],
    schema: dict[str, Any],
) -> list[str]:
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    return [
        error.message
        for error in sorted(
            validator.iter_errors(instance), key=lambda item: list(item.path)
        )
    ]


def validate_inner_notifications(
    document: dict[str, Any],
    fixture_name: str,
    instance: dict[str, Any],
) -> list[dict[str, Any]]:
    notification_schema = expand_references(
        document["components"]["schemas"]["NotificationEnvelope"],
        document,
    )
    envelopes: list[dict[str, Any]] = []
    for index, raw_notification in enumerate(instance.get("notifications", [])):
        try:
            envelope = json.loads(raw_notification)
        except json.JSONDecodeError as error:
            raise ContractValidationError(
                f"{fixture_name} notification {index} is not JSON: {error.msg}"
            ) from error
        if not isinstance(envelope, dict):
            raise ContractValidationError(
                f"{fixture_name} notification {index} must decode to an object"
            )
        errors = validate_json_schema(envelope, notification_schema)
        if errors:
            raise ContractValidationError(
                f"{fixture_name} notification {index} violates NotificationEnvelope: "
                + "; ".join(errors)
            )
        envelopes.append(envelope)
    return envelopes


def assert_wire_round_trip(
    fixture_name: str,
    encoding: str | None,
    instance: dict[str, Any],
) -> None:
    if encoding in {"form", "query"}:
        encoded = urlencode(instance)
        decoded_values = parse_qs(encoded, keep_blank_values=True, strict_parsing=True)
        decoded = {key: values[-1] for key, values in decoded_values.items()}
        if decoded != instance:
            raise ContractValidationError(
                f"{fixture_name} failed {encoding} round trip"
            )
        return

    if encoding == "indexed-form":
        notifications = instance.get("notifications", [])
        pairs = [
            (f"notifications[{index}]", raw) for index, raw in enumerate(notifications)
        ]
        encoded = urlencode(pairs)
        decoded_values = parse_qs(encoded, keep_blank_values=True, strict_parsing=True)
        indexed: list[tuple[int, str]] = []
        for field, values in decoded_values.items():
            match = re.fullmatch(r"notifications\[(\d+)]", field)
            if match is None or len(values) != 1:
                raise ContractValidationError(
                    f"{fixture_name} produced an invalid indexed form field: {field}"
                )
            indexed.append((int(match.group(1)), values[0]))
        indexed.sort(key=lambda item: item[0])
        if [index for index, _ in indexed] != list(range(len(notifications))):
            raise ContractValidationError(
                f"{fixture_name} has a sparse indexed form array"
            )
        if [value for _, value in indexed] != notifications:
            raise ContractValidationError(
                f"{fixture_name} failed indexed form round trip"
            )
        return

    if encoding is not None:
        raise ContractValidationError(
            f"{fixture_name} uses unknown wire encoding {encoding}"
        )


def decode_base64(value: str, field_name: str) -> bytes:
    try:
        return base64.b64decode(value, validate=True)
    except ValueError as error:
        raise ContractValidationError(
            f"{field_name} is not canonical base64"
        ) from error


def load_rsa_public_key(public_key_pem: str) -> rsa.RSAPublicKey:
    try:
        public_key = serialization.load_pem_public_key(public_key_pem.encode("ascii"))
    except (ValueError, TypeError) as error:
        raise ContractValidationError(
            "userPublicKey is not a valid PEM public key"
        ) from error
    if not isinstance(public_key, rsa.RSAPublicKey) or public_key.key_size != 2048:
        raise ContractValidationError("userPublicKey must contain a 2048-bit RSA key")
    return public_key


def verify_device_identity(instance: dict[str, Any]) -> None:
    public_key = load_rsa_public_key(instance["userPublicKey"])
    identifier_digest = decode_base64(instance["deviceIdentifier"], "deviceIdentifier")
    signature = decode_base64(
        instance["deviceIdentifierSignature"],
        "deviceIdentifierSignature",
    )
    if len(identifier_digest) != hashlib.sha512().digest_size:
        raise ContractValidationError(
            "deviceIdentifier must decode to a SHA-512 digest"
        )
    try:
        public_key.verify(
            signature,
            identifier_digest,
            padding.PKCS1v15(),
            utils.Prehashed(hashes.SHA512()),
        )
    except ValueError as error:
        raise ContractValidationError(
            "device identity signature verification failed"
        ) from error


def simulate_notification_batch(
    envelopes: list[dict[str, Any]],
    identity: dict[str, Any],
) -> dict[str, Any]:
    registered_identifier = identity["deviceIdentifier"]
    registered_token = identity["pushToken"]
    registered_token_hash = hashlib.sha512(registered_token.encode("utf-8")).hexdigest()
    public_key = load_rsa_public_key(identity["userPublicKey"])
    unknown: list[str] = []
    failed = 0

    for envelope in envelopes:
        identifier = envelope["deviceIdentifier"]
        if identifier != registered_identifier:
            if identifier not in unknown:
                unknown.append(identifier)
            continue
        if envelope["pushTokenHash"] != registered_token_hash:
            failed += 1
            continue
        subject = decode_base64(envelope["subject"], "subject")
        signature = decode_base64(envelope["signature"], "signature")
        try:
            public_key.verify(signature, subject, padding.PKCS1v15(), hashes.SHA512())
        except ValueError:
            failed += 1

    return {"unknown": unknown, "failed": failed}


def validate_fixture(
    document: dict[str, Any],
    fixture: dict[str, Any],
) -> tuple[int, int, int]:
    fixture_path = FIXTURE_ROOT / fixture["file"]
    instance = load_json(fixture_path)
    operation = find_operation(document, fixture["operationId"])
    if fixture["direction"] == "request":
        schema = request_schema(document, operation, fixture)
    elif fixture["direction"] == "response":
        schema = response_schema(document, operation, fixture)
    else:
        raise ContractValidationError(
            f"{fixture['name']} has unknown direction {fixture['direction']}"
        )
    schema = expand_references(schema, document)
    errors = validate_json_schema(instance, schema)
    expected_valid = fixture.get("valid", True)
    if expected_valid and errors:
        raise ContractValidationError(
            f"{fixture['name']} unexpectedly violates its schema: " + "; ".join(errors)
        )
    if not expected_valid and not errors:
        raise ContractValidationError(
            f"{fixture['name']} is a negative fixture but the schema accepted it"
        )

    assert_wire_round_trip(fixture["name"], fixture.get("wireEncoding"), instance)

    device_checks = 0
    envelope_checks = 0
    scenario_checks = 0
    if expected_valid and fixture.get("verifyDeviceIdentity"):
        verify_device_identity(instance)
        device_checks += 1

    if (
        expected_valid
        and fixture["direction"] == "request"
        and fixture["operationId"] == "deliverNotifications"
    ):
        envelopes = validate_inner_notifications(document, fixture["name"], instance)
        envelope_checks += len(envelopes)
        identity = load_json(FIXTURE_ROOT / fixture["identityFixture"])
        actual_response = simulate_notification_batch(envelopes, identity)
        expected_response = load_json(FIXTURE_ROOT / fixture["expectedResponse"])
        if actual_response != expected_response:
            raise ContractValidationError(
                f"{fixture['name']} classifies to {actual_response}, expected {expected_response}"
            )
        scenario_checks += 1

    return device_checks, envelope_checks, scenario_checks


def main() -> int:
    try:
        manifest = load_json(MANIFEST_PATH)
        contract_path = (FIXTURE_ROOT / manifest["contract"]).resolve()
        if (
            contract_path.parent != CONTRACT_ROOT
            or contract_path.name != "openapi.json"
        ):
            raise ContractValidationError(
                "Manifest contract must resolve to openapi.json"
            )
        document = load_json(contract_path)
        validate_spec(document)

        fixtures = manifest.get("fixtures")
        if not isinstance(fixtures, list) or not fixtures:
            raise ContractValidationError("Manifest must contain at least one fixture")

        device_checks = 0
        envelope_checks = 0
        scenario_checks = 0
        seen_files: set[str] = set()
        for fixture in fixtures:
            if not isinstance(fixture, dict):
                raise ContractValidationError(
                    "Every fixture manifest entry must be an object"
                )
            fixture_file = fixture.get("file")
            if fixture_file in seen_files:
                raise ContractValidationError(
                    f"Fixture is listed more than once: {fixture_file}"
                )
            seen_files.add(fixture_file)
            counts = validate_fixture(document, fixture)
            device_checks += counts[0]
            envelope_checks += counts[1]
            scenario_checks += counts[2]

        fixture_files = {
            path.name
            for path in FIXTURE_ROOT.glob("*.json")
            if path.name != MANIFEST_PATH.name
        }
        if fixture_files != seen_files:
            missing = sorted(fixture_files - seen_files)
            absent = sorted(seen_files - fixture_files)
            raise ContractValidationError(
                f"Fixture manifest mismatch; unlisted={missing}, missing={absent}"
            )

        print(
            "Validated 1 OpenAPI document, "
            f"{len(fixtures)} fixtures, {device_checks} device signatures, "
            f"{envelope_checks} envelopes and {scenario_checks} batch scenarios."
        )
        return 0
    except (ContractValidationError, KeyError, OSError, json.JSONDecodeError) as error:
        print(f"Contract validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
