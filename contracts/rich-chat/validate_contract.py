from __future__ import annotations

import argparse
import ipaddress
import json
import re
import sys
from copy import deepcopy
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlencode, urljoin, urlsplit

from jsonschema import Draft202012Validator
from openapi_spec_validator import validate


CONTRACT_ROOT = Path(__file__).resolve().parent
FIXTURE_ROOT = CONTRACT_ROOT / "fixtures"
MANIFEST_PATH = FIXTURE_ROOT / "manifest.json"
USER_AGENT = "com.nkshub.nextcloudtalk rich-chat-contract/0.1"
RENDER_ORIGIN = "https://cloud.example.org"
MAX_RENDER_MESSAGE_CHARS = 1024 * 1024
MAX_RENDER_PARAMETERS = 10_000
HTTP_METHODS = {"get", "post", "put", "delete", "patch", "head", "options"}
ROOM_TOKEN_PATTERN = re.compile(r"^[a-z0-9]{4,30}$")
SNOWFLAKE_PATTERN = re.compile(r"^[1-9][0-9]{0,39}$")
PLACEHOLDER_PATTERN = re.compile(r"\{([A-Za-z0-9_.-]+)\}")
PRIVATE_IPV4_PATTERN = re.compile(r"(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])")

SUCCESS_STATUSES = {
    "getMentionSuggestions": {200},
    "getRecentThreads": {200},
    "getSubscribedThreads": {200},
    "getThread": {200},
    "renameThread": {200},
    "setThreadNotificationLevel": {200},
    "getMessageReactions": {200},
    "addMessageReaction": {200, 201},
    "deleteMessageReaction": {200},
    "editChatMessage": {200, 202},
    "deleteChatMessage": {200, 202},
    "pinChatMessage": {200},
    "unpinChatMessage": {200},
    "hidePinnedChatMessage": {200},
    "getChatReminder": {200},
    "setChatReminder": {201},
    "deleteChatReminder": {200},
    "getScheduledChatMessages": {200},
    "scheduleChatMessage": {201},
    "editScheduledChatMessage": {202},
    "deleteScheduledChatMessage": {200},
}
MUTATION_OPERATIONS = {
    "renameThread",
    "setThreadNotificationLevel",
    "addMessageReaction",
    "deleteMessageReaction",
    "editChatMessage",
    "deleteChatMessage",
    "pinChatMessage",
    "unpinChatMessage",
    "hidePinnedChatMessage",
    "setChatReminder",
    "deleteChatReminder",
    "scheduleChatMessage",
    "editScheduledChatMessage",
    "deleteScheduledChatMessage",
}


class ContractValidationError(RuntimeError):
    pass


class ResponseSemanticError(ContractValidationError):
    pass


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractValidationError(f"{label} must be an object")
    return value


def require_array(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise ContractValidationError(f"{label} must be an array")
    return value


def require_string(
    value: Any,
    label: str,
    *,
    allow_empty: bool = False,
    maximum: int | None = None,
) -> str:
    if not isinstance(value, str):
        raise ContractValidationError(f"{label} must be a string")
    if not allow_empty and not value:
        raise ContractValidationError(f"{label} must not be empty")
    if maximum is not None and len(value) > maximum:
        raise ContractValidationError(f"{label} is too long")
    return value


def require_nonblank_string(
    value: Any,
    label: str,
    *,
    maximum: int | None = None,
) -> str:
    result = require_string(value, label, maximum=maximum)
    if not result.strip():
        raise ContractValidationError(f"{label} must contain non-whitespace text")
    return result


def require_integer(
    value: Any,
    label: str,
    *,
    minimum: int | None = None,
    maximum: int | None = None,
) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ContractValidationError(f"{label} must be an integer")
    if minimum is not None and value < minimum:
        raise ContractValidationError(f"{label} is below its minimum")
    if maximum is not None and value > maximum:
        raise ContractValidationError(f"{label} exceeds its maximum")
    return value


def require_boolean(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise ContractValidationError(f"{label} must be boolean")
    return value


def require_room_token(value: Any, label: str = "roomToken") -> str:
    token = require_string(value, label)
    if ROOM_TOKEN_PATTERN.fullmatch(token) is None:
        raise ContractValidationError(f"{label} must be a canonical room token")
    return token


def require_snowflake(value: Any, label: str = "scheduleId") -> str:
    identifier = require_string(value, label)
    if SNOWFLAKE_PATTERN.fullmatch(identifier) is None:
        raise ContractValidationError(f"{label} must be a numeric-string snowflake")
    return identifier


def ensure_unique_case_ids(cases: list[Any], label: str) -> None:
    identifiers: list[str] = []
    for index, raw_case in enumerate(cases):
        case = require_object(raw_case, f"{label}[{index}]")
        identifiers.append(require_string(case.get("id"), f"{label}[{index}].id"))
    if len(identifiers) != len(set(identifiers)):
        raise ContractValidationError(f"{label} ids must be unique")


def resolve_pointer(document: dict[str, Any], reference: str) -> Any:
    if not reference.startswith("#/"):
        raise ContractValidationError(
            f"Only local OpenAPI references are supported: {reference}"
        )
    current: Any = document
    for encoded_part in reference[2:].split("/"):
        part = encoded_part.replace("~1", "/").replace("~0", "~")
        if not isinstance(current, dict) or part not in current:
            raise ContractValidationError(
                f"OpenAPI reference cannot be resolved: {reference}"
            )
        current = current[part]
    return current


def resolve_reference_object(
    document: dict[str, Any],
    value: Any,
) -> dict[str, Any]:
    item = require_object(value, "OpenAPI component")
    reference = item.get("$ref")
    if reference is None:
        return item
    resolved = require_object(resolve_pointer(document, reference), reference)
    if len(item) == 1:
        return resolved
    merged = deepcopy(resolved)
    merged.update({key: value for key, value in item.items() if key != "$ref"})
    return merged


def expand_schema(
    document: dict[str, Any],
    value: Any,
    references: tuple[str, ...] = (),
) -> Any:
    if isinstance(value, list):
        return [expand_schema(document, item, references) for item in value]
    if not isinstance(value, dict):
        return value
    reference = value.get("$ref")
    if reference is not None:
        if reference in references:
            raise ContractValidationError(
                f"Circular OpenAPI schema reference: {reference}"
            )
        target = expand_schema(
            document,
            resolve_pointer(document, reference),
            references + (reference,),
        )
        siblings = {key: item for key, item in value.items() if key != "$ref"}
        if not siblings:
            return target
        return {
            "allOf": [
                target,
                expand_schema(document, siblings, references),
            ]
        }
    return {
        key: expand_schema(document, item, references) for key, item in value.items()
    }


def operation_index(
    document: dict[str, Any],
) -> dict[str, tuple[str, str, dict[str, Any]]]:
    paths = require_object(document.get("paths"), "OpenAPI paths")
    result: dict[str, tuple[str, str, dict[str, Any]]] = {}
    for path, raw_path_item in paths.items():
        path_item = require_object(raw_path_item, f"OpenAPI path {path}")
        for method, raw_operation in path_item.items():
            if method not in HTTP_METHODS:
                continue
            operation = require_object(raw_operation, f"{method.upper()} {path}")
            operation_id = require_string(
                operation.get("operationId"),
                f"{method.upper()} {path} operationId",
            )
            if operation_id in result:
                raise ContractValidationError(
                    f"Duplicate OpenAPI operationId: {operation_id}"
                )
            result[operation_id] = (path, method.upper(), operation)
    return result


def schema_for_response(
    document: dict[str, Any],
    operation_id: str,
    status: int,
) -> dict[str, Any]:
    operations = operation_index(document)
    if operation_id not in operations:
        raise ContractValidationError(f"Unknown operationId: {operation_id}")
    operation = operations[operation_id][2]
    responses = require_object(
        operation.get("responses"),
        f"{operation_id} responses",
    )
    raw_response = responses.get(str(status))
    if raw_response is None:
        raise ContractValidationError(f"{operation_id} has no response status {status}")
    response = resolve_reference_object(document, raw_response)
    content = require_object(response.get("content"), f"{operation_id} content")
    media = require_object(
        content.get("application/json"),
        f"{operation_id} application/json response",
    )
    return require_object(
        expand_schema(document, media.get("schema")),
        f"{operation_id} response schema",
    )


def validate_schema_instance(
    schema: dict[str, Any],
    instance: Any,
    label: str,
) -> None:
    validator = Draft202012Validator(schema)
    errors = sorted(
        validator.iter_errors(instance),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )
    if not errors:
        return
    first = errors[0]
    path = ".".join(str(part) for part in first.absolute_path) or "<root>"
    raise ContractValidationError(
        f"{label} failed schema at {path} ({first.validator})"
    )


def validate_context(context: dict[str, Any], label: str) -> None:
    if "roomToken" in context:
        require_room_token(context["roomToken"], f"{label}.roomToken")
    for field in ("messageId", "threadId"):
        if field in context:
            require_integer(context[field], f"{label}.{field}", minimum=1)
    if "scheduleId" in context:
        require_snowflake(context["scheduleId"], f"{label}.scheduleId")
    for field in ("actorId", "actorType"):
        if field in context:
            require_string(context[field], f"{label}.{field}", maximum=4096)


def classify_response(
    operation_id: str,
    status: int,
    meta: dict[str, Any],
) -> str:
    if operation_id not in SUCCESS_STATUSES:
        raise ResponseSemanticError(f"Unknown response operation: {operation_id}")
    ocs_status = require_string(meta.get("status"), "OCS meta status")
    ocs_code = require_integer(
        meta.get("statuscode"),
        "OCS meta statuscode",
        minimum=0,
        maximum=999,
    )
    if ocs_code != status:
        raise ResponseSemanticError("HTTP status and OCS statuscode do not match")
    if status in SUCCESS_STATUSES[operation_id]:
        if ocs_status != "ok":
            raise ResponseSemanticError("Successful HTTP response has failed OCS meta")
        return "success"
    if 200 <= status < 300:
        raise ResponseSemanticError(
            f"{operation_id} returned an undocumented success status"
        )
    if ocs_status != "failure":
        raise ResponseSemanticError("Failed HTTP response has successful OCS meta")
    if status == 401:
        return "reauth"
    if 400 <= status < 500:
        return "deterministic-failure"
    if status >= 500 and operation_id in MUTATION_OPERATIONS:
        return "ambiguous"
    if status >= 500:
        return "server-error"
    raise ResponseSemanticError("Unsupported HTTP response status")


def response_data(body: dict[str, Any]) -> Any:
    ocs = require_object(body.get("ocs"), "OCS envelope")
    return ocs.get("data")


def validate_response_binding(
    operation_id: str,
    context: dict[str, Any],
    body: dict[str, Any],
    classification: str,
) -> None:
    if classification != "success":
        return
    data = response_data(body)
    if operation_id in {
        "getRecentThreads",
        "getSubscribedThreads",
    }:
        thread_infos = require_array(data, f"{operation_id} data")
    elif operation_id in {
        "getThread",
        "renameThread",
        "setThreadNotificationLevel",
    }:
        thread_infos = [require_object(data, f"{operation_id} data")]
    else:
        thread_infos = []
    for index, raw_thread_info in enumerate(thread_infos):
        thread_info = require_object(raw_thread_info, f"{operation_id}[{index}]")
        thread = require_object(
            thread_info.get("thread"),
            f"{operation_id}[{index}].thread",
        )
        room_token = require_room_token(
            thread.get("roomToken"),
            f"{operation_id}[{index}].roomToken",
        )
        if "roomToken" in context and room_token != context["roomToken"]:
            raise ResponseSemanticError("Thread response room binding mismatch")
        expected_thread_id = context.get("threadId", context.get("messageId"))
        if expected_thread_id is not None and thread.get("id") != expected_thread_id:
            raise ResponseSemanticError("Thread response id binding mismatch")

    if operation_id in {
        "editChatMessage",
        "deleteChatMessage",
        "pinChatMessage",
        "unpinChatMessage",
    }:
        update = require_object(data, f"{operation_id} data")
        parent = require_object(update.get("parent"), f"{operation_id} parent")
        if parent.get("id") != context.get("messageId"):
            raise ResponseSemanticError("Message mutation parent id mismatch")
        if parent.get("token") != context.get("roomToken"):
            raise ResponseSemanticError("Message mutation parent room mismatch")

    if operation_id in {
        "getChatReminder",
        "setChatReminder",
    }:
        reminder = require_object(data, f"{operation_id} data")
        if reminder.get("messageId") != context.get("messageId"):
            raise ResponseSemanticError("Reminder message binding mismatch")
        if reminder.get("token") != context.get("roomToken"):
            raise ResponseSemanticError("Reminder room binding mismatch")

    if operation_id in {
        "editScheduledChatMessage",
    }:
        scheduled = require_object(data, f"{operation_id} data")
        if scheduled.get("id") != context.get("scheduleId"):
            raise ResponseSemanticError("Scheduled message id binding mismatch")


def validate_response_cases(
    document: dict[str, Any],
    cases: list[Any],
) -> dict[str, dict[str, Any]]:
    ensure_unique_case_ids(cases, "response cases")
    records: dict[str, dict[str, Any]] = {}
    for index, raw_case in enumerate(cases):
        case = require_object(raw_case, f"response cases[{index}]")
        case_id = require_string(case.get("id"), f"response cases[{index}].id")
        operation_id = require_string(
            case.get("operationId"),
            f"response {case_id}.operationId",
        )
        status = require_integer(
            case.get("status"),
            f"response {case_id}.status",
            minimum=100,
            maximum=599,
        )
        context = require_object(
            case.get("context"),
            f"response {case_id}.context",
        )
        validate_context(context, f"response {case_id}.context")
        body = require_object(case.get("body"), f"response {case_id}.body")
        schema = schema_for_response(document, operation_id, status)
        validate_schema_instance(schema, body, f"response {case_id}")
        ocs = require_object(body.get("ocs"), f"response {case_id}.ocs")
        meta = require_object(ocs.get("meta"), f"response {case_id}.meta")
        classification = classify_response(operation_id, status, meta)
        expected = require_string(
            case.get("expectedClassification"),
            f"response {case_id}.expectedClassification",
        )
        if classification != expected:
            raise ContractValidationError(f"Response {case_id} classification mismatch")
        validate_response_binding(operation_id, context, body, classification)
        records[case_id] = {
            "operationId": operation_id,
            "status": status,
            "context": deepcopy(context),
            "classification": classification,
            "data": deepcopy(ocs.get("data")),
        }
    return records


def validate_feature_list(value: Any, label: str) -> set[str]:
    raw_features = require_array(value, label)
    features: list[str] = []
    for index, raw_feature in enumerate(raw_features):
        feature = require_string(raw_feature, f"{label}[{index}]", maximum=128)
        if any(ord(character) < 0x20 for character in feature):
            raise ContractValidationError(f"{label}[{index}] contains a control")
        features.append(feature)
    if len(features) != len(set(features)):
        raise ContractValidationError(f"{label} must not contain duplicates")
    return set(features)


def resolve_capabilities(
    talk_features: Any,
    talk_local_features: Any,
    federated: Any,
    moderator: Any,
    participant_permissions: Any,
) -> dict[str, bool]:
    global_features = validate_feature_list(talk_features, "talkFeatures")
    local_features = validate_feature_list(
        talk_local_features,
        "talkLocalFeatures",
    )
    is_federated = require_boolean(federated, "federated")
    is_moderator = require_boolean(moderator, "moderator")
    permissions = require_integer(
        participant_permissions,
        "participantPermissions",
        minimum=0,
    )
    base = "chat-v2" in global_features
    threads = base and "threads" in global_features
    reactions = base and "reactions" in global_features
    reaction_permission = (
        "react-permission" not in global_features or permissions & 256 == 256
    )
    pinned = base and "pinned-messages" in global_features
    return {
        "mentions": base,
        "threadMetadata": threads,
        "threadMessageFetch": threads and not is_federated,
        "reactions": reactions,
        "canReact": reactions and reaction_permission,
        "edit": base and "edit-messages" in global_features,
        "delete": base and "delete-messages" in global_features,
        "pin": pinned and is_moderator,
        "hidePinned": pinned,
        "reminders": base and "remind-me-later" in global_features,
        "scheduled": (
            base and "scheduled-messages" in local_features and not is_federated
        ),
    }


def resolve_profile(profile: dict[str, Any]) -> dict[str, bool]:
    return resolve_capabilities(
        profile.get("talkFeatures"),
        profile.get("talkLocalFeatures"),
        profile.get("federated"),
        profile.get("moderator"),
        profile.get("participantPermissions"),
    )


def validate_capability_cases(cases: list[Any]) -> int:
    ensure_unique_case_ids(cases, "capability cases")
    for index, raw_case in enumerate(cases):
        case = require_object(raw_case, f"capability cases[{index}]")
        case_id = require_string(case.get("id"), f"capability cases[{index}].id")
        expected_error = case.get("expectedError", False)
        require_boolean(expected_error, f"capability {case_id}.expectedError")
        try:
            actual = resolve_capabilities(
                case.get("talkFeatures"),
                case.get("talkLocalFeatures"),
                case.get("federated"),
                case.get("moderator"),
                case.get("participantPermissions"),
            )
        except ContractValidationError:
            if expected_error:
                continue
            raise
        if expected_error:
            raise ContractValidationError(
                f"Capability case {case_id} unexpectedly succeeded"
            )
        expected = require_object(
            case.get("expected"),
            f"capability {case_id}.expected",
        )
        if actual != expected:
            changed = sorted(set(actual) | set(expected))
            raise ContractValidationError(
                f"Capability case {case_id} differs in fields: " + ", ".join(changed)
            )
    return len(cases)


def require_capability(
    capabilities: dict[str, bool],
    name: str,
    kind: str,
) -> None:
    if capabilities.get(name) is not True:
        raise ContractValidationError(f"{kind} is not allowed by capabilities")


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
        target = message_id()
        level = require_integer(values.get("level"), "level", minimum=0, maximum=3)
        return base_request(
            "setThreadNotificationLevel",
            "POST",
            f"/ocs/v2.php/apps/spreed/api/v1/chat/{token}/threads/{target}/notify",
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
    decoded = parse_qs(
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


def safe_origin(value: str) -> tuple[str, str, int]:
    split = urlsplit(value)
    if split.scheme != "https" or split.hostname is None:
        raise ContractValidationError("Render origin must be canonical HTTPS")
    if split.username is not None or split.password is not None:
        raise ContractValidationError("Render origin must not contain credentials")
    port = split.port or 443
    return split.scheme, split.hostname.lower(), port


def sanitize_link(raw_link: str, server_origin: str) -> str | None:
    if any(ord(character) < 0x20 for character in raw_link):
        return None
    split = urlsplit(raw_link)
    if split.username is not None or split.password is not None:
        return None
    if split.scheme:
        if split.scheme.lower() not in {"https", "mailto", "tel"}:
            return None
        return raw_link
    resolved = urljoin(server_origin, raw_link)
    if safe_origin(resolved) != safe_origin(server_origin):
        return None
    return resolved


def render_contract(
    message: Any,
    markdown: Any,
    raw_parameters: Any,
    *,
    server_origin: str = RENDER_ORIGIN,
) -> dict[str, Any]:
    source = require_string(
        message,
        "render message",
        allow_empty=True,
        maximum=MAX_RENDER_MESSAGE_CHARS,
    )
    use_markdown = require_boolean(markdown, "render markdown")
    parameters = require_object(raw_parameters, "render parameters")
    if len(parameters) > MAX_RENDER_PARAMETERS:
        raise ContractValidationError("Render parameters exceed the node budget")
    for key, raw_parameter in parameters.items():
        if PLACEHOLDER_PATTERN.fullmatch("{" + key + "}") is None:
            raise ContractValidationError("Render parameter key is not canonical")
        parameter = require_object(raw_parameter, f"render parameter {key}")
        require_string(
            parameter.get("type"), f"render parameter {key}.type", maximum=128
        )
        require_string(
            parameter.get("id"),
            f"render parameter {key}.id",
            allow_empty=True,
            maximum=4096,
        )
        require_string(
            parameter.get("name"),
            f"render parameter {key}.name",
            allow_empty=True,
            maximum=4096,
        )

    code_literals: list[str] = []
    prose = source
    if use_markdown:
        fenced = re.compile(r"(?ms)^\x60{3}[^\n]*\n(.*?)^\x60{3}[ \t]*$")

        def replace_fence(match: re.Match[str]) -> str:
            code_literals.append(match.group(1))
            return "\n"

        prose = fenced.sub(replace_fence, prose)
        inline = re.compile(r"\x60([^\x60\n]*)\x60")

        def replace_inline(match: re.Match[str]) -> str:
            code_literals.append(match.group(1))
            return ""

        prose = inline.sub(replace_inline, prose)

    rich_objects = 0

    def replace_placeholder(match: re.Match[str]) -> str:
        nonlocal rich_objects
        if match.group(1) not in parameters:
            return match.group(0)
        rich_objects += 1
        return ""

    rendered_text = PLACEHOLDER_PATTERN.sub(replace_placeholder, prose)
    literal_known = sum(rendered_text.count("{" + key + "}") for key in parameters)
    kinds: set[str] = set()
    if use_markdown:
        if re.search(r"\*\*[^*\n]+\*\*", prose):
            kinds.add("strong")
        if re.search(r"~~[^~\n]+~~", prose):
            kinds.add("strikethrough")
        if re.search(r"(?m)^\|.+\|\s*$\n^\|[\s:|-]+\|\s*$", prose):
            kinds.add("table")
        if re.search(r"(?m)^\s*[-*]\s+\[[ xX]\]\s+", prose):
            kinds.add("taskList")
    active_links: list[str] = []
    if use_markdown:
        link_pattern = re.compile(r"(?<!!)\[[^\]]+\]\(([^)\s]+(?:\([^)]*\))?)\)")
        for match in link_pattern.finditer(prose):
            safe = sanitize_link(match.group(1), server_origin)
            if safe is not None:
                active_links.append(safe)
    return {
        "richObjects": rich_objects,
        "literalKnownPlaceholders": literal_known,
        "codeLiterals": code_literals,
        "text": rendered_text,
        "elementKinds": sorted(kinds),
        "activeLinks": active_links,
    }


def validate_render_cases(cases: list[Any]) -> int:
    ensure_unique_case_ids(cases, "render cases")
    for index, raw_case in enumerate(cases):
        case = require_object(raw_case, f"render cases[{index}]")
        case_id = require_string(case.get("id"), f"render cases[{index}].id")
        result = render_contract(
            case.get("message"),
            case.get("markdown"),
            case.get("parameters"),
        )
        scalar_expectations = {
            "expectedRichObjects": "richObjects",
            "expectedLiteralKnownPlaceholders": "literalKnownPlaceholders",
            "expectedText": "text",
        }
        for fixture_field, result_field in scalar_expectations.items():
            if fixture_field in case and case[fixture_field] != result[result_field]:
                raise ContractValidationError(
                    f"Render case {case_id} differs in {result_field}"
                )
        if "expectedCodeLiteral" in case:
            if case["expectedCodeLiteral"] not in result["codeLiterals"]:
                raise ContractValidationError(
                    f"Render case {case_id} lost a code literal"
                )
        if "expectedElementKinds" in case:
            expected_kinds = set(
                require_array(
                    case["expectedElementKinds"],
                    f"render {case_id}.expectedElementKinds",
                )
            )
            if not expected_kinds.issubset(set(result["elementKinds"])):
                raise ContractValidationError(
                    f"Render case {case_id} lost a required element kind"
                )
        if "forbiddenElementKinds" in case:
            forbidden = set(
                require_array(
                    case["forbiddenElementKinds"],
                    f"render {case_id}.forbiddenElementKinds",
                )
            )
            if forbidden & set(result["elementKinds"]):
                raise ContractValidationError(
                    f"Render case {case_id} activated forbidden markup"
                )
        if "expectedActiveLinks" in case:
            expected_links = require_array(
                case["expectedActiveLinks"],
                f"render {case_id}.expectedActiveLinks",
            )
            if result["activeLinks"] != expected_links:
                raise ContractValidationError(
                    f"Render case {case_id} active-link mismatch"
                )
    return len(cases)


def initial_state() -> dict[str, Any]:
    room = {
        "messages": {
            120: {
                "id": 120,
                "message": "Original text",
                "deleted": False,
                "reactionCounts": {},
                "reactionsSelf": [],
            }
        },
        "threads": {
            120: {
                "firstMessageId": 120,
                "firstMessage": "Original text",
                "lastMessageId": 120,
                "lastMessage": "Original text",
            }
        },
        "previewMessageId": 120,
        "previewMessage": "Original text",
        "reminders": {},
        "schedules": {},
    }
    return {
        "accounts": {
            "account-a": {"rooms": {"rooma123": deepcopy(room)}},
            "account-b": {"rooms": {"rooma123": deepcopy(room)}},
        },
        "automaticReplay": False,
    }


class StatePlan:
    def __init__(
        self,
        source: dict[str, Any],
        candidate: dict[str, Any],
    ) -> None:
        self._source = source
        self._candidate = candidate
        self._consumed = False

    def commit(
        self,
        current: dict[str, Any],
        *,
        persisted: bool,
    ) -> dict[str, Any]:
        if self._consumed:
            raise ContractValidationError("State plan was already consumed")
        self._consumed = True
        if current is not self._source:
            raise ContractValidationError("State plan source is stale")
        return self._candidate if persisted else current


def prepare_state_plan(
    source: dict[str, Any],
    case: dict[str, Any],
    response: dict[str, Any],
) -> StatePlan:
    target_account = require_string(case.get("accountId"), "state accountId")
    request_account = require_string(
        case.get("requestAccountId", target_account),
        "state requestAccountId",
    )
    if request_account != target_account:
        raise ContractValidationError("Response account binding mismatch")
    accounts = require_object(source.get("accounts"), "state accounts")
    if target_account not in accounts:
        raise ContractValidationError("State target account does not exist")
    room_token = require_room_token(case.get("roomToken"))
    account = require_object(accounts[target_account], "state account")
    rooms = require_object(account.get("rooms"), "state rooms")
    if room_token not in rooms:
        raise ContractValidationError("State target room does not exist")
    candidate = deepcopy(source)
    candidate_room = candidate["accounts"][target_account]["rooms"][room_token]
    kind = require_string(case.get("kind"), "state kind")
    data = response["data"]
    classification = response["classification"]

    if kind == "reaction":
        message_id = require_integer(case.get("messageId"), "messageId", minimum=1)
        message = candidate_room["messages"].get(message_id)
        if message is None:
            raise ContractValidationError("Reaction target message does not exist")
        aggregate = require_object(data, "reaction aggregate")
        actor_id = response["context"].get("actorId")
        actor_type = response["context"].get("actorType")
        counts: dict[str, int] = {}
        reactions_self: list[str] = []
        for reaction, raw_actors in aggregate.items():
            require_string(reaction, "reaction aggregate key", maximum=32)
            actors = require_array(raw_actors, "reaction actors")
            counts[reaction] = len(actors)
            if any(
                require_object(actor, "reaction actor").get("actorId") == actor_id
                and require_object(actor, "reaction actor").get("actorType")
                == actor_type
                for actor in actors
            ):
                reactions_self.append(reaction)
        message["reactionCounts"] = counts
        message["reactionsSelf"] = sorted(reactions_self)

    elif kind == "messageMutation":
        message_id = require_integer(case.get("messageId"), "messageId", minimum=1)
        if classification != "success":
            raise ContractValidationError(
                "Message mutation state requires successful response"
            )
        update = require_object(data, "message mutation update")
        parent = require_object(update.get("parent"), "message mutation parent")
        if parent.get("id") != message_id or parent.get("token") != room_token:
            raise ContractValidationError("Message mutation state binding mismatch")
        message = candidate_room["messages"].get(message_id)
        if message is None:
            raise ContractValidationError("Mutation target message does not exist")
        authoritative_text = require_string(
            parent.get("message"),
            "authoritative parent message",
            allow_empty=True,
        )
        message["message"] = authoritative_text
        message["deleted"] = parent.get("deleted") is True
        thread = candidate_room["threads"].get(message_id)
        if thread is not None:
            if thread.get("firstMessageId") == message_id:
                thread["firstMessage"] = authoritative_text
            if thread.get("lastMessageId") == message_id:
                thread["lastMessage"] = authoritative_text
        if candidate_room.get("previewMessageId") == message_id:
            candidate_room["previewMessage"] = authoritative_text

    elif kind == "reminder":
        message_id = require_integer(case.get("messageId"), "messageId", minimum=1)
        reminder = require_object(data, "reminder response")
        if (
            reminder.get("messageId") != message_id
            or reminder.get("token") != room_token
        ):
            raise ContractValidationError("Reminder state binding mismatch")
        candidate_room["reminders"][message_id] = deepcopy(reminder)

    elif kind == "schedule":
        if classification == "ambiguous":
            candidate["automaticReplay"] = False
        elif classification == "success":
            scheduled = require_object(data, "scheduled response")
            schedule_id = require_snowflake(scheduled.get("id"))
            candidate_room["schedules"][schedule_id] = deepcopy(scheduled)
        else:
            raise ContractValidationError("Unsupported schedule classification")

    else:
        raise ContractValidationError(f"Unknown state case kind: {kind}")

    return StatePlan(source, candidate)


def state_summary(
    state: dict[str, Any],
    case: dict[str, Any],
) -> dict[str, Any]:
    account_id = require_string(case.get("accountId"), "state accountId")
    room_token = require_room_token(case.get("roomToken"))
    room = state["accounts"][account_id]["rooms"][room_token]
    kind = case["kind"]
    if kind == "reaction":
        message = room["messages"][case["messageId"]]
        return {
            "reactionCounts": message["reactionCounts"],
            "reactionsSelf": message["reactionsSelf"],
        }
    if kind == "messageMutation":
        message = room["messages"][case["messageId"]]
        thread = room["threads"][case["messageId"]]
        return {
            "message": message["message"],
            "threadFirstMessage": thread["firstMessage"],
            "roomPreviewMessage": room["previewMessage"],
            "deleted": message["deleted"],
        }
    if kind == "reminder":
        message_id = case["messageId"]
        reminder = room["reminders"].get(message_id)
        other_account = "account-b" if account_id == "account-a" else "account-a"
        other_room = state["accounts"][other_account]["rooms"][room_token]
        other_reminder = other_room["reminders"].get(message_id)
        return {
            "targetReminderTimestamp": (
                None if reminder is None else reminder["timestamp"]
            ),
            "otherAccountReminderTimestamp": (
                None if other_reminder is None else other_reminder["timestamp"]
            ),
        }
    if kind == "schedule":
        return {
            "scheduleIds": sorted(room["schedules"]),
            "automaticReplay": state["automaticReplay"],
        }
    raise ContractValidationError(f"Unknown state summary kind: {kind}")


def validate_state_cases(
    cases: list[Any],
    responses: dict[str, dict[str, Any]],
) -> tuple[int, int]:
    ensure_unique_case_ids(cases, "state cases")
    steps = 0
    for index, raw_case in enumerate(cases):
        case = require_object(raw_case, f"state cases[{index}]")
        case_id = require_string(case.get("id"), f"state cases[{index}].id")
        fixture_id = require_string(
            case.get("responseFixture"),
            f"state {case_id}.responseFixture",
        )
        if fixture_id not in responses:
            raise ContractValidationError(
                f"State case {case_id} references unknown response"
            )
        state = initial_state()
        if case.get("expectedRejected", False):
            try:
                prepare_state_plan(state, case, responses[fixture_id])
            except ContractValidationError:
                steps += 1
                continue
            raise ContractValidationError(
                f"State case {case_id} unexpectedly succeeded"
            )
        repeat = require_integer(
            case.get("repeat", 1),
            f"state {case_id}.repeat",
            minimum=1,
            maximum=10,
        )
        transaction = require_string(
            case.get("transaction"),
            f"state {case_id}.transaction",
        )
        if transaction not in {"commit", "fail"}:
            raise ContractValidationError(
                f"State case {case_id} has invalid transaction outcome"
            )
        for _ in range(repeat):
            plan = prepare_state_plan(state, case, responses[fixture_id])
            state = plan.commit(state, persisted=transaction == "commit")
            steps += 1
        expected = require_object(case.get("expected"), f"state {case_id}.expected")
        actual = state_summary(state, case)
        if actual != expected:
            changed = sorted(set(actual) | set(expected))
            raise ContractValidationError(
                f"State case {case_id} differs in fields: " + ", ".join(changed)
            )
    return len(cases), steps


def scan_secrets(paths: set[Path]) -> None:
    credential_pattern = re.compile(
        r'(?i)"(?:password|appPassword|authorization|accessToken|'
        r'firebaseToken|fcmToken|privateKey)"\s*:\s*"(?!REDACTED)[^"]+"'
    )
    fixed_patterns = (
        re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
        re.compile(r"AIza[0-9A-Za-z_-]{35}"),
        re.compile(r"\bPRIVATE_[A-Z0-9_]*GUARD\b"),
        re.compile(r"C:\\Users\\", re.IGNORECASE),
    )
    for path in sorted(paths):
        text = path.read_text(encoding="utf-8")
        if credential_pattern.search(text):
            raise ContractValidationError(f"Potential credential found in {path.name}")
        if any(pattern.search(text) for pattern in fixed_patterns):
            raise ContractValidationError(
                f"Potential private marker found in {path.name}"
            )
        for match in PRIVATE_IPV4_PATTERN.finditer(text):
            try:
                address = ipaddress.ip_address(match.group(0))
            except ValueError:
                continue
            if address.is_private or address.is_loopback or address.is_link_local:
                raise ContractValidationError(
                    f"Private network address found in {path.name}"
                )


def load_cases(
    manifest: dict[str, Any],
    file_field: str,
    count_field: str,
) -> tuple[Path, list[Any]]:
    relative_path = require_string(manifest.get(file_field), file_field)
    path = (FIXTURE_ROOT / relative_path).resolve()
    if path.parent != FIXTURE_ROOT.resolve():
        raise ContractValidationError(f"{file_field} escapes fixture root")
    document = require_object(load_json(path), relative_path)
    cases = require_array(document.get("cases"), f"{relative_path}.cases")
    expected_counts = require_object(
        manifest.get("expectedCounts"),
        "manifest expectedCounts",
    )
    expected = require_integer(
        expected_counts.get(count_field),
        f"expectedCounts.{count_field}",
        minimum=0,
    )
    if len(cases) != expected:
        raise ContractValidationError(f"{relative_path} count differs from manifest")
    return path, cases


def validate_contract() -> dict[str, int]:
    manifest = require_object(load_json(MANIFEST_PATH), "manifest")
    contract_relative = require_string(manifest.get("contract"), "manifest contract")
    contract_path = (FIXTURE_ROOT / contract_relative).resolve()
    if contract_path != (CONTRACT_ROOT / "openapi.json").resolve():
        raise ContractValidationError("Manifest contract path is not canonical")
    document = require_object(load_json(contract_path), "OpenAPI document")
    validate(document)
    operations = operation_index(document)
    if set(operations) != set(SUCCESS_STATUSES):
        raise ContractValidationError(
            "Explicit response policy does not cover every OpenAPI operation"
        )

    response_path, response_cases = load_cases(
        manifest,
        "responsesFile",
        "responses",
    )
    request_path, request_cases = load_cases(
        manifest,
        "requestsFile",
        "requests",
    )
    capability_path, capability_cases = load_cases(
        manifest,
        "capabilitiesFile",
        "capabilities",
    )
    render_path, render_cases = load_cases(
        manifest,
        "renderFile",
        "render",
    )
    state_path, state_cases = load_cases(
        manifest,
        "stateFile",
        "state",
    )

    responses = validate_response_cases(document, response_cases)
    capability_count = validate_capability_cases(capability_cases)
    request_count = validate_request_cases(document, request_cases)
    render_count = validate_render_cases(render_cases)
    state_count, state_steps = validate_state_cases(state_cases, responses)

    listed_paths = {
        response_path,
        request_path,
        capability_path,
        render_path,
        state_path,
    }
    actual_paths = {
        path.resolve()
        for path in FIXTURE_ROOT.glob("*.json")
        if path.name != MANIFEST_PATH.name
    }
    if listed_paths != actual_paths:
        raise ContractValidationError(
            "Rich-chat fixture manifest does not cover every JSON file"
        )
    scan_secrets(
        listed_paths
        | {
            MANIFEST_PATH.resolve(),
            contract_path,
            Path(__file__).resolve(),
            (CONTRACT_ROOT / "test_validate_contract.py").resolve(),
            (CONTRACT_ROOT / "requirements.txt").resolve(),
        }
    )
    return {
        "operations": len(operations),
        "responses": len(responses),
        "requests": request_count,
        "capabilities": capability_count,
        "render": render_count,
        "state": state_count,
        "stateSteps": state_steps,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate the Nextcloud Talk rich-chat contract",
    )
    parser.parse_args(argv)
    try:
        counts = validate_contract()
        print(
            "Validated 1 OpenAPI document, "
            f"{counts['operations']} operations, "
            f"{counts['responses']} response cases, "
            f"{counts['requests']} request cases, "
            f"{counts['capabilities']} capability cases, "
            f"{counts['render']} render cases and "
            f"{counts['state']} state cases with "
            f"{counts['stateSteps']} transactional steps."
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


if __name__ == "__main__":
    raise SystemExit(main())
