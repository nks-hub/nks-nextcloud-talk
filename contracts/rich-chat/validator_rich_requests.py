from __future__ import annotations

import re
from collections.abc import Callable
from copy import deepcopy
from typing import Any
from urllib.parse import parse_qs, urlencode

from validator_rich_protocol import (
    ContractValidationError,
    USER_AGENT,
    ensure_unique_case_ids,
    expand_schema,
    operation_index,
    require_array,
    require_boolean,
    require_capability,
    require_integer,
    require_nonblank_string,
    require_object,
    require_room_token,
    require_snowflake,
    require_string,
    resolve_profile,
    resolve_reference_object,
    validate_schema_instance,
)


def base_request(
    operation_id: str,
    method: str,
    path: str,
    *,
    query: dict[str, str] | None = None,
    body: dict[str, Any] | None = None,
) -> dict[str, Any]:
    wire_query = {"format": "json"}
    if query is not None:
        wire_query.update(query)
    return {
        "operationId": operation_id,
        "method": method,
        "path": path,
        "query": wire_query,
        "headers": {
            "OCS-APIRequest": "true",
            "User-Agent": USER_AGENT,
        },
        "body": body,
    }


def build_wire_request(
    kind: Any,
    raw_input: Any,
    raw_profile: Any,
) -> dict[str, Any]:
    request_kind = require_string(kind, "request kind")
    values = require_object(raw_input, f"{request_kind} input")
    profile = require_object(raw_profile, f"{request_kind} profile")
    capabilities = resolve_profile(profile)

    def room() -> str:
        return require_room_token(values.get("roomToken"))

    def message_id() -> int:
        return require_integer(values.get("messageId"), "messageId", minimum=1)

    if request_kind == "mentions":
        require_capability(capabilities, "mentions", request_kind)
        token = room()
        search = require_string(
            values.get("search"),
            "search",
            allow_empty=True,
            maximum=4096,
        )
        limit = require_integer(values.get("limit"), "limit", minimum=1, maximum=100)
        include_status = require_boolean(values.get("includeStatus"), "includeStatus")
        return base_request(
            "getMentionSuggestions",
            "GET",
            f"/ocs/v2.php/apps/spreed/api/v1/chat/{token}/mentions",
            query={
                "search": search,
                "limit": str(limit),
                "includeStatus": "1" if include_status else "0",
            },
        )

    if request_kind == "recentThreads":
        require_capability(capabilities, "threadMetadata", request_kind)
        token = room()
        limit = require_integer(values.get("limit"), "limit", minimum=1, maximum=50)
        return base_request(
            "getRecentThreads",
            "GET",
            f"/ocs/v2.php/apps/spreed/api/v1/chat/{token}/threads/recent",
            query={"limit": str(limit)},
        )

    if request_kind == "subscribedThreads":
        require_capability(capabilities, "threadMetadata", request_kind)
        limit = require_integer(values.get("limit"), "limit", minimum=1, maximum=100)
        offset = require_integer(values.get("offset"), "offset", minimum=0)
        return base_request(
            "getSubscribedThreads",
            "GET",
            "/ocs/v2.php/apps/spreed/api/v1/chat/subscribed-threads",
            query={"limit": str(limit), "offset": str(offset)},
        )

    if request_kind in {"getThread", "renameThread"}:
        capability = (
            "threadMessageFetch" if request_kind == "getThread" else "threadMetadata"
        )
        require_capability(capabilities, capability, request_kind)
        token = room()
        thread_id = require_integer(values.get("threadId"), "threadId", minimum=1)
        path = f"/ocs/v2.php/apps/spreed/api/v1/chat/{token}/threads/{thread_id}"
        if request_kind == "getThread":
            return base_request("getThread", "GET", path)
        title = require_nonblank_string(
            values.get("threadTitle"),
            "threadTitle",
            maximum=4096,
        )
        return base_request(
            "renameThread",
            "PUT",
            path,
            body={"threadTitle": title},
        )

    if request_kind == "notifyThread":
        require_capability(capabilities, "threadMetadata", request_kind)
        token = room()
        thread_id = require_integer(values.get("threadId"), "threadId", minimum=1)
        level = require_integer(values.get("level"), "level", minimum=0, maximum=3)
        return base_request(
            "setThreadNotificationLevel",
            "POST",
            f"/ocs/v2.php/apps/spreed/api/v1/chat/{token}/threads/{thread_id}/notify",
            body={"level": level},
        )

    if request_kind in {"getReactions", "addReaction", "deleteReaction"}:
        capability = "canReact" if request_kind == "addReaction" else "reactions"
        require_capability(capabilities, capability, request_kind)
        token = room()
        target = message_id()
        reaction = require_string(
            values.get("reaction"),
            "reaction",
            maximum=32,
        )
        path = f"/ocs/v2.php/apps/spreed/api/v1/reaction/{token}/{target}"
        if request_kind == "getReactions":
            return base_request(
                "getMessageReactions",
                "GET",
                path,
                query={"reaction": reaction},
            )
        if request_kind == "addReaction":
            return base_request(
                "addMessageReaction",
                "POST",
                path,
                body={"reaction": reaction},
            )
        return base_request(
            "deleteMessageReaction",
            "DELETE",
            path,
            body={"reaction": reaction},
        )

    if request_kind in {"editMessage", "deleteMessage"}:
        feature = "edit" if request_kind == "editMessage" else "delete"
        require_capability(capabilities, feature, request_kind)
        token = room()
        target = message_id()
        path = f"/ocs/v2.php/apps/spreed/api/v1/chat/{token}/{target}"
        if request_kind == "editMessage":
            message = require_nonblank_string(values.get("message"), "message")
            return base_request(
                "editChatMessage",
                "PUT",
                path,
                body={"message": message},
            )
        return base_request("deleteChatMessage", "DELETE", path)

    if request_kind in {
        "pinMessage",
        "unpinMessage",
        "hidePinnedMessage",
    }:
        feature = "hidePinned" if request_kind == "hidePinnedMessage" else "pin"
        require_capability(capabilities, feature, request_kind)
        token = room()
        target = message_id()
        suffix = "/pin/self" if request_kind == "hidePinnedMessage" else "/pin"
        path = f"/ocs/v2.php/apps/spreed/api/v1/chat/{token}/{target}{suffix}"
        if request_kind == "pinMessage":
            pin_until = require_integer(values.get("pinUntil"), "pinUntil", minimum=0)
            now = require_integer(values.get("now"), "now", minimum=0)
            if pin_until != 0 and pin_until <= now:
                raise ContractValidationError("pinUntil must be zero or in the future")
            return base_request(
                "pinChatMessage",
                "POST",
                path,
                body={"pinUntil": pin_until},
            )
        operation_id = (
            "unpinChatMessage"
            if request_kind == "unpinMessage"
            else "hidePinnedChatMessage"
        )
        return base_request(operation_id, "DELETE", path)

    if request_kind in {"getReminder", "setReminder", "deleteReminder"}:
        require_capability(capabilities, "reminders", request_kind)
        token = room()
        target = message_id()
        path = f"/ocs/v2.php/apps/spreed/api/v1/chat/{token}/{target}/reminder"
        if request_kind == "getReminder":
            return base_request("getChatReminder", "GET", path)
        if request_kind == "deleteReminder":
            return base_request("deleteChatReminder", "DELETE", path)
        timestamp = require_integer(
            values.get("timestamp"),
            "timestamp",
            minimum=1,
        )
        return base_request(
            "setChatReminder",
            "POST",
            path,
            body={"timestamp": timestamp},
        )

    if request_kind == "getScheduled":
        require_capability(capabilities, "scheduled", request_kind)
        token = room()
        return base_request(
            "getScheduledChatMessages",
            "GET",
            f"/ocs/v2.php/apps/spreed/api/v1/chat/{token}/schedule",
        )

    if request_kind in {"createScheduled", "editScheduled"}:
        require_capability(capabilities, "scheduled", request_kind)
        token = room()
        message = require_nonblank_string(values.get("message"), "message")
        send_at = require_integer(values.get("sendAt"), "sendAt", minimum=1)
        now = require_integer(values.get("now"), "now", minimum=0)
        if send_at <= now:
            raise ContractValidationError("sendAt must be in the future")
        silent = require_boolean(values.get("silent"), "silent")
        thread_title = require_string(
            values.get("threadTitle"),
            "threadTitle",
            allow_empty=True,
            maximum=4096,
        )
        body: dict[str, Any] = {
            "message": message,
            "sendAt": send_at,
            "silent": silent,
            "threadTitle": thread_title,
        }
        if request_kind == "createScheduled":
            thread_id = require_integer(
                values.get("threadId"),
                "threadId",
                minimum=0,
            )
            if (thread_id > 0 or thread_title) and not capabilities["threadMetadata"]:
                raise ContractValidationError(
                    "Scheduled thread fields require threads capability"
                )
            body["threadId"] = thread_id
            path = f"/ocs/v2.php/apps/spreed/api/v1/chat/{token}/schedule"
            return base_request(
                "scheduleChatMessage",
                "POST",
                path,
                body=body,
            )
        schedule_id = require_snowflake(values.get("scheduleId"))
        path = f"/ocs/v2.php/apps/spreed/api/v1/chat/{token}/schedule/{schedule_id}"
        return base_request(
            "editScheduledChatMessage",
            "POST",
            path,
            body=body,
        )

    if request_kind == "deleteScheduled":
        require_capability(capabilities, "scheduled", request_kind)
        token = room()
        schedule_id = require_snowflake(values.get("scheduleId"))
        return base_request(
            "deleteScheduledChatMessage",
            "DELETE",
            f"/ocs/v2.php/apps/spreed/api/v1/chat/{token}/schedule/{schedule_id}",
        )

    raise ContractValidationError(f"Unknown request kind: {request_kind}")


def match_path_template(template: str, actual: str) -> dict[str, str]:
    pattern_parts: list[str] = ["^"]
    cursor = 0
    for match in re.finditer(r"\{([A-Za-z0-9_]+)\}", template):
        pattern_parts.append(re.escape(template[cursor : match.start()]))
        pattern_parts.append(f"(?P<{match.group(1)}>[^/]+)")
        cursor = match.end()
    pattern_parts.append(re.escape(template[cursor:]))
    pattern_parts.append("$")
    match = re.fullmatch("".join(pattern_parts), actual)
    if match is None:
        raise ContractValidationError("Wire path does not match its OpenAPI operation")
    return match.groupdict()


def coerce_wire_scalar(value: Any, schema: dict[str, Any], label: str) -> Any:
    expanded_type = schema.get("type")
    if expanded_type == "integer":
        try:
            return int(value)
        except (TypeError, ValueError) as error:
            raise ContractValidationError(f"{label} is not an integer") from error
    if expanded_type == "boolean":
        if value in {True, "true", "1"}:
            return True
        if value in {False, "false", "0"}:
            return False
        raise ContractValidationError(f"{label} is not boolean")
    if expanded_type == "string":
        if not isinstance(value, str):
            raise ContractValidationError(f"{label} is not a string")
        return value
    return value


def validate_request_against_openapi(
    document: dict[str, Any],
    request: dict[str, Any],
    *,
    _parse_query: Callable[..., dict[str, list[str]]] = parse_qs,
) -> None:
    operation_id = require_string(request.get("operationId"), "wire operationId")
    operations = operation_index(document)
    if operation_id not in operations:
        raise ContractValidationError(f"Unknown wire operationId: {operation_id}")
    template, expected_method, operation = operations[operation_id]
    method = require_string(request.get("method"), "wire method")
    if method != expected_method:
        raise ContractValidationError("Wire method does not match OpenAPI")
    path = require_string(request.get("path"), "wire path")
    path_values = match_path_template(template, path)
    query = require_object(request.get("query"), "wire query")
    headers = require_object(request.get("headers"), "wire headers")
    parameters = require_array(operation.get("parameters", []), "OpenAPI parameters")
    known_query: set[str] = set()
    known_path: set[str] = set()
    for raw_parameter in parameters:
        parameter = resolve_reference_object(document, raw_parameter)
        name = require_string(parameter.get("name"), "OpenAPI parameter name")
        location = require_string(parameter.get("in"), "OpenAPI parameter location")
        required = parameter.get("required", False)
        if not isinstance(required, bool):
            raise ContractValidationError("OpenAPI parameter required must be boolean")
        if location == "query":
            section = query
            known_query.add(name)
        elif location == "path":
            section = path_values
            known_path.add(name)
        elif location == "header":
            section = headers
        else:
            raise ContractValidationError(
                f"Unsupported OpenAPI parameter location: {location}"
            )
        if name not in section:
            if required:
                raise ContractValidationError(
                    f"Required wire {location} field is absent: {name}"
                )
            continue
        schema = require_object(
            expand_schema(document, parameter.get("schema")),
            f"{operation_id} parameter {name}",
        )
        coerced = coerce_wire_scalar(section[name], schema, f"wire {location} {name}")
        validate_schema_instance(schema, coerced, f"wire {location} {name}")
    if set(query) != known_query:
        raise ContractValidationError("Wire query contains unknown fields")
    if set(path_values) != known_path:
        raise ContractValidationError("Wire path parameter mismatch")
    if headers.get("User-Agent") != USER_AGENT:
        raise ContractValidationError("Wire User-Agent is not canonical")

    request_body = operation.get("requestBody")
    body = request.get("body")
    if request_body is None:
        if body is not None:
            raise ContractValidationError("Wire body is not allowed")
        return
    body_component = resolve_reference_object(document, request_body)
    if body is None:
        raise ContractValidationError("Required wire body is absent")
    content = require_object(body_component.get("content"), "request body content")
    form = require_object(
        content.get("application/x-www-form-urlencoded"),
        "form request body",
    )
    schema = require_object(
        expand_schema(document, form.get("schema")),
        "form request schema",
    )
    validate_schema_instance(schema, body, "wire body")
    body_object = require_object(body, "wire body")
    encoded_pairs: list[tuple[str, str]] = []
    for field, raw_value in body_object.items():
        if isinstance(raw_value, bool):
            value = "true" if raw_value else "false"
        else:
            value = str(raw_value)
        encoded_pairs.append((field, value))
    decoded = _parse_query(
        urlencode(encoded_pairs),
        keep_blank_values=True,
        strict_parsing=True,
    )
    if set(decoded) != set(body_object):
        raise ContractValidationError("Form round trip changed wire section: body")
    properties = require_object(schema.get("properties", {}), "form properties")
    for field, raw_value in body_object.items():
        values = decoded.get(field)
        if values is None or len(values) != 1:
            raise ContractValidationError("Form round trip changed wire section: body")
        field_schema = require_object(
            properties.get(field, {}),
            f"form property {field}",
        )
        decoded_value = coerce_wire_scalar(
            values[0],
            field_schema,
            f"form property {field}",
        )
        if decoded_value != raw_value:
            raise ContractValidationError("Form round trip changed wire section: body")


def request_difference_message(
    case_id: str,
    actual: dict[str, Any],
    expected: dict[str, Any],
) -> str:
    fields = [
        field
        for field in (
            "operationId",
            "method",
            "path",
            "query",
            "headers",
            "body",
        )
        if actual.get(field) != expected.get(field)
    ]
    return f"Request case {case_id} differs in wire sections: " + ", ".join(fields)


def validate_request_cases(
    document: dict[str, Any],
    cases: list[Any],
) -> int:
    ensure_unique_case_ids(cases, "request cases")
    for index, raw_case in enumerate(cases):
        case = require_object(raw_case, f"request cases[{index}]")
        case_id = require_string(case.get("id"), f"request cases[{index}].id")
        expected_error = case.get("expectedError", False)
        require_boolean(expected_error, f"request {case_id}.expectedError")
        source_input = deepcopy(case.get("input"))
        source_profile = deepcopy(case.get("profile"))
        try:
            request = build_wire_request(
                case.get("kind"),
                case.get("input"),
                case.get("profile"),
            )
        except ContractValidationError:
            if expected_error:
                continue
            raise
        if expected_error:
            raise ContractValidationError(
                f"Request case {case_id} unexpectedly succeeded"
            )
        validate_request_against_openapi(document, request)
        if case.get("input") != source_input or case.get("profile") != source_profile:
            raise ContractValidationError(f"Request case {case_id} mutated its source")
        expected = require_object(case.get("expected"), f"request {case_id}.expected")
        if request != expected:
            raise ContractValidationError(
                request_difference_message(case_id, request, expected)
            )
    return len(cases)
