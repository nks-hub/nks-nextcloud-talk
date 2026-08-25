from __future__ import annotations

import re
from collections.abc import Callable
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlencode

from validator_common import (
    ContractValidationError,
    REQUIRED_CAPABILITY_IDS,
    REQUIRED_QUERY_IDS,
    USER_AGENT,
    canonical_cursor,
    conversation_token,
    load_json,
    message_text,
    reference_id,
    require_boolean,
    require_integer,
    require_list,
    require_object,
    require_string,
    require_unique_ids,
    safe_mapping_mismatch_fields,
)
from validator_schema import (
    expand_references,
    find_operation,
    request_body_schema,
    validate_json_schema,
)


def normalize_features(value: Any, label: str) -> set[str]:
    features = require_list(value, label)
    if any(not isinstance(feature, str) or not feature for feature in features):
        raise ContractValidationError(f"{label} must contain non-empty strings")
    if len(features) != len(set(features)):
        raise ContractValidationError(f"{label} must not contain duplicates")
    return set(features)


def resolve_capabilities(features: set[str], federated: bool) -> dict[str, bool]:
    read = "chat-v2" in features
    send_text = read and "chat-reference-id" in features
    reply = send_text and "chat-replies" in features
    return {
        "read": read,
        "sendText": send_text,
        "reply": reply,
        "privateReply": reply and "private-reply" in features and not federated,
        "backgroundCatchUp": read and "chat-keep-notifications" in features,
        "threadFetch": read and "threads" in features and not federated,
        "setReadMarker": (
            read and "chat-read-marker" in features and "chat-read-last" in features
        ),
        "markUnread": (
            read and "chat-read-marker" in features and "chat-unread" in features
        ),
    }


def build_wire_request(
    kind: str,
    raw_input: Any,
    raw_capabilities: Any,
) -> dict[str, Any]:
    input_value = require_object(raw_input, "query case input")
    features = normalize_features(raw_capabilities, "query case capabilities")
    headers = {"OCS-APIRequest": "true", "User-Agent": USER_AGENT}
    query: dict[str, str] = {"format": "json"}
    body: dict[str, Any] | None = None

    if kind == "fetch":
        if "chat-v2" not in features:
            raise ContractValidationError("Chat read requires chat-v2")
        direction = require_string(input_value.get("direction"), "fetch direction")
        if direction not in {"history", "future"}:
            raise ContractValidationError(f"Unknown fetch direction {direction}")
        cursor = canonical_cursor(input_value.get("cursor"), "fetch cursor")
        common_read = canonical_cursor(
            input_value.get("lastCommonRead"),
            "fetch lastCommonRead",
        )
        limit = require_integer(input_value.get("limit"), "fetch limit", 1)
        if limit > 200:
            raise ContractValidationError("Fetch limit exceeds 200")
        interactive = require_boolean(
            input_value.get("interactive"),
            "fetch interactive",
        )
        include_last_known = input_value.get("includeLastKnown", False)
        require_boolean(include_last_known, "fetch includeLastKnown")
        timeout = input_value.get("timeout", 0)
        timeout = require_integer(timeout, "fetch timeout", 0)
        if timeout > 30 or (direction == "history" and timeout != 0):
            raise ContractValidationError("Fetch timeout is invalid")
        if not interactive and "chat-keep-notifications" not in features:
            raise ContractValidationError(
                "Background catch-up requires chat-keep-notifications"
            )
        query.update(
            {
                "lookIntoFuture": "1" if direction == "future" else "0",
                "limit": str(limit),
                "lastKnownMessageId": cursor,
                "lastCommonReadId": common_read,
                "timeout": str(timeout),
                "setReadMarker": "0",
                "includeLastKnown": "1" if include_last_known else "0",
                "noStatusUpdate": "0" if interactive else "1",
                "markNotificationsAsRead": "1" if interactive else "0",
            }
        )
        thread_id = input_value.get("threadId")
        if thread_id is not None:
            thread_id = require_integer(thread_id, "fetch threadId", 1)
            federated = require_boolean(
                input_value.get("federated", False),
                "fetch federated",
            )
            if federated or "threads" not in features:
                raise ContractValidationError(
                    "Thread fetch is unsupported for this conversation"
                )
            query["threadId"] = str(thread_id)
        return {
            "method": "GET",
            "query": query,
            "headers": headers,
            "body": None,
            "operationId": "getChatMessages",
        }

    if kind == "send":
        if not {"chat-v2", "chat-reference-id"}.issubset(features):
            raise ContractValidationError(
                "Text send requires chat-v2 and chat-reference-id"
            )
        message = message_text(input_value.get("message"), "send message")
        send_reference = reference_id(
            input_value.get("referenceId"), "send referenceId"
        )
        federated = require_boolean(
            input_value.get("federated", False),
            "send federated",
        )
        body = {"message": message, "referenceId": send_reference}
        reply_to = input_value.get("replyTo")
        thread_id = input_value.get("threadId")
        if thread_id is not None:
            thread_id = require_integer(thread_id, "send threadId", 1)
            if reply_to is not None:
                raise ContractValidationError("Send cannot mix replyTo and threadId")
            if federated or "threads" not in features:
                raise ContractValidationError(
                    "Named-thread send requires local threads capability"
                )
            body["threadId"] = thread_id
        if reply_to is not None:
            reply_to = require_integer(reply_to, "send replyTo", 1)
            if "chat-replies" not in features:
                raise ContractValidationError("Reply requires chat-replies")
            parent_token = conversation_token(
                input_value.get("parentRoomToken"),
                "send parentRoomToken",
            )
            target_token = conversation_token(
                input_value.get("targetRoomToken"),
                "send targetRoomToken",
            )
            body["replyTo"] = reply_to
            if parent_token != target_token:
                if federated:
                    raise ContractValidationError(
                        "Federated cross-room private reply is unsupported"
                    )
                raise ContractValidationError(
                    "Cross-room private reply needs a separate eligibility contract"
                )
        elif any(
            key in input_value
            for key in ("parentRoomToken", "targetRoomToken", "replyToToken")
        ):
            raise ContractValidationError("Reply metadata requires replyTo")
        return {
            "method": "POST",
            "query": query,
            "headers": headers,
            "body": body,
            "operationId": "sendChatMessage",
        }

    if kind == "read":
        resolved = resolve_capabilities(features, False)
        if not resolved["setReadMarker"]:
            raise ContractValidationError(
                "Explicit read requires chat-read-marker and chat-read-last"
            )
        body = {
            "lastReadMessage": require_integer(
                input_value.get("lastReadMessage"),
                "read lastReadMessage",
                1,
            )
        }
        return {
            "method": "POST",
            "query": query,
            "headers": headers,
            "body": body,
            "operationId": "setChatReadMarker",
        }

    if kind == "unread":
        resolved = resolve_capabilities(features, False)
        if not resolved["markUnread"]:
            raise ContractValidationError(
                "Mark unread requires chat-read-marker and chat-unread"
            )
        if input_value:
            raise ContractValidationError("Mark unread does not accept a request body")
        return {
            "method": "DELETE",
            "query": query,
            "headers": headers,
            "body": None,
            "operationId": "markChatUnread",
        }
    raise ContractValidationError(f"Unknown request kind {kind}")


def request_parameters(
    document: dict[str, Any],
    operation: dict[str, Any],
) -> dict[tuple[str, str], dict[str, Any]]:
    result: dict[tuple[str, str], dict[str, Any]] = {}
    for raw_parameter in operation.get("parameters", []):
        parameter = require_object(
            expand_references(raw_parameter, document),
            "operation parameter",
        )
        key = (
            require_string(parameter.get("in"), "parameter location"),
            require_string(parameter.get("name"), "parameter name"),
        )
        if key in result:
            raise ContractValidationError(f"Duplicate OpenAPI parameter {key}")
        result[key] = parameter
    return result


def coerce_wire_value(value: str, schema: dict[str, Any], label: str) -> Any:
    value_type = schema.get("type")
    if value_type == "integer":
        if re.fullmatch(r"-?[0-9]+", value) is None:
            raise ContractValidationError(f"{label} is not an integer")
        return int(value)
    if value_type == "boolean":
        if value not in {"true", "false"}:
            raise ContractValidationError(f"{label} is not a lowercase boolean")
        return value == "true"
    if value_type == "string":
        return value
    raise ContractValidationError(f"Unsupported wire type {value_type} for {label}")


def validate_request_against_openapi(
    document: dict[str, Any],
    built: dict[str, Any],
    *,
    _parse_query: Callable[..., dict[str, list[str]]] = parse_qs,
) -> None:
    _, operation = find_operation(document, built["operationId"])
    parameters = request_parameters(document, operation)
    for location, actual in (
        ("query", require_object(built["query"], "built query")),
        ("header", require_object(built["headers"], "built headers")),
    ):
        declared = {
            name: parameter
            for (parameter_location, name), parameter in parameters.items()
            if parameter_location == location
        }
        normalized_actual = (
            actual
            if location == "query"
            else {key.lower(): value for key, value in actual.items()}
        )
        declared_lookup = (
            declared
            if location == "query"
            else {key.lower(): value for key, value in declared.items()}
        )
        if unexpected := sorted(set(normalized_actual) - set(declared_lookup)):
            if location == "header" and unexpected == ["user-agent"]:
                unexpected = []
            if unexpected:
                raise ContractValidationError(
                    f"Request emitted undeclared {location} values: {unexpected}"
                )
        for name, parameter in declared_lookup.items():
            if parameter.get("required") and name not in normalized_actual:
                raise ContractValidationError(
                    f"Request omitted required {location} value {name}"
                )
            if name not in normalized_actual:
                continue
            schema = require_object(
                expand_references(parameter.get("schema"), document),
                f"{location} {name} schema",
            )
            coerced = coerce_wire_value(
                normalized_actual[name],
                schema,
                f"{location} {name}",
            )
            errors = validate_json_schema(coerced, schema)
            if errors:
                raise ContractValidationError(
                    f"{location} {name} violates OpenAPI: " + "; ".join(errors)
                )

    body = built["body"]
    if body is None:
        if "requestBody" in operation:
            raise ContractValidationError("Request builder omitted a required body")
        return
    schema = request_body_schema(
        document,
        operation,
        "application/x-www-form-urlencoded",
    )
    errors = validate_json_schema(body, schema)
    if errors:
        raise ContractValidationError(
            "Request body violates OpenAPI: " + "; ".join(errors)
        )
    encoded = urlencode(body)
    parsed = _parse_query(encoded, keep_blank_values=True, strict_parsing=True)
    properties = require_object(schema.get("properties"), "request body properties")
    round_trip: dict[str, Any] = {}
    for name, values in parsed.items():
        if len(values) != 1:
            raise ContractValidationError(f"Form field {name} is repeated")
        property_schema = require_object(properties.get(name), f"form field {name}")
        round_trip[name] = coerce_wire_value(values[0], property_schema, name)
    if round_trip != body:
        raise ContractValidationError("Form round trip changed wire section: body")


def validate_query_cases(document: dict[str, Any], path: Path) -> int:
    root = require_object(load_json(path), path.name)
    cases = require_unique_ids(
        require_list(root.get("cases"), "query cases"),
        REQUIRED_QUERY_IDS,
        "query case",
    )
    for case in cases:
        try:
            built = build_wire_request(
                require_string(case.get("kind"), "query case kind"),
                case.get("input"),
                case.get("capabilities"),
            )
            validate_request_against_openapi(document, built)
        except ContractValidationError:
            if case.get("expectedError") is True:
                continue
            raise
        if case.get("expectedError") is True:
            raise ContractValidationError(
                f"Negative query case {case['id']} unexpectedly succeeded"
            )
        expected = require_object(case.get("expected"), "expected wire request")
        actual = {key: built[key] for key in ("method", "query", "headers", "body")}
        if actual != expected:
            mismatched_sections = safe_mapping_mismatch_fields(
                actual,
                expected,
                ("method", "query", "headers", "body"),
            )
            raise ContractValidationError(
                f"Query case {case['id']} differs in wire sections: "
                + ", ".join(mismatched_sections)
            )
    return len(cases)


def validate_capability_cases(path: Path) -> int:
    root = require_object(load_json(path), path.name)
    cases = require_unique_ids(
        require_list(root.get("cases"), "capability cases"),
        REQUIRED_CAPABILITY_IDS,
        "capability case",
    )
    for case in cases:
        try:
            features = normalize_features(
                case.get("talkFeatures"),
                "capability talkFeatures",
            )
            federated = require_boolean(
                case.get("federated"),
                "capability federated",
            )
            actual = resolve_capabilities(features, federated)
        except ContractValidationError:
            if case.get("expectedError") is True:
                continue
            raise
        if case.get("expectedError") is True:
            raise ContractValidationError(
                f"Negative capability case {case['id']} unexpectedly succeeded"
            )
        expected = require_object(case.get("expected"), "expected capabilities")
        if actual != expected:
            raise ContractValidationError(
                f"Capability case {case['id']} produced {actual}, expected {expected}"
            )
    return len(cases)
