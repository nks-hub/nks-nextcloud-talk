from __future__ import annotations

import json
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any
from urllib.parse import quote, unquote, urlsplit

from validator_common import (
    CHUNK_NAME,
    CONTROL,
    ContractValidationError,
    DAV_NAMESPACE,
    EXPECTED_CORE_SHAS,
    FIXTURE_ROOT,
    MAX_XML_BYTES,
    MAX_XML_DEPTH,
    MAX_XML_NODES,
    REQUIRED_CAPABILITY_IDS,
    REQUIRED_DAV_PLAN_IDS,
    REQUIRED_DAV_STATUS_IDS,
    REQUIRED_DAV_XML_IDS,
    REQUIRED_WIRE_IDS,
    ResponseSemanticError,
    XML_DECLARATION,
    XML_DECLARED_ENCODING,
    _api_headers,
    _binding,
    _decode_metadata,
    _expected_message_type,
    _metadata_message_type,
    _safe_identifier,
    _uuid,
    _validate_filename,
    _validate_metadata,
    find_operation,
    load_json,
    normalize_relative_path,
    normalize_server,
    request_schema,
    require_boolean,
    require_integer,
    require_list,
    require_object,
    require_string,
    require_unique_ids,
    response_schema,
    safe_mapping_mismatch_fields,
    validate_json_schema,
)


def build_wire_case(kind: str, raw_input: Any) -> dict[str, Any]:
    input_value = require_object(raw_input, "wire case input")
    if kind == "relativePath":
        _, encoded = normalize_relative_path(input_value.get("path"))
        return {"encodedPath": encoded}
    if kind == "responseBinding":
        request = require_object(input_value.get("request"), "request binding")
        response = require_object(input_value.get("response"), "response binding")
        request_binding = _binding(request)
        response_binding = _binding(response)
        if request_binding != response_binding:
            raise ContractValidationError("Response does not match its request binding")
        return {"bound": True}
    if kind not in {"probe", "finalize"}:
        raise ContractValidationError("Unknown wire case kind")
    binding = _binding(input_value)
    server = binding["server"]
    room = binding["roomToken"]
    common = {
        "method": "POST",
        "headers": _api_headers(),
        "binding": binding,
    }
    if kind == "probe":
        raw_names = require_list(input_value.get("fileNames"), "fileNames")
        if not 1 <= len(raw_names) <= 16:
            raise ContractValidationError("fileNames count is outside the contract")
        file_names = [_validate_filename(name, "fileName") for name in raw_names]
        allow_update = require_boolean(input_value.get("allowUpdate"), "allowUpdate")
        return {
            "operationId": "probeAttachmentFolder",
            **common,
            "uri": (
                f"{server}/ocs/v2.php/apps/spreed/api/v1/chat/{room}"
                "/attachment/folder?format=json"
            ),
            "body": {"fileNames": file_names, "allowUpdate": allow_update},
        }
    _, file_path = normalize_relative_path(input_value.get("filePath"))
    del file_path
    metadata = _validate_metadata(input_value.get("metadata", {}))
    expected_message_type = _expected_message_type(
        input_value.get("expectedMessageType")
    )
    if _metadata_message_type(metadata) != expected_message_type:
        raise ContractValidationError(
            "Finalize metadata differs from the job-bound message type"
        )
    encoded_metadata = json.dumps(
        metadata,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    body = {
        "filePath": input_value["filePath"],
        "referenceId": _uuid(input_value.get("referenceId"), "referenceId"),
        "talkMetaData": encoded_metadata,
        "fileName": _validate_filename(input_value.get("fileName"), "fileName"),
        "allowUpdate": require_boolean(input_value.get("allowUpdate"), "allowUpdate"),
    }
    return {
        "operationId": "finalizeAttachment",
        **common,
        "uri": (
            f"{server}/ocs/v2.php/apps/spreed/api/v1/chat/{room}/attachment?format=json"
        ),
        "body": body,
    }


def validate_built_request(document: dict[str, Any], built: dict[str, Any]) -> None:
    operation_id = require_string(built.get("operationId"), "operationId")
    _, _, operation = find_operation(document, operation_id)
    if built.get("method") != "POST":
        raise ContractValidationError("Talk mutation must use POST")
    headers = require_object(built.get("headers"), "request headers")
    if headers != _api_headers():
        raise ContractValidationError("Talk request headers differ from the contract")
    uri = require_string(built.get("uri"), "request URI")
    parsed = urlsplit(uri)
    if parsed.query != "format=json" or parsed.fragment:
        raise ContractValidationError("Talk request query differs from the contract")
    schema = request_schema(document, operation, "application/json")
    errors = validate_json_schema(built.get("body"), schema)
    if errors:
        raise ContractValidationError(
            "Built request violates OpenAPI: " + "; ".join(errors)
        )
    if operation_id == "finalizeAttachment":
        _decode_metadata(require_object(built["body"], "body")["talkMetaData"])


def _normalize_features(value: Any) -> set[str]:
    raw_features = require_list(value, "talkFeatures")
    features = [
        require_string(feature, "Talk feature", maximum=128) for feature in raw_features
    ]
    if len(features) != len(set(features)):
        raise ContractValidationError("Talk features must be unique")
    return set(features)


def resolve_capability_case(raw_case: Any) -> dict[str, Any]:
    case = require_object(raw_case, "capability case")
    snapshot = require_object(case.get("snapshot"), "capability snapshot")
    room = require_object(case.get("room"), "room profile")
    requested = require_object(case.get("requested"), "requested attachment options")
    features = _normalize_features(snapshot.get("talkFeatures"))
    attachments = require_object(snapshot.get("attachments"), "attachment config")
    allowed = require_boolean(attachments.get("allowed"), "attachments.allowed")
    subfolders = require_boolean(
        attachments.get("conversationSubfolders"),
        "attachments.conversationSubfolders",
    )
    federated = require_boolean(room.get("federated"), "room.federated")
    can_post = require_boolean(room.get("canPost"), "room.canPost")
    if snapshot.get("context") != "authenticated":
        return {"supported": False, "reason": "authenticated-capabilities-required"}
    if not allowed:
        return {"supported": False, "reason": "attachments-disabled"}
    if not subfolders:
        return {"supported": False, "reason": "conversation-subfolders-required"}
    if "chat-reference-id" not in features:
        return {"supported": False, "reason": "chat-reference-id-required"}
    if federated:
        return {"supported": False, "reason": "federated-room-unsupported"}
    if not can_post:
        return {"supported": False, "reason": "chat-write-permission-required"}
    allowed_requests = {"caption", "voice", "voiceMime", "reply", "thread", "silent"}
    if set(requested).difference(allowed_requests):
        raise ContractValidationError(
            "Requested attachment options contain an unknown member"
        )
    profile = {
        "caption": "media-caption" in features,
        "voice": "voice-message-sharing" in features,
        "reply": "chat-replies" in features,
        "thread": "threads" in features,
        "silent": "silent-send" in features,
    }
    requirements = (
        ("caption", "media-caption-required"),
        ("voice", "voice-message-sharing-required"),
        ("reply", "chat-replies-required"),
        ("thread", "threads-required"),
        ("silent", "silent-send-required"),
    )
    for option, reason in requirements:
        enabled = requested.get(option, False)
        require_boolean(enabled, f"requested.{option}")
        if enabled and not profile[option]:
            return {"supported": False, "reason": reason}
    if requested.get("voice", False):
        mime = require_string(requested.get("voiceMime"), "voiceMime", maximum=128)
        if mime not in {"audio/mpeg", "audio/wav"}:
            return {"supported": False, "reason": "voice-mime-unsupported"}
    elif "voiceMime" in requested:
        raise ContractValidationError("voiceMime requires requested.voice")
    return {"supported": True, "reason": None, "profile": profile}


def validate_capability_cases(path: Path) -> int:
    root = require_object(load_json(path), path.name)
    cases = require_unique_ids(
        root.get("cases"),
        REQUIRED_CAPABILITY_IDS,
        "capability case",
    )
    for case in cases:
        try:
            actual = resolve_capability_case(case)
        except ContractValidationError:
            if case.get("expectedError") is True:
                continue
            raise
        if case.get("expectedError") is True:
            raise ContractValidationError(
                f"Negative capability case {case['id']} unexpectedly succeeded"
            )
        expected = require_object(case.get("expected"), "capability expectation")
        if actual != expected:
            raise ContractValidationError(
                f"Capability case {case['id']} differs in safe result fields"
            )
    return len(cases)


def validate_wire_cases(document: dict[str, Any], path: Path) -> int:
    root = require_object(load_json(path), path.name)
    cases = require_unique_ids(root.get("cases"), REQUIRED_WIRE_IDS, "wire case")
    for case in cases:
        try:
            actual = build_wire_case(
                require_string(case.get("kind"), "wire case kind"),
                case.get("input"),
            )
            if actual.get("operationId") is not None:
                validate_built_request(document, actual)
        except ContractValidationError:
            if case.get("expectedError") is True:
                continue
            raise
        if case.get("expectedError") is True:
            raise ContractValidationError(
                f"Negative wire case {case['id']} unexpectedly succeeded"
            )
        expected = require_object(case.get("expected"), "wire expectation")
        if actual != expected:
            fields = safe_mapping_mismatch_fields(
                actual,
                expected,
                (
                    "operationId",
                    "method",
                    "uri",
                    "headers",
                    "body",
                    "binding",
                    "encodedPath",
                    "bound",
                ),
            )
            raise ContractValidationError(
                f"Wire case {case['id']} differs in sections: " + ", ".join(fields)
            )
    return len(cases)


def _safe_fixture_path(value: Any, suffix: str) -> Path:
    name = require_string(value, "fixture file", maximum=255)
    path = (FIXTURE_ROOT / name).resolve()
    if path.parent != FIXTURE_ROOT or path.suffix.lower() != suffix:
        raise ContractValidationError("Fixture path escapes its contract folder")
    if not path.is_file():
        raise ContractValidationError("Fixture file does not exist")
    return path


def _ocs_parts(instance: Any) -> tuple[dict[str, Any], Any]:
    root = require_object(instance, "OCS response")
    ocs = require_object(root.get("ocs"), "OCS envelope")
    return require_object(ocs.get("meta"), "OCS metadata"), ocs.get("data")


def _validate_renames(value: Any, maximum: int) -> list[dict[str, str]]:
    raw_entries = require_list(value, "renames")
    if len(raw_entries) > maximum:
        raise ResponseSemanticError("Rename count exceeds its response bound")
    entries: list[dict[str, str]] = []
    for raw_entry in raw_entries:
        entry = require_object(raw_entry, "rename entry")
        if len(entry) != 1:
            raise ResponseSemanticError("Each rename entry must have one mapping")
        source, target = next(iter(entry.items()))
        entries.append(
            {
                _validate_filename(source, "rename source"): _validate_filename(
                    target,
                    "rename target",
                )
            }
        )
    return entries


def classify_fixture(
    fixture: dict[str, Any],
    instance: Any,
) -> dict[str, Any]:
    direction = fixture["direction"]
    operation_id = fixture["operationId"]
    if direction == "request":
        if operation_id == "finalizeAttachment":
            body = require_object(instance, "finalize request")
            normalize_relative_path(body.get("filePath"))
            metadata = _decode_metadata(body.get("talkMetaData"))
            expected_message_type = _expected_message_type(
                fixture.get("expectedMessageType")
            )
            if _metadata_message_type(metadata) != expected_message_type:
                raise ContractValidationError(
                    "Finalize fixture differs from the job-bound message type"
                )
            require_boolean(body.get("allowUpdate"), "allowUpdate")
        elif operation_id == "probeAttachmentFolder":
            body = require_object(instance, "probe request")
            require_boolean(body.get("allowUpdate"), "allowUpdate")
        return {"classification": "request-valid", "renames": []}

    status = require_integer(int(fixture["status"]), "HTTP status", 100, 599)
    meta, data = _ocs_parts(instance)
    ocs_status = require_integer(meta.get("statuscode"), "OCS status", 0, 999)
    ocs_state = require_string(meta.get("status"), "OCS status text", maximum=32)
    if status == 200 and ocs_status == 200 and ocs_state == "ok":
        data_object = require_object(data, "OCS response data")
        if operation_id == "probeAttachmentFolder":
            normalize_relative_path(data_object.get("folder"))
            renames = _validate_renames(data_object.get("renames"), 16)
            return {"classification": "probe-confirmed", "renames": renames}
        renames = _validate_renames(data_object.get("renames"), 1)
        if len(renames) != 1:
            raise ResponseSemanticError("Finalize must return exactly one rename map")
        return {"classification": "finalize-accepted", "renames": renames}

    if status != ocs_status or ocs_state != "failure":
        if operation_id == "finalizeAttachment":
            return {"classification": "ambiguous-finalize", "renames": []}
        raise ResponseSemanticError("HTTP and OCS status disagree")
    require_object(data, "OCS error data")
    if status == 401:
        classification = "reauth"
    elif operation_id == "finalizeAttachment" and status >= 500 and status != 507:
        classification = "ambiguous-finalize"
    elif status in {400, 403, 404, 422, 501, 507}:
        classification = "deterministic-failure"
    else:
        classification = "transient-failure"
    return {"classification": classification, "renames": []}


def validate_fixture(
    document: dict[str, Any],
    fixture: dict[str, Any],
) -> dict[str, Any]:
    instance = load_json(_safe_fixture_path(fixture.get("file"), ".json"))
    operation_id = require_string(fixture.get("operationId"), "fixture operationId")
    _, _, operation = find_operation(document, operation_id)
    direction = require_string(fixture.get("direction"), "fixture direction")
    media_type = require_string(fixture.get("mediaType"), "fixture media type")
    schema_valid = fixture.get("schemaValid")
    if not isinstance(schema_valid, bool):
        raise ContractValidationError("Fixture schemaValid must be boolean")
    if direction == "request":
        schema = request_schema(document, operation, media_type)
    elif direction == "response":
        status = require_string(fixture.get("status"), "fixture status", maximum=3)
        schema = response_schema(document, operation, status, media_type)
    else:
        raise ContractValidationError("Fixture direction is unsupported")
    errors = validate_json_schema(instance, schema)
    if schema_valid and errors:
        raise ContractValidationError(
            f"Fixture {fixture['id']} violates its schema: " + "; ".join(errors)
        )
    if not schema_valid and not errors:
        raise ContractValidationError(
            f"Negative fixture {fixture['id']} was accepted by its schema"
        )
    if not schema_valid:
        result = {"classification": "schema-error", "renames": []}
    else:
        try:
            result = classify_fixture(fixture, instance)
        except ResponseSemanticError:
            result = {"classification": "semantic-error", "renames": []}
    expected_classification = require_string(
        fixture.get("expectedClassification"),
        "expected classification",
    )
    if result["classification"] != expected_classification:
        raise ContractValidationError(
            f"Fixture {fixture['id']} has classification "
            f"{result['classification']}, expected {expected_classification}"
        )
    if "expectedRenameCount" in fixture:
        expected_count = require_integer(
            fixture["expectedRenameCount"],
            "expected rename count",
            0,
            16,
        )
        if len(result["renames"]) != expected_count:
            raise ContractValidationError(
                f"Fixture {fixture['id']} has an unexpected rename count"
            )
    return result


def parse_dav_multistatus_bytes(raw: bytes) -> list[dict[str, Any]]:
    if len(raw) > MAX_XML_BYTES:
        raise ContractValidationError("DAV XML byte budget exceeded")
    try:
        text = raw.decode("utf-8-sig", errors="strict")
    except UnicodeDecodeError as error:
        raise ContractValidationError("DAV XML must use UTF-8") from error
    if "\x00" in text:
        raise ContractValidationError("DAV XML must use UTF-8")
    declaration = XML_DECLARATION.match(text)
    if declaration is not None:
        encoding = XML_DECLARED_ENCODING.search(declaration.group("attributes"))
        if encoding is not None and encoding.group("encoding").lower() not in {
            "utf-8",
            "utf8",
        }:
            raise ContractValidationError("DAV XML declaration must use UTF-8")
    upper = text.upper()
    if "<!DOCTYPE" in upper or "<!ENTITY" in upper:
        raise ContractValidationError("DAV XML declarations are forbidden")

    chunks: list[dict[str, Any]] = []
    seen: set[str] = set()
    parser = ET.XMLPullParser(events=("start", "end"))
    tags: list[str] = []
    nodes = 0
    depth = 0
    root_seen = False
    response_hrefs: list[str | None] | None = None
    response_lengths: list[str | None] | None = None

    def process_events() -> None:
        nonlocal depth, nodes, root_seen, response_hrefs, response_lengths
        for event, node in parser.read_events():
            if event == "start":
                parent = tags[-1] if tags else None
                tags.append(node.tag)
                depth += 1
                nodes += 1
                if nodes > MAX_XML_NODES or depth > MAX_XML_DEPTH:
                    raise ContractValidationError("DAV XML structural budget exceeded")
                if not root_seen:
                    root_seen = True
                    if node.tag != f"{DAV_NAMESPACE}multistatus":
                        raise ContractValidationError(
                            "DAV response is not a multistatus"
                        )
                if (
                    node.tag == f"{DAV_NAMESPACE}response"
                    and parent == f"{DAV_NAMESPACE}multistatus"
                ):
                    if response_hrefs is not None:
                        raise ContractValidationError("DAV responses overlap")
                    response_hrefs = []
                    response_lengths = []
                continue

            parent = tags[-2] if len(tags) > 1 else None
            if response_hrefs is not None and response_lengths is not None:
                if node.tag == f"{DAV_NAMESPACE}href" and parent == (
                    f"{DAV_NAMESPACE}response"
                ):
                    response_hrefs.append(node.text)
                elif node.tag == f"{DAV_NAMESPACE}getcontentlength":
                    response_lengths.append(node.text)
                elif node.tag == f"{DAV_NAMESPACE}response" and parent == (
                    f"{DAV_NAMESPACE}multistatus"
                ):
                    if len(response_hrefs) != 1 or response_hrefs[0] is None:
                        raise ContractValidationError("DAV response lacks one href")
                    href = response_hrefs[0]
                    if len(href) > 4096 or CONTROL.search(href):
                        raise ContractValidationError("DAV href exceeds its bound")
                    name = unquote(href.rstrip("/").rsplit("/", 1)[-1])
                    if CHUNK_NAME.fullmatch(name) is not None:
                        if len(response_lengths) != 1 or response_lengths[0] is None:
                            raise ContractValidationError(
                                "DAV chunk lacks one content length"
                            )
                        length_text = response_lengths[0]
                        if not length_text.isascii() or not length_text.isdecimal():
                            raise ContractValidationError(
                                "DAV chunk length is not canonical"
                            )
                        length = require_integer(
                            int(length_text),
                            "DAV chunk length",
                            1,
                        )
                        if name in seen:
                            raise ContractValidationError(
                                "DAV multistatus repeats a chunk"
                            )
                        seen.add(name)
                        chunks.append({"name": name, "length": length})
                    response_hrefs = None
                    response_lengths = None
            node.clear()
            if not tags or tags[-1] != node.tag:
                raise ContractValidationError("DAV multistatus is malformed")
            tags.pop()
            depth -= 1

    try:
        for offset in range(0, len(text), 4096):
            parser.feed(text[offset : offset + 4096])
            process_events()
        parser.close()
        process_events()
    except ET.ParseError as error:
        raise ContractValidationError("DAV multistatus is malformed") from error
    if not root_seen or tags or depth != 0:
        raise ContractValidationError("DAV multistatus is malformed")
    chunks.sort(key=lambda item: item["name"])
    return chunks


def validate_dav_xml_fixtures(manifest: dict[str, Any]) -> int:
    fixtures = require_unique_ids(
        manifest.get("davXmlFixtures"),
        REQUIRED_DAV_XML_IDS,
        "DAV XML fixture",
    )
    for fixture in fixtures:
        raw = _safe_fixture_path(fixture.get("file"), ".xml").read_bytes()
        try:
            actual = parse_dav_multistatus_bytes(raw)
        except ContractValidationError:
            if fixture.get("expectedError") is True:
                continue
            raise
        if fixture.get("expectedError") is True:
            raise ContractValidationError(
                f"Negative DAV XML fixture {fixture['id']} unexpectedly succeeded"
            )
        expected = require_list(fixture.get("expectedChunks"), "expected chunks")
        if actual != expected:
            raise ContractValidationError(
                f"DAV XML fixture {fixture['id']} differs in chunk summary"
            )
    return len(fixtures)


def _dav_user_segment(value: Any) -> str:
    user_id = _safe_identifier(value, "DAV userId")
    return quote(user_id, safe="-._~@+")


def _dav_upload_id(value: Any) -> str:
    return _uuid(value, "DAV uploadId")


def _chunk_ranges(file_size: int, chunk_size: int) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    start = 0
    while start < file_size:
        end = min(start + chunk_size, file_size) - 1
        ranges.append((start, end))
        start = end + 1
    return ranges


def _chunk_name(start: int, end: int) -> str:
    return f"{start:016d}-{end:016d}"


def _dav_upload_base(server: str, user: str, upload_id: str) -> str:
    return f"{server}/remote.php/dav/uploads/{user}/{upload_id}"


def _dav_file_uri(server: str, user: str, encoded_path: str) -> str:
    return f"{server}/remote.php/dav/files/{user}/{encoded_path}"


def build_dav_plan(kind: str, raw_input: Any) -> dict[str, Any]:
    input_value = require_object(raw_input, "DAV plan input")
    account_id = _safe_identifier(input_value.get("accountId"), "DAV accountId")
    server = normalize_server(input_value.get("server"))
    user = _dav_user_segment(input_value.get("userId"))
    binding = {"accountId": account_id, "server": server}
    if kind == "cleanupChunk":
        upload_id = _dav_upload_id(input_value.get("uploadId"))
        return {
            "binding": binding,
            "method": "DELETE",
            "uri": _dav_upload_base(server, user, upload_id),
            "headers": {},
            "successStatuses": [204, 404],
        }
    if kind == "cleanupDraft":
        _, encoded_path = normalize_relative_path(input_value.get("draftPath"))
        return {
            "binding": binding,
            "method": "DELETE",
            "uri": _dav_file_uri(server, user, encoded_path),
            "headers": {},
            "successStatuses": [204, 404],
        }
    if kind != "upload":
        raise ContractValidationError("Unknown DAV plan kind")
    _, encoded_path = normalize_relative_path(input_value.get("draftPath"))
    upload_id = _dav_upload_id(input_value.get("uploadId"))
    file_size = require_integer(input_value.get("fileSize"), "fileSize", 1)
    threshold = require_integer(
        input_value.get("chunkThreshold"),
        "chunkThreshold",
        1,
    )
    chunk_size = require_integer(input_value.get("chunkSize"), "chunkSize", 1)
    existing = require_list(input_value.get("existingChunks"), "existingChunks")
    destination = _dav_file_uri(server, user, encoded_path)
    if file_size <= threshold:
        if existing:
            raise ContractValidationError("Normal upload cannot carry chunk state")
        return {
            "binding": binding,
            "mode": "normal",
            "steps": [
                {
                    "method": "PUT",
                    "uri": destination,
                    "headers": {
                        "Content-Length": str(file_size),
                        "Content-Type": "application/octet-stream",
                    },
                    "contentStart": 0,
                    "contentLength": file_size,
                    "successStatuses": [201, 204],
                }
            ],
        }

    ranges = _chunk_ranges(file_size, chunk_size)
    expected_ranges = {
        _chunk_name(start, end): end - start + 1 for start, end in ranges
    }
    existing_names: set[str] = set()
    for raw_chunk in existing:
        chunk = require_object(raw_chunk, "existing chunk")
        if set(chunk) != {"name", "length"}:
            raise ContractValidationError("Existing chunk has an unknown member")
        name = require_string(chunk.get("name"), "existing chunk name", maximum=33)
        length = require_integer(chunk.get("length"), "existing chunk length", 1)
        if name not in expected_ranges or expected_ranges[name] != length:
            raise ContractValidationError("Existing chunk does not match the byte plan")
        if name in existing_names:
            raise ContractValidationError("Existing chunk is duplicated")
        existing_names.add(name)

    upload_base = _dav_upload_base(server, user, upload_id)
    steps: list[dict[str, Any]] = [
        {
            "method": "MKCOL",
            "uri": upload_base,
            "headers": {},
            "successStatuses": [201, 405],
        },
        {
            "method": "PROPFIND",
            "uri": upload_base,
            "headers": {"Depth": "1"},
            "successStatuses": [207],
        },
    ]
    for start, end in ranges:
        name = _chunk_name(start, end)
        if name in existing_names:
            continue
        length = end - start + 1
        steps.append(
            {
                "method": "PUT",
                "uri": f"{upload_base}/{name}",
                "headers": {"Content-Length": str(length)},
                "contentStart": start,
                "contentLength": length,
                "successStatuses": [201, 204],
            }
        )
    steps.append(
        {
            "method": "MOVE",
            "uri": f"{upload_base}/.file",
            "headers": {
                "Destination": destination,
                "OC-Total-Length": str(file_size),
            },
            "successStatuses": [201, 204],
        }
    )
    for step in steps:
        headers = require_object(step["headers"], "DAV step headers")
        if "Range" in headers or "Content-Range" in headers:
            raise ContractValidationError(
                "Chunk PUT must not emit an HTTP range header"
            )
        if step["method"] == "MOVE":
            source = urlsplit(step["uri"])
            target = urlsplit(headers["Destination"])
            if (source.scheme, source.netloc) != (target.scheme, target.netloc):
                raise ContractValidationError("MOVE Destination crosses server origin")
            if headers.get("OC-Total-Length") != str(file_size):
                raise ContractValidationError("MOVE lacks OC-Total-Length")
    return {"binding": binding, "mode": "chunked", "steps": steps}


def classify_dav_status(method: Any, status: Any) -> str:
    normalized_method = require_string(method, "DAV method", maximum=16).upper()
    normalized_status = require_integer(status, "DAV status", 100, 599)
    success = {
        "MKCOL": {201, 405},
        "PROPFIND": {207},
        "PUT": {201, 204},
        "MOVE": {201, 204},
        "DELETE": {204, 404},
    }
    if normalized_method not in success:
        raise ContractValidationError("Unsupported DAV method")
    if normalized_status in success[normalized_method]:
        return "success"
    if normalized_method == "MOVE" and normalized_status == 400:
        return "deterministic-failure"
    if normalized_status in {401, 403, 409, 412, 413, 422, 507}:
        return "deterministic-failure"
    return "transient-failure"


def validate_dav_cases(path: Path) -> tuple[int, int]:
    root = require_object(load_json(path), path.name)
    if root.get("upstreamCoreShas") != EXPECTED_CORE_SHAS:
        raise ContractValidationError(
            "DAV cases are not bound to the approved core SHAs"
        )
    plans = require_unique_ids(root.get("plans"), REQUIRED_DAV_PLAN_IDS, "DAV plan")
    for case in plans:
        try:
            actual = build_dav_plan(
                require_string(case.get("kind"), "DAV plan kind"),
                case.get("input"),
            )
        except ContractValidationError:
            if case.get("expectedError") is True:
                continue
            raise
        if case.get("expectedError") is True:
            raise ContractValidationError(
                f"Negative DAV plan {case['id']} unexpectedly succeeded"
            )
        expected = require_object(case.get("expected"), "DAV plan expectation")
        if actual != expected:
            raise ContractValidationError(
                f"DAV plan {case['id']} differs in bounded wire output"
            )

    statuses = require_unique_ids(
        root.get("statusCases"),
        REQUIRED_DAV_STATUS_IDS,
        "DAV status case",
    )
    for case in statuses:
        actual = classify_dav_status(case.get("method"), case.get("status"))
        expected = require_string(case.get("expected"), "DAV status expectation")
        if actual != expected:
            raise ContractValidationError(
                f"DAV status case {case['id']} has an unexpected classification"
            )
    return len(plans), len(statuses)


ATTACHMENT_PHASES = {
    "cancelled",
    "cancelling",
    "cleanupFailed",
    "completed",
    "draftResolved",
    "failed",
    "finalizing",
    "localPrepared",
    "probing",
    "retryable",
    "uploaded",
    "uploading",
    "awaitingConfirmation",
}
RETRY_PHASES = {"localPrepared", "probing", "draftResolved", "uploading", "uploaded"}
