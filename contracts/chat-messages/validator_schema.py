from __future__ import annotations

from copy import deepcopy
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker

from validator_common import (
    ContractValidationError,
    DECIMAL_CURSOR,
    FIXTURE_ROOT,
    MAX_RETRY_AFTER_SECONDS,
    ResponseSemanticError,
    SCHEMA_PATH_MEMBER,
    canonical_cursor,
    conversation_token,
    load_json,
    reference_id,
    require_integer,
    require_list,
    require_object,
    require_string,
)


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
        reference = require_string(value["$ref"], "$ref")
        if reference in reference_stack:
            raise ContractValidationError(
                f"Circular reference is not supported: {reference}"
            )
        target = deepcopy(resolve_pointer(document, reference))
        siblings = {key: item for key, item in value.items() if key != "$ref"}
        if siblings:
            target_object = require_object(target, f"reference {reference}")
            target_object.update(siblings)
            target = target_object
        return expand_references(
            target,
            document,
            reference_stack + (reference,),
        )
    return {
        key: expand_references(item, document, reference_stack)
        for key, item in value.items()
    }


def find_operation(
    document: dict[str, Any],
    operation_id_value: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    for raw_path_item in document.get("paths", {}).values():
        path_item = require_object(raw_path_item, "OpenAPI path item")
        for method, raw_operation in path_item.items():
            if method.lower() not in {"get", "post", "put", "patch", "delete"}:
                continue
            operation = require_object(raw_operation, "OpenAPI operation")
            if operation.get("operationId") == operation_id_value:
                return path_item, operation
    raise ContractValidationError(f"Unknown operationId: {operation_id_value}")


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


def request_body_schema(
    document: dict[str, Any],
    operation: dict[str, Any],
    media_type: str,
) -> dict[str, Any]:
    try:
        schema = operation["requestBody"]["content"][media_type]["schema"]
    except KeyError as error:
        raise ContractValidationError(
            f"Operation has no {media_type} request schema"
        ) from error
    return require_object(
        expand_references(schema, document),
        "request body schema",
    )


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


def ocs_parts(instance: Any) -> tuple[dict[str, Any], Any]:
    root = require_object(instance, "OCS response")
    ocs = require_object(root.get("ocs"), "OCS envelope")
    meta = require_object(ocs.get("meta"), "OCS metadata")
    return meta, ocs.get("data")


def validate_message_list(
    raw_messages: Any,
    context: dict[str, Any],
) -> list[dict[str, Any]]:
    messages = require_list(raw_messages, "chat message data")
    room_token = conversation_token(context.get("roomToken"), "fixture roomToken")
    direction = require_string(context.get("direction"), "fixture direction")
    if direction not in {"history", "future"}:
        raise ResponseSemanticError(f"Unknown chat direction {direction}")
    thread_id = context.get("threadId")
    if thread_id is not None:
        thread_id = require_integer(thread_id, "fixture threadId", 1)

    typed: list[dict[str, Any]] = []
    ids: list[int] = []
    for index, raw_message in enumerate(messages):
        message = require_object(raw_message, f"message {index}")
        message_id = require_integer(message.get("id"), f"message {index} id", 1)
        if message.get("token") != room_token:
            raise ResponseSemanticError(
                f"Message {index} token does not match its room"
            )
        if thread_id is not None and message.get("threadId") != thread_id:
            raise ResponseSemanticError(
                f"Message {index} does not belong to the requested thread"
            )
        ids.append(message_id)
        typed.append(message)
    if len(ids) != len(set(ids)):
        raise ResponseSemanticError("Chat response contains duplicate message ids")
    if direction == "history" and ids != sorted(ids, reverse=True):
        raise ResponseSemanticError("History response is not strictly descending")
    if direction == "future" and ids != sorted(ids):
        raise ResponseSemanticError("Future response is not strictly ascending")
    return typed


def classify_get_response(
    instance: Any,
    status: str,
    headers: dict[str, str],
    context: dict[str, Any],
) -> dict[str, Any]:
    if status == "304":
        if instance is not None:
            raise ResponseSemanticError("HTTP 304 must not carry a JSON body")
        return {
            "classification": "not-modified",
            "messages": [],
            "cursor": None,
            "commonRead": None,
        }
    if status == "401":
        return {
            "classification": "reauth",
            "messages": [],
            "cursor": None,
            "commonRead": None,
        }
    if status == "404":
        return {
            "classification": "thread-not-found",
            "messages": [],
            "cursor": None,
            "commonRead": None,
        }
    if status in {"429", "503"}:
        return {
            "classification": "transient-error",
            "messages": [],
            "cursor": None,
            "commonRead": None,
        }
    if status != "200":
        raise ResponseSemanticError(f"Unsupported GET fixture status {status}")

    meta, raw_data = ocs_parts(instance)
    if meta.get("status") != "ok" or meta.get("statuscode") != 200:
        return {
            "classification": "ocs-error",
            "messages": [],
            "cursor": None,
            "commonRead": None,
        }
    messages = validate_message_list(raw_data, context)
    raw_cursor = lookup_header(headers, "X-Chat-Last-Given")
    cursor = canonical_cursor(raw_cursor, "X-Chat-Last-Given") if raw_cursor else None
    raw_common_read = lookup_header(headers, "X-Chat-Last-Common-Read")
    common_read = (
        canonical_cursor(raw_common_read, "X-Chat-Last-Common-Read")
        if raw_common_read
        else None
    )
    direction = context["direction"]
    if messages and cursor is None:
        raise ResponseSemanticError("Visible chat messages require a response cursor")
    if messages:
        ids = [message["id"] for message in messages]
        if direction == "history" and int(cursor) > min(ids):
            raise ResponseSemanticError("History cursor moved in the wrong direction")
        if direction == "future" and int(cursor) < max(ids):
            raise ResponseSemanticError("Future cursor moved in the wrong direction")
        classification = "messages"
    elif cursor is not None:
        classification = "invisible-cursor-advance"
    elif common_read is not None:
        classification = "common-read-only"
    else:
        raise ResponseSemanticError(
            "HTTP 200 empty chat response has neither cursor nor common-read change"
        )
    return {
        "classification": classification,
        "messages": messages,
        "cursor": cursor,
        "commonRead": common_read,
    }


def classify_send_response(
    instance: Any,
    status: str,
    context: dict[str, Any],
    headers: dict[str, str],
) -> dict[str, Any]:
    meta, raw_data = ocs_parts(instance)
    error_code = raw_data.get("error") if isinstance(raw_data, dict) else None
    if status == "401":
        return {"classification": "reauth", "messages": [], "messageId": None}
    if status == "429" and error_code == "mentions":
        raw_retry_after = lookup_header(headers, "Retry-After")
        retry_after_seconds = None
        if raw_retry_after is not None and DECIMAL_CURSOR.fullmatch(raw_retry_after):
            retry_after_seconds = min(
                int(raw_retry_after),
                MAX_RETRY_AFTER_SECONDS,
            )
        return {
            "classification": "rate-limited",
            "messages": [],
            "messageId": None,
            "retryAfterSeconds": retry_after_seconds,
        }
    if (
        (status in {"400", "403"} and error_code == "reply-to")
        or (status == "404" and error_code == "actor")
        or (status == "413" and error_code == "message")
    ):
        return {
            "classification": "deterministic-failure",
            "messages": [],
            "messageId": None,
        }
    if status == "400" and error_code == "message":
        return {
            "classification": "send-ambiguous",
            "messages": [],
            "messageId": None,
        }
    if status != "201" or meta.get("status") != "ok" or meta.get("statuscode") != 201:
        return {"classification": "server-error", "messages": [], "messageId": None}
    if raw_data is None:
        return {
            "classification": "send-unconfirmed",
            "messages": [],
            "messageId": None,
        }
    message = require_object(raw_data, "send response message")
    expected_token = conversation_token(context.get("roomToken"), "send roomToken")
    expected_reference = reference_id(
        context.get("referenceId"),
        "send referenceId",
    )
    if (
        message.get("token") != expected_token
        or message.get("referenceId") != expected_reference
    ):
        return {
            "classification": "send-unconfirmed",
            "messages": [message],
            "messageId": None,
        }
    message_id = require_integer(message.get("id"), "send message id", 1)

    reply_to = context.get("replyTo")
    thread_id = context.get("threadId")
    if thread_id is not None:
        thread_id = require_integer(thread_id, "send threadId", 1)
        if reply_to is not None:
            raise ResponseSemanticError("Send context mixes replyTo and threadId")
    if thread_id is not None:
        if message.get("parent") is not None:
            raise ResponseSemanticError("Named-thread response does not match context")
    elif reply_to is not None:
        reply_to = require_integer(reply_to, "send replyTo", 1)
        parent = require_object(message.get("parent"), "send reply parent")
        parent_token = conversation_token(
            context.get("parentRoomToken"),
            "send parentRoomToken",
        )
        if parent.get("token") != parent_token:
            raise ResponseSemanticError("Reply parent token does not match context")
        reply_to_token = context.get("replyToToken")
        if reply_to_token is None:
            if parent.get("id") != reply_to:
                raise ResponseSemanticError("Same-room reply parent id is wrong")
        else:
            reply_to_token = conversation_token(reply_to_token, "send replyToToken")
            metadata = require_object(parent.get("metaData"), "private reply metadata")
            if (
                metadata.get("replyToMessageId") != reply_to
                or metadata.get("replyToConversationToken") != reply_to_token
            ):
                raise ResponseSemanticError("Private reply metadata is incomplete")
    elif message.get("parent") is not None:
        raise ResponseSemanticError("Plain send unexpectedly returned a reply parent")
    if not direct_send_message_has_expected_thread_semantics(
        message,
        requested_thread_id=thread_id,
        reply_to=reply_to,
        private_reply=context.get("replyToToken") is not None,
    ):
        raise ResponseSemanticError("Send response thread does not match context")
    return {
        "classification": "send-confirmed",
        "messages": [message],
        "messageId": message_id,
    }


def classify_read_response(
    instance: Any,
    status: str,
    operation_id_value: str,
    context: dict[str, Any],
    headers: dict[str, str],
) -> dict[str, Any]:
    if status == "401":
        return {"classification": "reauth", "room": None, "messages": []}
    if status != "200":
        return {"classification": "ocs-error", "room": None, "messages": []}
    meta, raw_data = ocs_parts(instance)
    if meta.get("status") != "ok" or meta.get("statuscode") != 200:
        return {"classification": "ocs-error", "room": None, "messages": []}
    room = require_object(raw_data, "read marker room")
    expected_token = conversation_token(context.get("roomToken"), "read roomToken")
    if room.get("token") != expected_token:
        raise ResponseSemanticError("Read marker room token does not match context")
    if operation_id_value == "setChatReadMarker":
        expected_last_read = require_integer(
            context.get("lastReadMessage"),
            "read lastReadMessage",
            1,
        )
        if room.get("lastReadMessage") != expected_last_read:
            raise ResponseSemanticError(
                "Read marker did not confirm its explicit target"
            )
        classification = "read-confirmed"
    else:
        classification = "unread-confirmed"
    common_read = lookup_header(headers, "X-Chat-Last-Common-Read")
    if common_read is not None:
        canonical_cursor(common_read, "X-Chat-Last-Common-Read")
        if int(common_read) != room.get("lastCommonReadMessage"):
            raise ResponseSemanticError("Read response header and room disagree")
    return {"classification": classification, "room": room, "messages": []}


def classify_fixture(
    fixture: dict[str, Any],
    instance: Any,
    headers: dict[str, str],
) -> dict[str, Any]:
    direction = require_string(fixture.get("direction"), "fixture direction")
    if direction == "request":
        return {"classification": "request-valid", "messages": []}
    operation_id_value = require_string(
        fixture.get("operationId"),
        "fixture operationId",
    )
    status = require_string(fixture.get("status"), "fixture status")
    context = require_object(fixture.get("context", {}), "fixture context")
    if operation_id_value == "getChatMessages":
        return classify_get_response(instance, status, headers, context)
    if operation_id_value == "sendChatMessage":
        return classify_send_response(instance, status, context, headers)
    if operation_id_value in {"setChatReadMarker", "markChatUnread"}:
        return classify_read_response(
            instance,
            status,
            operation_id_value,
            context,
            headers,
        )
    raise ContractValidationError(
        f"Fixture uses unsupported operation {operation_id_value}"
    )


def validate_fixture(
    document: dict[str, Any],
    fixture: dict[str, Any],
    sets: dict[str, dict[str, str]],
) -> dict[str, Any]:
    fixture_path = (
        FIXTURE_ROOT / require_string(fixture.get("file"), "fixture file")
    ).resolve()
    if fixture_path.parent != FIXTURE_ROOT or fixture_path.suffix != ".json":
        raise ContractValidationError(f"Invalid fixture path {fixture_path.name}")
    instance = load_json(fixture_path)
    _, operation = find_operation(
        document,
        require_string(fixture.get("operationId"), "fixture operationId"),
    )
    direction = require_string(fixture.get("direction"), "fixture direction")
    media_type = fixture.get("mediaType")
    expected_schema_valid = fixture.get("schemaValid")
    if not isinstance(expected_schema_valid, bool):
        raise ContractValidationError(
            f"Fixture {fixture['id']} needs a boolean schemaValid"
        )

    if direction == "request":
        schema = request_body_schema(
            document,
            operation,
            require_string(media_type, "fixture media type"),
        )
        errors = validate_json_schema(instance, schema)
        headers: dict[str, str] = {}
    elif direction == "response":
        status = require_string(fixture.get("status"), "fixture status")
        if status == "304":
            errors = [] if instance is None else ["$ [null-body]"]
        else:
            schema = response_schema(
                document,
                operation,
                status,
                require_string(media_type, "fixture media type"),
            )
            errors = validate_json_schema(instance, schema)
        header_set_id = require_string(fixture.get("headerSet"), "fixture header set")
        try:
            headers = sets[header_set_id]
        except KeyError as error:
            raise ContractValidationError(
                f"Unknown header set {header_set_id}"
            ) from error
        validate_response_headers(document, operation, status, headers)
    else:
        raise ContractValidationError(f"Unknown fixture direction {direction}")

    if expected_schema_valid and errors:
        raise ContractValidationError(
            f"Fixture {fixture['id']} violates its schema: " + "; ".join(errors)
        )
    if not expected_schema_valid and not errors:
        raise ContractValidationError(
            f"Negative fixture {fixture['id']} was accepted by its schema"
        )
    if not expected_schema_valid:
        return {"classification": "schema-error", "messages": []}

    try:
        result = classify_fixture(fixture, instance, headers)
    except ResponseSemanticError:
        result = {"classification": "semantic-error", "messages": []}
    expected_classification = require_string(
        fixture.get("expectedClassification"),
        "fixture expected classification",
    )
    if result["classification"] != expected_classification:
        raise ContractValidationError(
            f"Fixture {fixture['id']} classified as {result['classification']}, "
            f"expected {expected_classification}"
        )
    if "expectedMessageCount" in fixture:
        expected_count = require_integer(
            fixture["expectedMessageCount"],
            "expectedMessageCount",
            0,
        )
        if len(result.get("messages", [])) != expected_count:
            raise ContractValidationError(
                f"Fixture {fixture['id']} returned "
                f"{len(result.get('messages', []))} messages, expected {expected_count}"
            )
    if (
        "expectedCursor" in fixture
        and result.get("cursor") != fixture["expectedCursor"]
    ):
        raise ContractValidationError(
            f"Fixture {fixture['id']} cursor is {result.get('cursor')}, "
            f"expected {fixture['expectedCursor']}"
        )
    if (
        "expectedMessageId" in fixture
        and result.get("messageId") != fixture["expectedMessageId"]
    ):
        raise ContractValidationError(
            f"Fixture {fixture['id']} message id is {result.get('messageId')}, "
            f"expected {fixture['expectedMessageId']}"
        )
    result["instance"] = instance
    result["headers"] = headers
    return result


def direct_send_message_has_expected_thread_semantics(
    message: dict[str, Any],
    *,
    requested_thread_id: int | None,
    reply_to: int | None,
    private_reply: bool,
) -> bool:
    thread_id = message.get("threadId")
    parent = message.get("parent")
    if requested_thread_id is not None:
        return thread_id == requested_thread_id and parent is None
    if reply_to is None:
        return thread_id == message.get("id") and parent is None
    if not isinstance(parent, dict):
        return False
    if private_reply:
        return thread_id == parent.get("id") and parent.get("threadId") == 0
    parent_thread_id = parent.get("threadId")
    return (
        isinstance(parent_thread_id, int)
        and not isinstance(parent_thread_id, bool)
        and parent_thread_id > 0
        and thread_id == parent_thread_id
    )
