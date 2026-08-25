from __future__ import annotations

# ruff: noqa: E402, F403, F405

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
from urllib.request import Request, build_opener

from openapi_spec_validator import validate_spec


_MODULE_ROOT = Path(__file__).resolve().parent
if str(_MODULE_ROOT) not in sys.path:
    sys.path.insert(0, str(_MODULE_ROOT))

from validator_conversation_protocol import *


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
