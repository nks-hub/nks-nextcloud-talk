from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import uuid
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit, urlunsplit
from urllib.request import Request, build_opener

from openapi_spec_validator import validate_spec

from validator_common import (
    CHAT_PATH,
    CONTRACT_ROOT,
    ContractValidationError,
    ENV_NAME,
    FIXTURE_ROOT,
    MANIFEST_PATH,
    MAX_LIVE_RESPONSE_BYTES,
    NoRedirectHandler,
    REQUIRED_FIXTURE_IDS,
    conversation_token,
    load_json,
    require_list,
    require_object,
    require_string,
    require_unique_ids,
)
from validator_merge import validate_merge_cases
from validator_outbox import validate_outbox_cases
from validator_requests import (
    build_wire_request,
    validate_capability_cases,
    validate_query_cases,
    validate_request_against_openapi,
)
from validator_schema import (
    classify_get_response,
    classify_send_response,
    find_operation,
    header_sets,
    ocs_parts,
    response_schema,
    validate_fixture,
    validate_json_schema,
    validate_response_headers,
)


def scan_fixture_secrets(paths: set[Path]) -> None:
    forbidden = [
        re.compile(r"nks-garage", re.IGNORECASE),
        re.compile(r"-----BEGIN (?:RSA |EC )?PRIVATE KEY-----"),
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


def validate_schema_redaction(
    document: dict[str, Any],
    fixture: dict[str, Any],
    headers: dict[str, str],
) -> int:
    private_marker = "PRIVATE_MESSAGE_VALUE_REDACTION_GUARD"
    instance = load_json(FIXTURE_ROOT / fixture["file"])
    _, raw_messages = ocs_parts(instance)
    messages = require_list(raw_messages, "redaction guard messages")
    message = require_object(messages[0], "redaction guard message")
    message["token"] = private_marker
    message["message"] = private_marker
    message["messageParameters"] = {private_marker: {"type": 7}}
    _, operation = find_operation(document, "getChatMessages")
    schema = response_schema(
        document,
        operation,
        "200",
        "application/json",
    )
    rendered = "; ".join(validate_json_schema(instance, schema))
    if not rendered:
        raise ContractValidationError("Schema redaction guard unexpectedly succeeded")
    if private_marker in rendered:
        raise ContractValidationError("Schema diagnostics exposed a payload value")
    if "$.ocs.data[0].token [pattern]" not in rendered:
        raise ContractValidationError(
            "Schema diagnostics lack a sanitized token path and validator"
        )
    if "$.ocs.data[0].messageParameters [oneOf]" not in rendered:
        raise ContractValidationError(
            "Schema diagnostics lost the malformed dynamic-object path"
        )
    validate_response_headers(document, operation, "200", headers)
    return 1


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
    raw_origin = "https://[2001:db8::1]:8443/nextcloud/"
    expected = "https://[2001:db8::1]:8443/nextcloud"
    actual = normalize_live_origin(raw_origin)
    if actual != expected:
        raise ContractValidationError(
            f"Live origin normalization returned {actual}, expected {expected}"
        )
    return 1


def chat_url(origin: str, room_token: str, query: dict[str, str]) -> str:
    parsed = urlsplit(origin)
    path = f"{parsed.path}{CHAT_PATH}/{room_token}"
    return urlunsplit((parsed.scheme, parsed.netloc, path, urlencode(query), ""))


def read_live_body(response: Any) -> bytes:
    content_length = response.headers.get("Content-Length")
    if content_length is not None and int(content_length) > MAX_LIVE_RESPONSE_BYTES:
        raise ContractValidationError("Live response exceeds the byte limit")
    payload = response.read(MAX_LIVE_RESPONSE_BYTES + 1)
    if len(payload) > MAX_LIVE_RESPONSE_BYTES:
        raise ContractValidationError("Live response exceeds the byte limit")
    return payload


def live_response_headers(headers: Any) -> dict[str, str]:
    return {
        name: value
        for name in ("X-Chat-Last-Given", "X-Chat-Last-Common-Read")
        if (value := headers.get(name)) is not None
    }


def fetch_live_response(
    method: str,
    url: str,
    headers: dict[str, str],
    body: dict[str, Any] | None = None,
) -> tuple[str, Any, dict[str, str]]:
    encoded_body = urlencode(body).encode("utf-8") if body is not None else None
    request_headers = {"Accept": "application/json", **headers}
    if encoded_body is not None:
        request_headers["Content-Type"] = "application/x-www-form-urlencoded"
    request = Request(
        url,
        method=method,
        headers=request_headers,
        data=encoded_body,
    )
    opener = build_opener(NoRedirectHandler())
    try:
        with opener.open(request, timeout=20) as response:
            payload = read_live_body(response)
            status = str(response.status)
            response_headers = live_response_headers(response.headers)
    except HTTPError as error:
        if method == "GET" and error.code == 304:
            return "304", None, live_response_headers(error.headers)
        raise ContractValidationError(
            f"Live chat endpoint returned HTTP {error.code}"
        ) from error
    except (URLError, TimeoutError, ValueError) as error:
        raise ContractValidationError("Live chat request failed") from error
    try:
        instance = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ContractValidationError(
            "Live chat endpoint did not return UTF-8 JSON"
        ) from error
    return status, instance, response_headers


def validate_live_get(
    document: dict[str, Any],
    status: str,
    instance: Any,
    headers: dict[str, str],
    room_token: str,
    direction: str,
) -> dict[str, Any]:
    _, operation = find_operation(document, "getChatMessages")
    if status != "304":
        schema = response_schema(document, operation, status, "application/json")
        errors = validate_json_schema(instance, schema)
        if errors:
            raise ContractValidationError(
                "Live chat response violates the schema: " + "; ".join(errors)
            )
    validate_response_headers(document, operation, status, headers)
    result = classify_get_response(
        instance,
        status,
        headers,
        {"roomToken": room_token, "direction": direction},
    )
    if result["classification"] in {"reauth", "ocs-error", "thread-not-found"}:
        raise ContractValidationError(
            f"Live chat GET classified as {result['classification']}"
        )
    return result


def live_credentials(
    username_env: str,
    password_env: str,
    room_token_env: str,
) -> tuple[str, str]:
    if any(
        ENV_NAME.fullmatch(name) is None
        for name in (username_env, password_env, room_token_env)
    ):
        raise ContractValidationError("Live environment variable name is invalid")
    username = os.environ.get(username_env)
    app_password = os.environ.get(password_env)
    room_token = os.environ.get(room_token_env)
    if not username or not app_password or not room_token:
        raise ContractValidationError(
            "Live smoke needs username, app password and test-room token in "
            "the configured environment variables"
        )
    token = conversation_token(room_token, "live test-room token")
    authorization = base64.b64encode(
        f"{username}:{app_password}".encode("utf-8")
    ).decode("ascii")
    return token, f"Basic {authorization}"


def live_read_smoke(
    document: dict[str, Any],
    origin: str,
    room_token: str,
    authorization: str,
) -> tuple[int, str, str]:
    features = ["chat-v2", "chat-keep-notifications"]
    history_request = build_wire_request(
        "fetch",
        {
            "direction": "history",
            "cursor": "0",
            "lastCommonRead": "0",
            "limit": 1,
            "includeLastKnown": True,
            "interactive": False,
        },
        features,
    )
    validate_request_against_openapi(document, history_request)
    status, instance, headers = fetch_live_response(
        "GET",
        chat_url(origin, room_token, history_request["query"]),
        {**history_request["headers"], "Authorization": authorization},
    )
    history_result = validate_live_get(
        document,
        status,
        instance,
        headers,
        room_token,
        "history",
    )
    anchor = history_result.get("cursor") or "0"
    common_read = history_result.get("commonRead") or "0"

    future_request = build_wire_request(
        "fetch",
        {
            "direction": "future",
            "cursor": anchor,
            "lastCommonRead": common_read,
            "limit": 200,
            "timeout": 0,
            "interactive": False,
        },
        features,
    )
    validate_request_against_openapi(document, future_request)
    status, instance, headers = fetch_live_response(
        "GET",
        chat_url(origin, room_token, future_request["query"]),
        {**future_request["headers"], "Authorization": authorization},
    )
    future_result = validate_live_get(
        document,
        status,
        instance,
        headers,
        room_token,
        "future",
    )
    latest_cursor = future_result.get("cursor") or anchor
    latest_common_read = future_result.get("commonRead") or common_read
    return (
        len(history_result.get("messages", []))
        + len(future_result.get("messages", [])),
        latest_cursor,
        latest_common_read,
    )


def live_write_smoke(
    document: dict[str, Any],
    origin: str,
    room_token: str,
    authorization: str,
    anchor: str,
    common_read: str,
    *,
    _fetch_response: Any | None = None,
) -> int:
    fetch_response = fetch_live_response if _fetch_response is None else _fetch_response
    send_reference = str(uuid.uuid4())
    send_request = build_wire_request(
        "send",
        {
            "message": f"Synthetic contract smoke {send_reference}",
            "referenceId": send_reference,
            "federated": False,
        },
        ["chat-v2", "chat-reference-id"],
    )
    validate_request_against_openapi(document, send_request)
    status, instance, headers = fetch_response(
        "POST",
        chat_url(origin, room_token, send_request["query"]),
        {**send_request["headers"], "Authorization": authorization},
        send_request["body"],
    )
    _, operation = find_operation(document, "sendChatMessage")
    schema = response_schema(document, operation, status, "application/json")
    errors = validate_json_schema(instance, schema)
    if errors:
        raise ContractValidationError(
            "Live send response violates the schema: " + "; ".join(errors)
        )
    validate_response_headers(document, operation, status, headers)
    send_result = classify_send_response(
        instance,
        status,
        {"roomToken": room_token, "referenceId": send_reference},
        headers,
    )
    if send_result["classification"] not in {"send-confirmed", "send-unconfirmed"}:
        raise ContractValidationError(
            f"Live send classified as {send_result['classification']}"
        )

    cursor = anchor
    features = ["chat-v2", "chat-keep-notifications"]
    for _ in range(3):
        request = build_wire_request(
            "fetch",
            {
                "direction": "future",
                "cursor": cursor,
                "lastCommonRead": common_read,
                "limit": 200,
                "timeout": 0,
                "interactive": False,
            },
            features,
        )
        validate_request_against_openapi(document, request)
        status, instance, response_headers = fetch_response(
            "GET",
            chat_url(origin, room_token, request["query"]),
            {**request["headers"], "Authorization": authorization},
        )
        result = validate_live_get(
            document,
            status,
            instance,
            response_headers,
            room_token,
            "future",
        )
        matches = [
            message
            for message in result.get("messages", [])
            if message.get("referenceId") == send_reference
            and message.get("token") == room_token
        ]
        if len(matches) == 1:
            return 1
        if len(matches) > 1:
            raise ContractValidationError(
                "Live catch-up found duplicate messages for one referenceId"
            )
        next_cursor = result.get("cursor")
        if next_cursor is None or next_cursor == cursor:
            break
        cursor = next_cursor
        common_read = result.get("commonRead") or common_read
    raise ContractValidationError(
        "Live send was not confirmed by bounded authoritative catch-up"
    )


def resolve_case_path(manifest: dict[str, Any], field: str) -> Path:
    filename = require_string(manifest.get(field), field)
    path = (FIXTURE_ROOT / filename).resolve()
    if path.parent != FIXTURE_ROOT or path.suffix != ".json":
        raise ContractValidationError(f"{field} must stay in the fixtures directory")
    return path


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate the Nextcloud Talk chat messages contract."
    )
    parser.add_argument(
        "--live-origin",
        help="Run two authenticated chat GET requests without read side effects.",
    )
    parser.add_argument(
        "--live-write",
        action="store_true",
        help="Also send one synthetic message and confirm it in a dedicated test room.",
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
    parser.add_argument(
        "--live-room-token-env",
        default="NEXTCLOUD_TALK_TEST_ROOM_TOKEN",
        help="Environment variable containing a read-only test-room token.",
    )
    parser.add_argument(
        "--live-write-room-token-env",
        default="NEXTCLOUD_TALK_WRITE_TEST_ROOM_TOKEN",
        help="Environment variable containing the dedicated mutable test-room token.",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        if arguments.live_write and not arguments.live_origin:
            raise ContractValidationError("--live-write requires --live-origin")
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
        records: dict[str, dict[str, Any]] = {}
        listed_fixture_paths: set[Path] = set()
        schema_valid_count = 0
        accepted_message_count = 0
        for fixture in fixtures:
            result = validate_fixture(document, fixture, sets)
            records[fixture["id"]] = {"metadata": fixture, "result": result}
            listed_fixture_paths.add((FIXTURE_ROOT / fixture["file"]).resolve())
            schema_valid_count += int(fixture["schemaValid"])
            accepted_message_count += len(result.get("messages", []))

        query_path = resolve_case_path(manifest, "queryCasesFile")
        capability_path = resolve_case_path(manifest, "capabilityCasesFile")
        merge_path = resolve_case_path(manifest, "mergeCasesFile")
        outbox_path = resolve_case_path(manifest, "outboxCasesFile")
        query_count = validate_query_cases(document, query_path)
        capability_count = validate_capability_cases(capability_path)
        merge_count, merge_steps = validate_merge_cases(merge_path, records)
        outbox_count, outbox_steps = validate_outbox_cases(outbox_path, records)
        redaction_fixture = next(
            fixture for fixture in fixtures if fixture["id"] == "history-page"
        )
        redaction_count = validate_schema_redaction(
            document,
            redaction_fixture,
            sets[redaction_fixture["headerSet"]],
        )
        origin_count = validate_origin_normalization()

        case_paths = {query_path, capability_path, merge_path, outbox_path}
        listed_paths = listed_fixture_paths | case_paths
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
        scan_fixture_secrets(
            listed_paths | {MANIFEST_PATH.resolve(), contract_path.resolve()}
        )

        live_summary = ""
        if arguments.live_origin:
            room_env = (
                arguments.live_write_room_token_env
                if arguments.live_write
                else arguments.live_room_token_env
            )
            room_token, authorization = live_credentials(
                arguments.live_username_env,
                arguments.live_app_password_env,
                room_env,
            )
            origin = normalize_live_origin(arguments.live_origin)
            read_messages, cursor, common_read = live_read_smoke(
                document,
                origin,
                room_token,
                authorization,
            )
            live_summary = (
                f" Live read smoke accepted {read_messages} messages across two "
                "side-effect-free GET requests without printing payload data."
            )
            if arguments.live_write:
                confirmations = live_write_smoke(
                    document,
                    origin,
                    room_token,
                    authorization,
                    cursor,
                    common_read,
                )
                live_summary += (
                    f" Live write smoke confirmed {confirmations} synthetic message "
                    "through authoritative catch-up."
                )

        print(
            "Validated 1 OpenAPI document, "
            f"{len(fixtures)} fixtures ({schema_valid_count} schema-valid, "
            f"{accepted_message_count} accepted messages), {query_count} query cases, "
            f"{capability_count} capability cases, {merge_count} merge cases with "
            f"{merge_steps} transactional steps, {outbox_count} outbox cases with "
            f"{outbox_steps} lifecycle steps, {redaction_count} schema-redaction guard "
            f"and {origin_count} origin case.{live_summary}"
        )
        return 0
    except (
        ContractValidationError,
        KeyError,
        OSError,
        TypeError,
        ValueError,
        json.JSONDecodeError,
    ) as error:
        print(f"Contract validation failed: {error}", file=sys.stderr)
        return 1
