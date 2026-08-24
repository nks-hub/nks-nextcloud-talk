from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
from copy import deepcopy
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from jsonschema import Draft202012Validator, FormatChecker
from openapi_spec_validator import validate_spec


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
        if isinstance(preview, dict) and preview.get("token") != token:
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


def validate_request_against_openapi(
    document: dict[str, Any],
    query: dict[str, str],
    headers: dict[str, str],
) -> None:
    operation = find_operation(document, "getConversationsV4")
    parameters = request_parameters(document, operation)
    declared_query = {
        name: parameter
        for (location, name), parameter in parameters.items()
        if location == "query"
    }
    if unexpected := sorted(set(query) - set(declared_query)):
        raise ContractValidationError(
            f"Request builder emitted unknown query parameters: {unexpected}"
        )
    for name, parameter in declared_query.items():
        if parameter.get("required") and name not in query:
            raise ContractValidationError(
                f"Request builder omitted required query parameter {name}"
            )
        if name not in query:
            continue
        schema = require_object(parameter.get("schema"), f"query {name} schema")
        coerced = coerce_query_value(query[name], schema, name)
        errors = validate_json_schema(coerced, schema)
        if errors:
            raise ContractValidationError(
                f"Query parameter {name} violates OpenAPI: " + "; ".join(errors)
            )

    declared_headers = {
        name: parameter
        for (location, name), parameter in parameters.items()
        if location == "header"
    }
    for name, parameter in declared_headers.items():
        value = lookup_header(headers, name)
        if parameter.get("required") and value is None:
            raise ContractValidationError(
                f"Request builder omitted required header {name}"
            )
        if value is None:
            continue
        schema = require_object(parameter.get("schema"), f"header {name} schema")
        errors = validate_json_schema(value, schema)
        if errors:
            raise ContractValidationError(
                f"Request header {name} violates OpenAPI: " + "; ".join(errors)
            )

    encoded = urlencode(query)
    decoded = {
        key: values[-1]
        for key, values in parse_qs(
            encoded,
            keep_blank_values=True,
            strict_parsing=True,
        ).items()
    }
    if decoded != query:
        raise ContractValidationError("Conversation query failed its wire round trip")


def validate_query_cases(document: dict[str, Any], path: Path) -> int:
    root = require_object(load_json(path), path.name)
    expected_headers = require_object(root.get("expectedHeaders"), "expected headers")
    cases = require_unique_ids(
        require_list(root.get("cases"), "query cases"),
        REQUIRED_QUERY_IDS,
        "query case",
    )
    for case in cases:
        expected_error = case.get("expectedError", False)
        try:
            query, headers = build_request(
                require_string(case.get("mode"), "query mode"),
                case.get("cursor"),
                case.get("includeLastMessage"),
            )
            validate_request_against_openapi(document, query, headers)
        except ContractValidationError:
            if not expected_error:
                raise
        else:
            if expected_error:
                raise ContractValidationError(
                    f"Query case {case['id']} unexpectedly succeeded"
                )
            if query != require_object(case.get("expected"), "expected query"):
                raise ContractValidationError(
                    f"Query case {case['id']} returned {query}, "
                    f"expected {case.get('expected')}"
                )
            if headers != expected_headers:
                raise ContractValidationError(
                    f"Query case {case['id']} emitted unexpected headers"
                )
    return len(cases)


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


def initialize_state(raw_accounts: Any) -> dict[str, Any]:
    accounts = require_object(raw_accounts, "initial accounts")
    state: dict[str, Any] = {"accounts": {}}
    for account_id, raw_account in accounts.items():
        require_string(account_id, "accountId")
        account = require_object(raw_account, f"account {account_id}")
        room_tokens = require_list(account.get("roomTokens"), "initial room tokens")
        if any(not isinstance(token, str) or not token for token in room_tokens):
            raise ContractValidationError("Initial room tokens must be strings")
        if len(room_tokens) != len(set(room_tokens)):
            raise ContractValidationError("Initial room tokens must be unique")
        configuration_hash = account.get("configurationHash")
        if configuration_hash is not None and not isinstance(configuration_hash, str):
            raise ContractValidationError("Configuration hash must be string or null")
        state["accounts"][account_id] = {
            "rooms": {token: {"token": token} for token in room_tokens},
            "cursor": validate_cursor(
                account.get("cursor"),
                "initial cursor",
                allow_none=True,
            ),
            "configurationHash": configuration_hash,
            "emptyConfirmation": None,
            "capabilityRefreshRequired": False,
        }
    return state


def account_summary(account: dict[str, Any]) -> dict[str, Any]:
    return {
        "roomTokens": sorted(account["rooms"]),
        "cursor": account["cursor"],
        "configurationHash": account["configurationHash"],
        "emptyConfirmationRequestId": (
            account["emptyConfirmation"]["requestId"]
            if account["emptyConfirmation"] is not None
            else None
        ),
        "capabilityRefreshRequired": account["capabilityRefreshRequired"],
    }


def decode_merge_response(
    document: dict[str, Any],
    fixture_metadata: dict[str, Any],
    headers: dict[str, str],
) -> tuple[list[dict[str, Any]], str, str]:
    instance = load_json(FIXTURE_ROOT / fixture_metadata["file"])
    status = fixture_metadata["status"]
    return decode_cursor_v4_response(
        document,
        status,
        instance,
        headers,
    )


def apply_merge_step(
    state: dict[str, Any],
    step: dict[str, Any],
    document: dict[str, Any],
    fixtures_by_file: dict[str, dict[str, Any]],
    sets: dict[str, dict[str, str]],
) -> tuple[dict[str, Any], str]:
    account_id = require_string(step.get("accountId"), "merge accountId")
    if account_id not in state["accounts"]:
        raise ContractValidationError(f"Unknown merge account {account_id}")
    mode = require_string(step.get("mode"), "merge mode")
    if mode not in {"full", "incremental"}:
        raise ContractValidationError(f"Unknown merge mode {mode}")
    request_id = require_string(step.get("requestId"), "merge requestId")
    fixture_file = require_string(step.get("fixture"), "merge fixture")
    try:
        fixture_metadata = fixtures_by_file[fixture_file]
    except KeyError as error:
        raise ContractValidationError(
            f"Merge references unknown fixture {fixture_file}"
        ) from error
    header_set_id = require_string(step.get("headerSet"), "merge header set")
    try:
        headers = sets[header_set_id]
    except KeyError as error:
        raise ContractValidationError(
            f"Merge references unknown header set {header_set_id}"
        ) from error

    before = deepcopy(state)
    try:
        rooms, cursor, configuration_hash = decode_merge_response(
            document,
            fixture_metadata,
            headers,
        )
    except ContractValidationError:
        return before, "rejected"

    candidate = deepcopy(state)
    account = candidate["accounts"][account_id]
    outcome = "applied"
    if mode == "full" and not rooms and account["rooms"]:
        observed_at = step.get("observedAt")
        if not isinstance(observed_at, int) or observed_at < 0:
            raise ContractValidationError(
                "Full-empty merge needs a non-negative observedAt"
            )
        previous_proof = account["emptyConfirmation"]
        if previous_proof is None:
            account["emptyConfirmation"] = {
                "requestId": request_id,
                "observedAt": observed_at,
            }
            outcome = "confirmation-required"
        elif previous_proof["requestId"] == request_id:
            outcome = "confirmation-required"
        elif (
            0
            <= observed_at - previous_proof["observedAt"]
            <= EMPTY_CONFIRMATION_WINDOW_SECONDS
        ):
            account["rooms"] = {}
            account["emptyConfirmation"] = None
        else:
            account["emptyConfirmation"] = {
                "requestId": request_id,
                "observedAt": observed_at,
            }
            outcome = "confirmation-required"
    elif mode == "full":
        account["rooms"] = {room["token"]: room for room in rooms}
        account["emptyConfirmation"] = None
    else:
        for room in rooms:
            account["rooms"][room["token"]] = room
        if rooms:
            account["emptyConfirmation"] = None

    if outcome == "applied":
        previous_hash = account["configurationHash"]
        if previous_hash is not None and previous_hash != configuration_hash:
            account["capabilityRefreshRequired"] = True
        account["configurationHash"] = configuration_hash
        account["cursor"] = cursor

    transaction = require_string(step.get("transaction"), "merge transaction")
    if transaction == "fail":
        return before, "transaction-error"
    if transaction != "commit":
        raise ContractValidationError(f"Unknown merge transaction {transaction}")

    for other_account_id, other_account in before["accounts"].items():
        if other_account_id == account_id:
            continue
        if candidate["accounts"][other_account_id] != other_account:
            raise ContractValidationError(
                f"Merge for {account_id} changed account {other_account_id}"
            )
    return candidate, outcome


def validate_merge_cases(
    document: dict[str, Any],
    path: Path,
    fixtures_by_file: dict[str, dict[str, Any]],
    sets: dict[str, dict[str, str]],
) -> tuple[int, int]:
    root = require_object(load_json(path), path.name)
    cases = require_unique_ids(
        require_list(root.get("cases"), "merge cases"),
        REQUIRED_MERGE_IDS,
        "merge case",
    )
    step_count = 0
    for case in cases:
        state = initialize_state(case.get("initialAccounts"))
        steps = require_list(case.get("steps"), f"merge case {case['id']} steps")
        if not steps:
            raise ContractValidationError(f"Merge case {case['id']} has no steps")
        for raw_step in steps:
            step = require_object(raw_step, "merge step")
            state, outcome = apply_merge_step(
                state,
                step,
                document,
                fixtures_by_file,
                sets,
            )
            expected_outcome = require_string(
                step.get("expectedOutcome"),
                "expected merge outcome",
            )
            if outcome != expected_outcome:
                raise ContractValidationError(
                    f"Merge case {case['id']} returned {outcome}, "
                    f"expected {expected_outcome}"
                )
            account_id = step["accountId"]
            expected_account = require_object(
                step.get("expectedAccount"),
                "expected account state",
            )
            actual_account = account_summary(state["accounts"][account_id])
            if actual_account != expected_account:
                raise ContractValidationError(
                    f"Merge case {case['id']} state is {actual_account}, "
                    f"expected {expected_account}"
                )
            step_count += 1
    return len(cases), step_count


def walk_json(value: Any) -> Any:
    if isinstance(value, dict):
        for key, item in value.items():
            yield key, item
            yield from walk_json(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk_json(item)


def scan_fixture_secrets(paths: set[Path]) -> None:
    forbidden = [
        re.compile(r"nks-garage", re.IGNORECASE),
        re.compile(r"-----BEGIN (?:RSA )?PRIVATE KEY-----"),
        re.compile(
            r"\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\."
            r"[A-Za-z0-9_-]{10,}\b"
        ),
        re.compile(
            r'"(?:authorization|appPassword|private_key|refresh_token|access_token)"\s*:',
            re.IGNORECASE,
        ),
    ]
    for path in paths:
        raw = path.read_text(encoding="utf-8")
        for pattern in forbidden:
            if pattern.search(raw):
                raise ContractValidationError(
                    f"Fixture secret scan rejected {path.name}: {pattern.pattern}"
                )


def normalize_live_origin(raw_origin: str) -> str:
    try:
        parsed = urlsplit(raw_origin)
        port = parsed.port
    except ValueError as error:
        raise ContractValidationError("Live origin is malformed") from error
    if parsed.scheme.lower() != "https":
        raise ContractValidationError("Live smoke requires an HTTPS origin")
    if not parsed.hostname or parsed.username or parsed.password:
        raise ContractValidationError("Live origin has an invalid authority")
    if parsed.query or parsed.fragment:
        raise ContractValidationError("Live origin must not contain query or fragment")
    hostname = parsed.hostname.encode("idna").decode("ascii").lower()
    authority_hostname = f"[{hostname}]" if ":" in hostname else hostname
    netloc = authority_hostname if port is None else f"{authority_hostname}:{port}"
    path = parsed.path.rstrip("/")
    if "//" in path or "/../" in f"{path}/" or "/./" in f"{path}/":
        raise ContractValidationError("Live origin has a non-canonical base path")
    return urlunsplit(("https", netloc, path, "", ""))


def validate_origin_normalization() -> int:
    cases = {
        "https://[2001:db8::1]:8443/nextcloud/": (
            "https://[2001:db8::1]:8443/nextcloud"
        ),
    }
    for raw_origin, expected in cases.items():
        actual = normalize_live_origin(raw_origin)
        if actual != expected:
            raise ContractValidationError(
                f"Live origin normalization returned {actual}, expected {expected}"
            )
    return len(cases)


def conversation_url(origin: str, query: dict[str, str]) -> str:
    parsed = urlsplit(origin)
    path = f"{parsed.path}{ROOM_PATH}"
    return urlunsplit((parsed.scheme, parsed.netloc, path, urlencode(query), ""))


def fetch_live_response(
    url: str,
    headers: dict[str, str],
) -> tuple[Any, dict[str, str]]:
    request = Request(
        url,
        method="GET",
        headers={"Accept": "application/json", **headers},
    )
    opener = build_opener(NoRedirectHandler())
    try:
        with opener.open(request, timeout=20) as response:
            content_length = response.headers.get("Content-Length")
            if (
                content_length is not None
                and int(content_length) > MAX_LIVE_RESPONSE_BYTES
            ):
                raise ContractValidationError("Live response exceeds the byte limit")
            payload = response.read(MAX_LIVE_RESPONSE_BYTES + 1)
            if len(payload) > MAX_LIVE_RESPONSE_BYTES:
                raise ContractValidationError("Live response exceeds the byte limit")
            if response.status != 200:
                raise ContractValidationError(
                    f"Live room endpoint returned HTTP {response.status}"
                )
            response_headers = {
                name: value
                for name in (
                    "X-Nextcloud-Talk-Hash",
                    "X-Nextcloud-Talk-Modified-Before",
                    "X-Nextcloud-Talk-Federation-Invites",
                )
                if (value := response.headers.get(name)) is not None
            }
    except HTTPError as error:
        raise ContractValidationError(
            f"Live room endpoint returned HTTP {error.code}"
        ) from error
    except (URLError, TimeoutError, ValueError) as error:
        raise ContractValidationError("Live room request failed") from error
    try:
        return json.loads(payload.decode("utf-8")), response_headers
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ContractValidationError(
            "Live room endpoint did not return UTF-8 JSON"
        ) from error


def validate_live_payload(
    document: dict[str, Any],
    instance: Any,
    headers: dict[str, str],
) -> tuple[list[dict[str, Any]], str]:
    rooms, cursor, _ = decode_cursor_v4_response(
        document,
        "200",
        instance,
        headers,
    )
    return rooms, cursor


def validate_live_schema_redaction(
    document: dict[str, Any],
    fixture_metadata: dict[str, Any],
    headers: dict[str, str],
) -> int:
    private_marker = "PRIVATE_ROOM_VALUE_REDACTION_GUARD"
    instance = load_json(FIXTURE_ROOT / fixture_metadata["file"])
    _, raw_rooms = ocs_parts(instance)
    rooms = require_list(raw_rooms, "redaction guard rooms")
    if not rooms:
        raise ContractValidationError("Redaction guard fixture has no rooms")
    room = require_object(rooms[0], "redaction guard room")
    room["token"] = private_marker
    preview = require_object(room.get("lastMessage"), "redaction guard preview")
    parameters = require_object(
        preview.get("messageParameters"),
        "redaction guard parameters",
    )
    parameters[private_marker] = {"type": 7}
    try:
        validate_live_payload(document, instance, headers)
    except ContractValidationError as error:
        rendered_error = str(error)
        if private_marker in rendered_error:
            raise ContractValidationError(
                "Live schema diagnostics exposed a payload value"
            ) from error
        if "$.ocs.data[0].token [pattern]" not in rendered_error:
            raise ContractValidationError(
                "Live schema diagnostics lack a sanitized path and validator"
            ) from error
        if "$.ocs.data[0].lastMessage [anyOf]" not in rendered_error:
            raise ContractValidationError(
                "Live schema diagnostics lost the malformed dynamic object path"
            ) from error
        return 1
    raise ContractValidationError("Live schema redaction guard unexpectedly succeeded")


def live_smoke(
    document: dict[str, Any],
    raw_origin: str,
    username_env: str,
    password_env: str,
) -> tuple[int, int]:
    if (
        ENV_NAME.fullmatch(username_env) is None
        or ENV_NAME.fullmatch(password_env) is None
    ):
        raise ContractValidationError("Credential environment variable name is invalid")
    username = os.environ.get(username_env)
    app_password = os.environ.get(password_env)
    if not username or not app_password:
        raise ContractValidationError(
            f"Live smoke needs credentials in {username_env} and {password_env}"
        )
    origin = normalize_live_origin(raw_origin)
    authorization = base64.b64encode(
        f"{username}:{app_password}".encode("utf-8")
    ).decode("ascii")

    full_query, request_headers = build_request("full", None, False)
    validate_request_against_openapi(document, full_query, request_headers)
    full_payload, full_headers = fetch_live_response(
        conversation_url(origin, full_query),
        {**request_headers, "Authorization": f"Basic {authorization}"},
    )
    full_rooms, cursor = validate_live_payload(
        document,
        full_payload,
        full_headers,
    )

    incremental_query, request_headers = build_request(
        "incremental",
        cursor,
        False,
    )
    validate_request_against_openapi(document, incremental_query, request_headers)
    incremental_payload, incremental_headers = fetch_live_response(
        conversation_url(origin, incremental_query),
        {**request_headers, "Authorization": f"Basic {authorization}"},
    )
    incremental_rooms, _ = validate_live_payload(
        document,
        incremental_payload,
        incremental_headers,
    )
    return len(full_rooms), len(incremental_rooms)


def resolve_case_path(manifest: dict[str, Any], field: str) -> Path:
    filename = require_string(manifest.get(field), field)
    path = (FIXTURE_ROOT / filename).resolve()
    if path.parent != FIXTURE_ROOT or path.suffix != ".json":
        raise ContractValidationError(f"{field} must stay in the fixtures directory")
    return path


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate the Nextcloud Talk conversation list contract."
    )
    parser.add_argument(
        "--live-origin",
        help="Run two authenticated, read-only room GET requests.",
    )
    parser.add_argument(
        "--live-username-env",
        default="NEXTCLOUD_TALK_USERNAME",
        help="Environment variable containing the live login name.",
    )
    parser.add_argument(
        "--live-app-password-env",
        default="NEXTCLOUD_TALK_APP_PASSWORD",
        help="Environment variable containing the live app password.",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        manifest = require_object(load_json(MANIFEST_PATH), MANIFEST_PATH.name)
        contract_path = (FIXTURE_ROOT / manifest["contract"]).resolve()
        if (
            contract_path.parent != CONTRACT_ROOT
            or contract_path.name != "openapi.json"
        ):
            raise ContractValidationError(
                "Manifest contract must resolve to openapi.json"
            )
        document = require_object(load_json(contract_path), contract_path.name)
        validate_spec(document)

        sets = header_sets(manifest)
        fixtures = require_unique_ids(
            require_list(manifest.get("fixtures"), "fixtures"),
            REQUIRED_FIXTURE_IDS,
            "fixture",
        )
        fixtures_by_file: dict[str, dict[str, Any]] = {}
        schema_checks = 0
        room_count = 0
        for fixture in fixtures:
            fixture_file = require_string(fixture.get("file"), "fixture file")
            fixture_path = (FIXTURE_ROOT / fixture_file).resolve()
            if fixture_path.parent != FIXTURE_ROOT or fixture_path.suffix != ".json":
                raise ContractValidationError(f"Invalid fixture path {fixture_file}")
            if fixture_file in fixtures_by_file:
                raise ContractValidationError(
                    f"Fixture file is listed twice: {fixture_file}"
                )
            fixtures_by_file[fixture_file] = fixture
            checked, rooms = validate_fixture(document, fixture, sets)
            schema_checks += checked
            room_count += rooms

        query_path = resolve_case_path(manifest, "queryCasesFile")
        capability_path = resolve_case_path(manifest, "capabilityCasesFile")
        merge_path = resolve_case_path(manifest, "mergeCasesFile")
        query_count = validate_query_cases(document, query_path)
        capability_count = validate_capability_cases(
            document,
            capability_path,
            fixtures_by_file,
        )
        merge_count, merge_steps = validate_merge_cases(
            document,
            merge_path,
            fixtures_by_file,
            sets,
        )
        full_fixture = next(
            fixture for fixture in fixtures if fixture.get("id") == "full"
        )
        full_header_set = require_string(
            full_fixture.get("headerSet"),
            "full fixture header set",
        )
        redaction_guard_count = validate_live_schema_redaction(
            document,
            full_fixture,
            sets[full_header_set],
        )
        origin_case_count = validate_origin_normalization()

        listed_paths = {
            (FIXTURE_ROOT / fixture_file).resolve() for fixture_file in fixtures_by_file
        } | {query_path, capability_path, merge_path}
        actual_paths = {
            path.resolve()
            for path in FIXTURE_ROOT.glob("*.json")
            if path.name != MANIFEST_PATH.name
        }
        if actual_paths != listed_paths:
            raise ContractValidationError(
                "Fixture manifest mismatch; "
                f"unlisted={sorted(path.name for path in actual_paths - listed_paths)}, "
                f"missing={sorted(path.name for path in listed_paths - actual_paths)}"
            )
        scan_fixture_secrets(listed_paths | {MANIFEST_PATH.resolve()})

        live_summary = ""
        if arguments.live_origin:
            full_rooms, incremental_rooms = live_smoke(
                document,
                arguments.live_origin,
                arguments.live_username_env,
                arguments.live_app_password_env,
            )
            live_summary = (
                f" Live smoke validated {full_rooms} full and "
                f"{incremental_rooms} incremental rooms without printing payload data."
            )

        print(
            "Validated 1 OpenAPI document, "
            f"{len(fixtures)} response fixtures ({schema_checks} schema-valid, "
            f"{room_count} accepted rooms), {query_count} query cases, "
            f"{capability_count} capability cases and {merge_count} merge cases "
            f"with {merge_steps} transactional steps, {redaction_guard_count} "
            f"live-schema redaction guard and {origin_case_count} origin case."
            f"{live_summary}"
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
