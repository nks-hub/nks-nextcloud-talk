from __future__ import annotations

import json
import re
from copy import deepcopy
from pathlib import Path
from typing import Any
from urllib.request import HTTPRedirectHandler, Request

from jsonschema import Draft202012Validator, FormatChecker


CONTRACT_ROOT = Path(__file__).resolve().parent
FIXTURE_ROOT = CONTRACT_ROOT / "fixtures"
MANIFEST_PATH = FIXTURE_ROOT / "manifest.json"
ROOM_PATH = "/ocs/v2.php/apps/spreed/api/v4/room"
USER_AGENT = "com.nkshub.nextcloudtalk conversation-list-contract/0.1"
MAX_LIVE_RESPONSE_BYTES = 8 * 1024 * 1024
EMPTY_CONFIRMATION_WINDOW_SECONDS = 300
DECIMAL_CURSOR = re.compile(r"^(0|[1-9][0-9]*)$")
ENV_NAME = re.compile(r"^[A-Z][A-Z0-9_]{1,127}$")
SCHEMA_PATH_MEMBER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

REQUIRED_FIXTURE_IDS = {
    "compact",
    "talk22",
    "federated",
    "duplicate-token",
    "empty",
    "full",
    "incremental",
    "missing-token",
    "ocs-failure",
    "preview-token-mismatch",
    "unauthorized",
}
REQUIRED_QUERY_IDS = {
    "full-compact",
    "full-preview",
    "full-with-cursor",
    "incremental-compact",
    "incremental-leading-zero",
    "incremental-negative",
    "incremental-zero",
}
REQUIRED_CAPABILITY_IDS = {
    "cursor-v4-wire-profile-confirmed",
    "duplicate-feature-is-invalid",
    "http-error-probe-requires-reauthentication",
    "malformed-cursor-wire-profile-is-unsupported",
    "missing-cursor-wire-profile-is-unsupported",
    "missing-hash-wire-profile-is-unsupported",
    "ocs-error-probe-is-deferred",
    "release-only-is-unsupported",
    "schema-error-probe-is-unsupported",
    "v3-only-is-unsupported",
    "v4-among-other-features",
    "v4-present",
}
REQUIRED_MERGE_IDS = {
    "already-empty-account-accepts-full-empty",
    "configuration-hash-change-refreshes-capabilities",
    "duplicate-token-does-not-advance-cursor",
    "empty-needs-independent-confirmation",
    "expired-empty-proof-is-replaced",
    "full-prunes-missing",
    "incremental-preserves-missing",
    "non-empty-delta-invalidates-empty-proof",
    "ocs-failure-does-not-advance-cursor",
    "preview-mismatch-does-not-advance-cursor",
    "same-empty-request-is-not-independent",
    "same-room-token-remains-account-scoped",
    "schema-error-does-not-advance-cursor",
    "transaction-failure-rolls-back-cursor",
}


class ContractValidationError(RuntimeError):
    pass


class ResponseSemanticError(ContractValidationError):
    pass


class NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(
        self,
        request: Request,
        file_pointer: Any,
        code: int,
        message: str,
        headers: Any,
        new_url: str,
    ) -> None:
        return None


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractValidationError(f"{label} must be an object")
    return value


def require_list(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise ContractValidationError(f"{label} must be an array")
    return value


def require_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ContractValidationError(f"{label} must be a non-empty string")
    return value


def require_unique_ids(
    cases: list[Any],
    required_ids: set[str],
    label: str,
) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    ids: list[str] = []
    for raw_case in cases:
        value = require_object(raw_case, label)
        case_id = require_string(value.get("id"), f"{label} id")
        ids.append(case_id)
        values.append(value)
    if len(ids) != len(set(ids)):
        raise ContractValidationError(f"{label} ids must be unique")
    if set(ids) != required_ids:
        raise ContractValidationError(
            f"{label} coverage mismatch; "
            f"missing={sorted(required_ids - set(ids))}, "
            f"unexpected={sorted(set(ids) - required_ids)}"
        )
    return values


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
        return expand_references(
            target,
            document,
            reference_stack + (reference,),
        )
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


def response_definition(
    document: dict[str, Any],
    operation: dict[str, Any],
    status: str,
) -> dict[str, Any]:
    response = operation.get("responses", {}).get(status)
    if not isinstance(response, dict):
        raise ContractValidationError(f"Operation has no response status {status}")
    return require_object(
        expand_references(response, document),
        f"response {status}",
    )


def response_schema(
    document: dict[str, Any],
    operation: dict[str, Any],
    status: str,
    media_type: str,
) -> dict[str, Any]:
    response = response_definition(document, operation, status)
    try:
        schema = response["content"][media_type]["schema"]
    except KeyError as error:
        raise ContractValidationError(
            f"Response {status} has no {media_type} schema"
        ) from error
    return require_object(schema, f"response {status} schema")


def schema_property_names(schema: dict[str, Any]) -> set[str]:
    names: set[str] = set()

    def visit(value: Any) -> None:
        if isinstance(value, dict):
            properties = value.get("properties")
            if isinstance(properties, dict):
                names.update(
                    name
                    for name in properties
                    if isinstance(name, str)
                    and SCHEMA_PATH_MEMBER.fullmatch(name) is not None
                )
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(schema)
    return names


def summarize_schema_error(error: Any, safe_members: set[str]) -> str:
    path = "$"
    for member in error.absolute_path:
        if isinstance(member, int):
            path += f"[{member}]"
        elif isinstance(member, str) and member in safe_members:
            path += f".{member}"
        else:
            path += "[<member>]"
    validator = error.validator
    if (
        not isinstance(validator, str)
        or SCHEMA_PATH_MEMBER.fullmatch(validator) is None
    ):
        validator = "unknown"
    return f"{path} [{validator}]"


def validate_json_schema(instance: Any, schema: dict[str, Any]) -> list[str]:
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    safe_members = schema_property_names(schema)
    return [
        summarize_schema_error(error, safe_members)
        for error in sorted(
            validator.iter_errors(instance),
            key=lambda item: tuple(str(member) for member in item.absolute_path),
        )
    ]


def lookup_header(headers: dict[str, str], name: str) -> str | None:
    matching = [value for key, value in headers.items() if key.lower() == name.lower()]
    if len(matching) > 1:
        raise ContractValidationError(f"Header {name} is present more than once")
    return matching[0] if matching else None


def validate_response_headers(
    document: dict[str, Any],
    operation: dict[str, Any],
    status: str,
    headers: dict[str, str],
) -> None:
    response = response_definition(document, operation, status)
    declared = require_object(response.get("headers", {}), "response headers")
    for name, raw_definition in declared.items():
        definition = require_object(raw_definition, f"header {name}")
        value = lookup_header(headers, name)
        if definition.get("required", False) and value is None:
            raise ContractValidationError(f"Required response header {name} is absent")
        if value is None:
            continue
        schema = require_object(definition.get("schema"), f"header {name} schema")
        errors = validate_json_schema(value, schema)
        if errors:
            raise ContractValidationError(
                f"Header {name} violates its schema: " + "; ".join(errors)
            )


def ocs_parts(instance: Any) -> tuple[dict[str, Any], Any]:
    root = require_object(instance, "OCS response")
    ocs = require_object(root.get("ocs"), "OCS envelope")
    meta = require_object(ocs.get("meta"), "OCS metadata")
    return meta, ocs.get("data")


def classify_response(
    instance: Any,
    status: str,
) -> tuple[str, list[dict[str, Any]]]:
    meta, raw_data = ocs_parts(instance)
    if status == "401":
        return "reauth", []
    if status != "200":
        raise ResponseSemanticError(f"Unsupported fixture status {status}")
    if meta.get("status") != "ok" or meta.get("statuscode") != 200:
        return "ocs-error", []

    rooms = require_list(raw_data, "OCS conversation data")
    typed_rooms: list[dict[str, Any]] = []
    tokens: list[str] = []
    for index, raw_room in enumerate(rooms):
        room = require_object(raw_room, f"room {index}")
        token = require_string(room.get("token"), f"room {index} token")
        tokens.append(token)
        preview = room.get("lastMessage")
        preview_token = preview.get("token") if isinstance(preview, dict) else None
        remote_token = room.get("remoteToken") if room.get("remoteServer") else None
        # A federated room's preview is forwarded from the remote server: it
        # names the remote conversation, or carries no token at all. A local
        # preview must name its own room.
        if isinstance(preview, dict) and (
            (remote_token is None and preview_token != token)
            or (remote_token is not None and preview_token not in (None, token, remote_token))
        ):
            raise ResponseSemanticError(
                f"Room {index} preview token does not match its room token"
            )
        typed_rooms.append(room)
    if len(tokens) != len(set(tokens)):
        raise ResponseSemanticError("Conversation response contains duplicate tokens")
    return "success", typed_rooms


def header_sets(manifest: dict[str, Any]) -> dict[str, dict[str, str]]:
    raw_sets = require_object(manifest.get("headerSets"), "header sets")
    result: dict[str, dict[str, str]] = {}
    for set_id, raw_headers in raw_sets.items():
        headers = require_object(raw_headers, f"header set {set_id}")
        if any(
            not isinstance(key, str) or not isinstance(value, str)
            for key, value in headers.items()
        ):
            raise ContractValidationError(
                f"Header set {set_id} must contain string names and values"
            )
        result[set_id] = headers
    return result


def validate_fixture(
    document: dict[str, Any],
    fixture: dict[str, Any],
    sets: dict[str, dict[str, str]],
) -> tuple[int, int]:
    if fixture.get("direction") != "response":
        raise ContractValidationError("Conversation fixtures must be responses")
    fixture_path = FIXTURE_ROOT / require_string(
        fixture.get("file"),
        "fixture file",
    )
    instance = load_json(fixture_path)
    operation = find_operation(
        document,
        require_string(fixture.get("operationId"), "fixture operationId"),
    )
    status = require_string(fixture.get("status"), "fixture status")
    media_type = require_string(fixture.get("mediaType"), "fixture media type")
    schema = response_schema(document, operation, status, media_type)
    errors = validate_json_schema(instance, schema)
    expected_schema_valid = fixture.get("schemaValid")
    if not isinstance(expected_schema_valid, bool):
        raise ContractValidationError(
            f"Fixture {fixture['id']} needs a boolean schemaValid"
        )
    if expected_schema_valid and errors:
        raise ContractValidationError(
            f"Fixture {fixture['id']} violates its schema: " + "; ".join(errors)
        )
    if not expected_schema_valid and not errors:
        raise ContractValidationError(
            f"Negative fixture {fixture['id']} was accepted by its schema"
        )
    if not expected_schema_valid:
        return 0, 0

    raw_header_set = fixture.get("headerSet")
    headers: dict[str, str] = {}
    if raw_header_set is not None:
        header_set_id = require_string(raw_header_set, "fixture header set")
        try:
            headers = sets[header_set_id]
        except KeyError as error:
            raise ContractValidationError(
                f"Unknown header set {header_set_id}"
            ) from error
    validate_response_headers(document, operation, status, headers)

    try:
        classification, rooms = classify_response(instance, status)
    except ResponseSemanticError:
        classification, rooms = "semantic-error", []
    if classification == "success":
        validate_cursor_v4_wire_profile(document, headers)
    expected_classification = require_string(
        fixture.get("expectedClassification"),
        "fixture expected classification",
    )
    if classification != expected_classification:
        raise ContractValidationError(
            f"Fixture {fixture['id']} classified as {classification}, "
            f"expected {expected_classification}"
        )
    if "expectedRoomCount" in fixture and len(rooms) != fixture["expectedRoomCount"]:
        raise ContractValidationError(
            f"Fixture {fixture['id']} returned {len(rooms)} rooms, "
            f"expected {fixture['expectedRoomCount']}"
        )
    if fixture.get("expectLastMessageAbsent") and any(
        "lastMessage" in room for room in rooms
    ):
        raise ContractValidationError(
            f"Fixture {fixture['id']} unexpectedly contains a lastMessage"
        )
    return 1, len(rooms)


def request_parameters(
    document: dict[str, Any],
    operation: dict[str, Any],
) -> dict[tuple[str, str], dict[str, Any]]:
    parameters: dict[tuple[str, str], dict[str, Any]] = {}
    for raw_parameter in operation.get("parameters", []):
        parameter = require_object(
            expand_references(raw_parameter, document),
            "operation parameter",
        )
        key = (
            require_string(parameter.get("in"), "parameter location"),
            require_string(parameter.get("name"), "parameter name"),
        )
        if key in parameters:
            raise ContractValidationError(f"Duplicate OpenAPI parameter {key}")
        parameters[key] = parameter
    return parameters


def build_request(
    mode: str,
    cursor: Any,
    include_last_message: Any,
) -> tuple[dict[str, str], dict[str, str]]:
    if not isinstance(include_last_message, bool):
        raise ContractValidationError("includeLastMessage must be boolean")
    if mode not in {"full", "incremental"}:
        raise ContractValidationError(f"Unknown fetch mode {mode}")
    if mode == "full" and cursor is not None:
        raise ContractValidationError("Full fetch must not send modifiedSince")
    if mode == "incremental":
        if not isinstance(cursor, str) or DECIMAL_CURSOR.fullmatch(cursor) is None:
            raise ContractValidationError(
                "Incremental fetch needs a canonical non-negative cursor"
            )
        if len(cursor) > 20:
            raise ContractValidationError("Incremental cursor is too long")

    query = {
        "format": "json",
        "noStatusUpdate": "1",
        "includeStatus": "false",
        "includeLastMessage": str(include_last_message).lower(),
    }
    if mode == "incremental":
        query["modifiedSince"] = cursor
    headers = {
        "OCS-APIRequest": "true",
        "User-Agent": USER_AGENT,
    }
    return query, headers


def coerce_query_value(value: str, schema: dict[str, Any], name: str) -> Any:
    value_type = schema.get("type")
    if value_type == "integer":
        if re.fullmatch(r"-?[0-9]+", value) is None:
            raise ContractValidationError(f"Query parameter {name} is not an integer")
        return int(value)
    if value_type == "boolean":
        if value not in {"true", "false"}:
            raise ContractValidationError(
                f"Query parameter {name} is not a lowercase boolean"
            )
        return value == "true"
    if value_type == "string":
        return value
    raise ContractValidationError(
        f"Unsupported query schema type {value_type} for {name}"
    )


def resolve_conversation_candidate(features: Any) -> str | None:
    values = require_list(features, "Talk features")
    if any(not isinstance(item, str) or not item for item in values):
        raise ContractValidationError("Talk features must contain non-empty strings")
    if len(values) != len(set(values)):
        raise ContractValidationError("Talk features contain duplicates")
    return ROOM_PATH if "conversation-v4" in values else None


def validate_cursor_v4_wire_profile(
    document: dict[str, Any],
    headers: dict[str, str],
) -> str:
    operation = find_operation(document, "getConversationsV4")
    validate_response_headers(document, operation, "200", headers)
    cursor = lookup_header(headers, "X-Nextcloud-Talk-Modified-Before")
    configuration_hash = lookup_header(headers, "X-Nextcloud-Talk-Hash")
    if cursor is None or configuration_hash is None:
        raise ContractValidationError("Cursor-v4 wire profile is incomplete")
    validate_cursor(cursor, "cursor-v4 wire cursor")
    require_string(configuration_hash, "cursor-v4 configuration hash")
    return cursor


def decode_cursor_v4_response(
    document: dict[str, Any],
    status: str,
    instance: Any,
    headers: dict[str, str],
) -> tuple[list[dict[str, Any]], str, str]:
    if status != "200":
        raise ResponseSemanticError("Cursor-v4 probe requires HTTP 200")
    operation = find_operation(document, "getConversationsV4")
    errors = validate_json_schema(
        instance,
        response_schema(document, operation, "200", "application/json"),
    )
    if errors:
        raise ResponseSemanticError(
            "Cursor-v4 response violates the wire schema: " + "; ".join(errors)
        )
    classification, rooms = classify_response(instance, "200")
    if classification != "success":
        raise ResponseSemanticError(
            f"Cursor-v4 response classified as {classification}"
        )
    cursor = validate_cursor_v4_wire_profile(document, headers)
    configuration_hash = lookup_header(headers, "X-Nextcloud-Talk-Hash")
    if configuration_hash is None:
        raise ResponseSemanticError("Cursor-v4 response lacks configuration hash")
    return rooms, cursor, configuration_hash


def negotiate_conversation_profile(
    document: dict[str, Any],
    features: Any,
    raw_probe: Any,
) -> dict[str, Any]:
    candidate_path = resolve_conversation_candidate(features)
    if candidate_path is None:
        return {
            "candidatePath": None,
            "activePath": None,
            "profile": "unsupported",
        }
    if raw_probe is None:
        return {
            "candidatePath": candidate_path,
            "activePath": None,
            "profile": "candidate",
        }

    probe = require_object(raw_probe, "cursor-v4 probe")
    status = require_string(probe.get("status"), "cursor-v4 probe status")
    probe_headers = require_object(probe.get("headers"), "wire probe headers")
    if any(not isinstance(value, str) for value in probe_headers.values()):
        raise ContractValidationError("Wire probe header values must be strings")
    if status == "401":
        return {
            "candidatePath": candidate_path,
            "activePath": None,
            "profile": "reauthentication-required",
        }
    if status != "200":
        reasons = {
            "426": "upgrade-required",
            "429": "rate-limited",
            "503": "service-unavailable",
        }
        return {
            "candidatePath": candidate_path,
            "activePath": None,
            "profile": "deferred",
            "deferralReason": reasons.get(status, "unexpected-http-status"),
        }
    try:
        operation = find_operation(document, "getConversationsV4")
        errors = validate_json_schema(
            probe.get("instance"),
            response_schema(document, operation, "200", "application/json"),
        )
        if errors:
            raise ResponseSemanticError(
                "Cursor-v4 response violates the wire schema: " + "; ".join(errors)
            )
        classification, _ = classify_response(probe.get("instance"), "200")
        if classification == "ocs-error":
            return {
                "candidatePath": candidate_path,
                "activePath": None,
                "profile": "deferred",
                "deferralReason": "ocs-failure",
            }
        decode_cursor_v4_response(
            document,
            status,
            probe.get("instance"),
            probe_headers,
        )
    except ContractValidationError:
        return {
            "candidatePath": candidate_path,
            "activePath": None,
            "profile": "unsupported-wire-profile",
        }
    return {
        "candidatePath": candidate_path,
        "activePath": candidate_path,
        "profile": "cursor-v4",
    }


def validate_capability_cases(
    document: dict[str, Any],
    path: Path,
    fixtures_by_file: dict[str, dict[str, Any]],
) -> int:
    root = require_object(load_json(path), path.name)
    cases = require_unique_ids(
        require_list(root.get("cases"), "capability cases"),
        REQUIRED_CAPABILITY_IDS,
        "capability case",
    )
    for case in cases:
        expected_error = case.get("expectedError", False)
        try:
            probe_fixture_file = case.get("probeFixture")
            probe: dict[str, Any] | None = None
            if probe_fixture_file is not None:
                fixture_file = require_string(
                    probe_fixture_file,
                    "capability probe fixture",
                )
                try:
                    fixture_metadata = fixtures_by_file[fixture_file]
                except KeyError as error:
                    raise ContractValidationError(
                        f"Capability probe references unknown fixture {fixture_file}"
                    ) from error
                probe_headers = require_object(
                    case.get("probeHeaders"),
                    "capability probe headers",
                )
                probe = {
                    "status": fixture_metadata["status"],
                    "instance": load_json(FIXTURE_ROOT / fixture_file),
                    "headers": probe_headers,
                }
            elif case.get("probeHeaders") is not None:
                raise ContractValidationError(
                    "Capability probe headers require a probe fixture"
                )
            actual = negotiate_conversation_profile(
                document,
                case.get("talkFeatures"),
                probe,
            )
        except ContractValidationError:
            if not expected_error:
                raise
        else:
            if expected_error:
                raise ContractValidationError(
                    f"Capability case {case['id']} unexpectedly succeeded"
                )
            expected = require_object(
                case.get("expected"),
                "expected conversation profile",
            )
            if actual != expected:
                raise ContractValidationError(
                    f"Capability case {case['id']} resolved to {actual}, "
                    f"expected {expected}"
                )
    return len(cases)


def validate_cursor(value: Any, label: str, allow_none: bool = False) -> str | None:
    if value is None and allow_none:
        return None
    if not isinstance(value, str) or DECIMAL_CURSOR.fullmatch(value) is None:
        raise ContractValidationError(f"{label} must be a canonical decimal cursor")
    if len(value) > 20:
        raise ContractValidationError(f"{label} is too long")
    return value
