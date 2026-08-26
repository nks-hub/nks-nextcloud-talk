from __future__ import annotations

import json
import re
from copy import deepcopy
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator


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
    if operation_id == "setThreadNotificationLevel" and "threadId" not in context:
        raise ResponseSemanticError("Thread notification canonical id context missing")
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
        thread_id = require_integer(
            thread.get("id"),
            f"{operation_id}[{index}].thread.id",
            minimum=1,
        )
        last_message_id = require_integer(
            thread.get("lastMessageId"),
            f"{operation_id}[{index}].thread.lastMessageId",
            minimum=0,
        )
        if "roomToken" in context and room_token != context["roomToken"]:
            raise ResponseSemanticError("Thread response room binding mismatch")
        expected_thread_id = context.get("threadId", context.get("messageId"))
        if expected_thread_id is not None and thread_id != expected_thread_id:
            raise ResponseSemanticError("Thread response id binding mismatch")
        for field, expected_message_id in (
            ("first", thread_id),
            ("last", last_message_id),
        ):
            raw_message = thread_info.get(field)
            if raw_message is None:
                continue
            message = require_object(
                raw_message,
                f"{operation_id}[{index}].{field}",
            )
            if message.get("token") != room_token:
                raise ResponseSemanticError(
                    f"Thread {field} message room mismatch"
                )
            if message.get("id") != expected_message_id:
                raise ResponseSemanticError(
                    f"Thread {field} message id mismatch"
                )
            if message.get("threadId") != thread_id:
                raise ResponseSemanticError(
                    f"Thread {field} message thread id mismatch"
                )

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
        "threadMessageFetch": threads,
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
