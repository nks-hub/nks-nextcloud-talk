from __future__ import annotations

import re
from copy import deepcopy
from typing import Any
from urllib.parse import urljoin, urlsplit

from validator_rich_protocol import (
    ContractValidationError,
    MAX_RENDER_MESSAGE_CHARS,
    MAX_RENDER_PARAMETERS,
    PLACEHOLDER_PATTERN,
    RENDER_ORIGIN,
    ensure_unique_case_ids,
    require_array,
    require_boolean,
    require_integer,
    require_object,
    require_room_token,
    require_snowflake,
    require_string,
)


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
