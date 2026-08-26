from __future__ import annotations

# ruff: noqa: E402, F403

import sys
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs


_MODULE_ROOT = Path(__file__).resolve().parent
if str(_MODULE_ROOT) not in sys.path:
    sys.path.insert(0, str(_MODULE_ROOT))

import validator_rich_protocol as _validator_protocol
import validator_rich_requests as _validator_requests
import validator_rich_runner as _validator_runner
from validator_rich_projection import *
from validator_rich_protocol import *
from validator_rich_requests import *
from validator_rich_runner import *


def validate_request_against_openapi(
    document: dict[str, Any],
    request: dict[str, Any],
) -> None:
    _validator_requests.validate_request_against_openapi(
        document,
        request,
        _parse_query=parse_qs,
    )


def validate_response_cases(
    document: dict[str, Any],
    cases: list[Any],
) -> dict[str, dict[str, Any]]:
    for index, raw_case in enumerate(cases):
        case = _validator_protocol.require_object(
            raw_case,
            f"response cases[{index}]",
        )
        operation_id = _validator_protocol.require_string(
            case.get("operationId"),
            f"response cases[{index}].operationId",
        )
        if operation_id != "setThreadNotificationLevel":
            continue
        context = _validator_protocol.require_object(
            case.get("context"),
            f"response cases[{index}].context",
        )
        if "messageId" in context:
            raise _validator_protocol.ResponseSemanticError(
                "Thread notification legacy message id context is forbidden"
            )
        if "threadId" not in context:
            raise _validator_protocol.ResponseSemanticError(
                "Thread notification canonical id context missing"
            )
    return _validator_protocol.validate_response_cases(document, cases)


_validator_runner.validate_response_cases = validate_response_cases


if __name__ == "__main__":
    raise SystemExit(_validator_runner.main())
