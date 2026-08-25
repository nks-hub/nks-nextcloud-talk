from __future__ import annotations

import argparse
import ipaddress
import json
import re
import sys
from pathlib import Path
from typing import Any

from openapi_spec_validator import validate

from validator_rich_projection import validate_render_cases, validate_state_cases
from validator_rich_protocol import (
    CONTRACT_ROOT,
    FIXTURE_ROOT,
    MANIFEST_PATH,
    PRIVATE_IPV4_PATTERN,
    SUCCESS_STATUSES,
    ContractValidationError,
    load_json,
    operation_index,
    require_array,
    require_integer,
    require_object,
    require_string,
    validate_capability_cases,
    validate_response_cases,
)
from validator_rich_requests import validate_request_cases


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
            (CONTRACT_ROOT / "validate_contract.py").resolve(),
            (CONTRACT_ROOT / "test_validate_contract.py").resolve(),
            (CONTRACT_ROOT / "requirements.txt").resolve(),
        }
        | {path.resolve() for path in CONTRACT_ROOT.glob("validator_rich_*.py")}
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
