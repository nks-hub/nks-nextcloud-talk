from __future__ import annotations

from pathlib import Path
from typing import Any

from openapi_spec_validator import validate

from validator_common import (
    CONTRACT_ROOT,
    ContractValidationError,
    EXPECTED_CORE_SHAS,
    EXPECTED_TALK_SHA,
    FIXTURE_ROOT,
    MANIFEST_PATH,
    REQUIRED_FIXTURE_IDS,
    load_json,
    require_list,
    require_object,
    require_string,
    require_unique_ids,
)
from validator_state import validate_state_cases
from validator_transport import (
    _safe_fixture_path,
    validate_capability_cases,
    validate_dav_cases,
    validate_dav_xml_fixtures,
    validate_fixture,
    validate_wire_cases,
)


def _case_file(manifest: dict[str, Any], field: str) -> Path:
    return _safe_fixture_path(manifest.get(field), ".json")


def _validate_manifest_files(manifest: dict[str, Any]) -> None:
    referenced = {
        "manifest.json",
        "capability.cases.json",
        "dav.cases.json",
        "state.cases.json",
        "wire.cases.json",
    }
    for fixture in require_list(manifest.get("fixtures"), "manifest fixtures"):
        entry = require_object(fixture, "manifest fixture")
        referenced.add(require_string(entry.get("file"), "fixture file", maximum=255))
    for fixture in require_list(manifest.get("davXmlFixtures"), "DAV XML fixtures"):
        entry = require_object(fixture, "DAV XML fixture")
        referenced.add(require_string(entry.get("file"), "DAV XML file", maximum=255))
    actual = {
        path.name
        for path in FIXTURE_ROOT.iterdir()
        if path.is_file() and path.suffix.lower() in {".json", ".xml"}
    }
    if actual != referenced:
        raise ContractValidationError(
            "Fixture inventory mismatch; "
            f"missing={sorted(referenced - actual)}, "
            f"unreferenced={sorted(actual - referenced)}"
        )


def validate_contract() -> dict[str, int]:
    document = require_object(load_json(CONTRACT_ROOT / "openapi.json"), "OpenAPI")
    validate(document)
    if document.get("openapi") != "3.1.0":
        raise ContractValidationError("Contract must remain OpenAPI 3.1.0")
    if document.get("x-upstream-talk-sha") != EXPECTED_TALK_SHA:
        raise ContractValidationError("OpenAPI is not bound to the approved Talk SHA")
    if document.get("x-upstream-core-shas") != EXPECTED_CORE_SHAS:
        raise ContractValidationError("OpenAPI is not bound to the approved core SHAs")

    manifest = require_object(load_json(MANIFEST_PATH), "manifest")
    if manifest.get("upstreamTalkSha") != EXPECTED_TALK_SHA:
        raise ContractValidationError("Manifest Talk SHA differs from the contract")
    if manifest.get("upstreamCoreShas") != EXPECTED_CORE_SHAS:
        raise ContractValidationError("Manifest core SHAs differ from the contract")
    contract_path = (
        FIXTURE_ROOT / require_string(manifest.get("contract"), "contract path")
    ).resolve()
    if contract_path != (CONTRACT_ROOT / "openapi.json").resolve():
        raise ContractValidationError("Manifest must resolve to the local openapi.json")

    fixtures = require_unique_ids(
        manifest.get("fixtures"),
        REQUIRED_FIXTURE_IDS,
        "manifest fixture",
    )
    fixture_results = [validate_fixture(document, fixture) for fixture in fixtures]
    probe_request = next(
        fixture for fixture in fixtures if fixture["id"] == "probe-request"
    )
    finalize_request = next(
        fixture for fixture in fixtures if fixture["id"] == "finalize-request"
    )
    probe_body = require_object(
        load_json(_safe_fixture_path(probe_request["file"], ".json")),
        "probe request",
    )
    finalize_body = require_object(
        load_json(_safe_fixture_path(finalize_request["file"], ".json")),
        "finalize request",
    )
    if (
        probe_body.get("allowUpdate") is not False
        or finalize_body.get("allowUpdate") is not False
    ):
        raise ContractValidationError("Both Talk requests must carry allowUpdate=false")
    if probe_body["allowUpdate"] != finalize_body["allowUpdate"]:
        raise ContractValidationError("allowUpdate changed across the attachment job")

    capability_count = validate_capability_cases(
        _case_file(manifest, "capabilityCasesFile")
    )
    wire_count = validate_wire_cases(document, _case_file(manifest, "wireCasesFile"))
    dav_plan_count, dav_status_count = validate_dav_cases(
        _case_file(manifest, "davCasesFile")
    )
    state_count = validate_state_cases(_case_file(manifest, "stateCasesFile"))
    dav_xml_count = validate_dav_xml_fixtures(manifest)
    _validate_manifest_files(manifest)
    return {
        "fixtures": len(fixture_results),
        "capabilityCases": capability_count,
        "wireCases": wire_count,
        "davPlans": dav_plan_count,
        "davStatuses": dav_status_count,
        "davXmlFixtures": dav_xml_count,
        "stateCases": state_count,
    }


def main() -> int:
    try:
        counts = validate_contract()
    except Exception as error:  # noqa: BLE001 - command boundary reports one safe line
        print(f"attachment-upload contract: FAILED ({type(error).__name__}: {error})")
        return 1
    summary = ", ".join(f"{name}={count}" for name, count in counts.items())
    print(f"attachment-upload contract: OK ({summary})")
    return 0
