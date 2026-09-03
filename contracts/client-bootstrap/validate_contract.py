from __future__ import annotations

import argparse
import ipaddress
import json
import re
import sys
from copy import deepcopy
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from jsonschema import Draft202012Validator, FormatChecker
from openapi_spec_validator import validate_spec


CONTRACT_ROOT = Path(__file__).resolve().parent
FIXTURE_ROOT = CONTRACT_ROOT / "fixtures"
MANIFEST_PATH = FIXTURE_ROOT / "manifest.json"
MAX_LIVE_RESPONSE_BYTES = 2 * 1024 * 1024
CONTROL_CHARACTERS = re.compile(r"[\x00-\x1f\x7f]")
DNS_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")
PATH_SEGMENT = re.compile(r"[A-Za-z0-9._~-]+")
TOKEN_SEGMENT = re.compile(r"[A-Za-z0-9._~-]{32,4096}")

REQUIRED_FIXTURE_IDS = {
    "status-ready",
    "status-maintenance",
    "login-init-empty-request",
    "login-init-root",
    "login-init-subpath",
    "login-init-pretty-urls",
    "login-init-mixed-routes",
    "login-init-debug-http",
    "login-init-cross-origin",
    "login-init-base-path-escape",
    "login-init-base-path-poll-escape",
    "login-init-cross-origin-poll",
    "login-poll-request",
    "login-poll-pending",
    "login-poll-success",
    "login-poll-subpath",
    "login-poll-base-path-escape",
    "login-poll-cross-origin",
    "login-poll-debug-http",
    "login-poll-malformed",
    "capabilities-anonymous",
    "capabilities-authenticated",
}

REQUIRED_NORMALIZATION_IDS = {
    "missing-scheme",
    "subpath-and-trailing-slash",
    "default-https-port",
    "explicit-https-port",
    "debug-http",
    "ipv6-host",
    "production-http-rejected",
    "userinfo-rejected",
    "query-rejected",
    "fragment-rejected",
    "backslash-rejected",
    "control-character-rejected",
    "dot-segment-rejected",
    "encoded-path-rejected",
    "double-slash-rejected",
    "unsupported-scheme-rejected",
    "zero-port-rejected",
    "ambiguous-ipv4-rejected",
    "trailing-dot-host-rejected",
    "malformed-ipv6-rejected",
    "empty-port-rejected",
    "empty-input-rejected",
}


class ContractValidationError(RuntimeError):
    pass


class NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(
        self,
        request: Request,
        file_pointer: Any,
        code: int,
        message: str,
        headers: Any,
        new_url: str,
    ) -> None:
        return None


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractValidationError(f"{label} must contain a JSON object")
    return value


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
        reference = value["$ref"]
        if reference in reference_stack:
            raise ContractValidationError(
                f"Circular reference is not supported: {reference}"
            )
        target = deepcopy(resolve_pointer(document, reference))
        siblings = {key: item for key, item in value.items() if key != "$ref"}
        if siblings:
            if not isinstance(target, dict):
                raise ContractValidationError(
                    f"Reference siblings require an object: {reference}"
                )
            target.update(siblings)
        return expand_references(target, document, reference_stack + (reference,))

    return {
        key: expand_references(item, document, reference_stack)
        for key, item in value.items()
    }


def find_operation(document: dict[str, Any], operation_id: str) -> dict[str, Any]:
    for path_item in document.get("paths", {}).values():
        for method, operation in path_item.items():
            if method.lower() not in {"get", "post", "put", "patch", "delete"}:
                continue
            if operation.get("operationId") == operation_id:
                return operation
    raise ContractValidationError(f"Unknown operationId: {operation_id}")


def request_schema(
    document: dict[str, Any],
    operation: dict[str, Any],
    fixture: dict[str, Any],
) -> dict[str, Any]:
    if fixture.get("location") != "body":
        raise ContractValidationError(
            f"Unsupported request location: {fixture.get('location')}"
        )

    media_type = fixture.get("mediaType")
    request_body = expand_references(operation.get("requestBody", {}), document)
    try:
        return request_body["content"][media_type]["schema"]
    except KeyError as error:
        raise ContractValidationError(
            f"Operation {fixture['operationId']} has no {media_type} request body"
        ) from error


def response_schema(
    document: dict[str, Any],
    operation: dict[str, Any],
    fixture: dict[str, Any],
) -> dict[str, Any]:
    status = fixture.get("status")
    media_type = fixture.get("mediaType")
    response = expand_references(
        operation.get("responses", {}).get(status, {}), document
    )
    try:
        return response["content"][media_type]["schema"]
    except KeyError as error:
        raise ContractValidationError(
            f"Operation {fixture['operationId']} status {status} "
            f"has no {media_type} schema"
        ) from error


def validate_json_schema(instance: Any, schema: dict[str, Any]) -> list[str]:
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    return [
        error.message
        for error in sorted(
            validator.iter_errors(instance), key=lambda item: list(item.path)
        )
    ]


def validate_required_headers(
    document: dict[str, Any],
    operation: dict[str, Any],
    fixture: dict[str, Any],
) -> None:
    supplied = {
        key.lower(): value
        for key, value in require_object(fixture.get("headers", {}), "headers").items()
    }
    for raw_parameter in operation.get("parameters", []):
        parameter = expand_references(raw_parameter, document)
        if parameter.get("in") != "header" or not parameter.get("required"):
            continue
        name = parameter["name"]
        value = supplied.get(name.lower())
        if value is None:
            raise ContractValidationError(
                f"{fixture['name']} is missing required header {name}"
            )
        errors = validate_json_schema(value, parameter["schema"])
        if errors:
            raise ContractValidationError(
                f"{fixture['name']} header {name} is invalid: " + "; ".join(errors)
            )


def assert_form_round_trip(fixture_name: str, instance: Any) -> None:
    if not isinstance(instance, dict):
        raise ContractValidationError(f"{fixture_name} form fixture must be an object")
    if not all(isinstance(value, str) for value in instance.values()):
        if instance:
            raise ContractValidationError(
                f"{fixture_name} form fixture must contain scalar strings"
            )

    encoded = urlencode(instance)
    decoded_values = parse_qs(encoded, keep_blank_values=True, strict_parsing=True)
    decoded = {key: values[-1] for key, values in decoded_values.items()}
    if decoded != instance:
        raise ContractValidationError(f"{fixture_name} failed form round trip")


def canonical_host(host: str) -> str:
    if host.endswith("."):
        raise ContractValidationError("Trailing-dot hosts are ambiguous")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        try:
            ascii_host = host.encode("idna").decode("ascii").lower()
        except UnicodeError as error:
            raise ContractValidationError("Host is not valid IDNA") from error
        if len(ascii_host) > 253 or not ascii_host:
            raise ContractValidationError("Host length is invalid")
        labels = ascii_host.split(".")
        if len(labels) == 4 and all(label.isdigit() for label in labels):
            raise ContractValidationError(
                "IPv4-like hosts must use canonical decimal form"
            )
        if any(DNS_LABEL.fullmatch(label) is None for label in labels):
            raise ContractValidationError("Host contains an invalid DNS label")
        return ascii_host

    return f"[{address.compressed}]" if address.version == 6 else address.compressed


def normalize_server_base(raw_value: str, allow_debug_http: bool = False) -> str:
    if not isinstance(raw_value, str):
        raise ContractValidationError("Server address must be a string")
    if CONTROL_CHARACTERS.search(raw_value):
        raise ContractValidationError("Server address contains a control character")
    if "\\" in raw_value:
        raise ContractValidationError("Backslashes are not allowed in server addresses")

    value = raw_value.strip(" ")
    if not value or " " in value:
        raise ContractValidationError("Server address is empty or contains spaces")
    if "://" not in value:
        value = f"https://{value}"

    try:
        parsed = urlsplit(value)
    except ValueError as error:
        raise ContractValidationError("Server address cannot be parsed") from error
    scheme = parsed.scheme.lower()
    if scheme != "https" and not (allow_debug_http and scheme == "http"):
        raise ContractValidationError("Production server addresses require HTTPS")
    if parsed.username is not None or parsed.password is not None:
        raise ContractValidationError("Userinfo is not allowed in server addresses")
    if parsed.query or parsed.fragment:
        raise ContractValidationError(
            "Query and fragment are not allowed in server addresses"
        )
    if (
        not parsed.netloc
        or parsed.netloc.endswith(":")
        or parsed.hostname is None
        or "%" in parsed.netloc
    ):
        raise ContractValidationError("Server address has no unambiguous host")

    try:
        port = parsed.port
    except ValueError as error:
        raise ContractValidationError("Server port is invalid") from error
    if port == 0:
        raise ContractValidationError("Server port must be between 1 and 65535")
    host = canonical_host(parsed.hostname)
    default_port = 443 if scheme == "https" else 80
    authority = host if port is None or port == default_port else f"{host}:{port}"

    path = parsed.path
    if path == "/":
        path = ""
    elif path:
        if not path.startswith("/"):
            raise ContractValidationError("Server subpath must be absolute")
        path = path[:-1] if path.endswith("/") else path
        segments = path[1:].split("/")
        if any(
            not segment
            or segment in {".", ".."}
            or PATH_SEGMENT.fullmatch(segment) is None
            for segment in segments
        ):
            raise ContractValidationError("Server subpath is ambiguous or encoded")

    return urlunsplit((scheme, authority, path, "", ""))


def same_origin(first: str, second: str) -> bool:
    first_parts = urlsplit(first)
    second_parts = urlsplit(second)
    return (
        first_parts.scheme,
        first_parts.hostname,
        first_parts.port,
    ) == (
        second_parts.scheme,
        second_parts.hostname,
        second_parts.port,
    )


def validate_login_initialization(
    instance: Any,
    raw_base_url: str,
    allow_debug_http: bool = False,
) -> None:
    value = require_object(instance, "Login Flow v2 initialization")
    poll = require_object(value.get("poll"), "Login Flow v2 poll descriptor")
    base_url = normalize_server_base(raw_base_url, allow_debug_http)
    login_url = normalize_server_base(value["login"], allow_debug_http)
    poll_url = normalize_server_base(poll["endpoint"], allow_debug_http)

    if not same_origin(base_url, login_url) or not same_origin(base_url, poll_url):
        raise ContractValidationError("Login Flow v2 returned a cross-origin URL")

    base_path = urlsplit(base_url).path.rstrip("/")
    actual_poll_path = urlsplit(poll_url).path
    actual_login_path = urlsplit(login_url).path
    # With `index.php` by default, without it on a pretty-URL server; both
    # endpoints must agree on one of the two shapes.
    login_prefix = None
    for route in ("/index.php", ""):
        if actual_poll_path == f"{base_path}{route}/login/v2/poll" and actual_login_path.startswith(
            f"{base_path}{route}/login/v2/flow/"
        ):
            login_prefix = f"{base_path}{route}/login/v2/flow/"
            break
    if login_prefix is None:
        raise ContractValidationError("Login Flow v2 returned an unexpected poll or login path")

    login_token = actual_login_path[len(login_prefix) :]
    if TOKEN_SEGMENT.fullmatch(login_token) is None:
        raise ContractValidationError("Login Flow v2 login token path is malformed")
    if login_token == poll.get("token"):
        raise ContractValidationError("Login and poll tokens must be independent")


def validate_credentials(
    instance: Any,
    raw_base_url: str,
    secret_prefix: str,
    allow_debug_http: bool = False,
) -> None:
    value = require_object(instance, "Login Flow v2 credentials")
    base_url = normalize_server_base(raw_base_url, allow_debug_http)
    credential_server = normalize_server_base(value["server"], allow_debug_http)
    if credential_server != base_url:
        raise ContractValidationError(
            "Credential response changed the verified server base"
        )
    if not value["appPassword"].startswith(secret_prefix):
        raise ContractValidationError(
            "Credential fixture must use an obvious synthetic secret"
        )


def status_blockers(instance: Any) -> list[str]:
    value = require_object(instance, "server status")
    blockers: list[str] = []
    if not value["installed"]:
        blockers.append("not-installed")
    if value["maintenance"]:
        blockers.append("maintenance")
    if value["needsDbUpgrade"]:
        blockers.append("database-upgrade-required")
    return blockers


def string_set(value: Any, label: str) -> set[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise ContractValidationError(f"{label} must be a string list")
    result = set(value)
    if len(result) != len(value):
        raise ContractValidationError(f"{label} contains duplicates")
    return result


def validate_capability_snapshot(
    instance: Any,
    fixture: dict[str, Any],
) -> tuple[str, int, int]:
    value = require_object(instance, "capability response")
    ocs = require_object(value.get("ocs"), "OCS envelope")
    meta = require_object(ocs.get("meta"), "OCS metadata")
    if meta.get("status") != "ok" or meta.get("statuscode") != 200:
        raise ContractValidationError("Capability fixture must represent OCS success")
    data = require_object(ocs.get("data"), "OCS data")
    capabilities = require_object(data.get("capabilities"), "capability namespaces")
    namespaces = set(capabilities)

    required_namespaces = set(fixture.get("requiredNamespaces", []))
    forbidden_namespaces = set(fixture.get("forbiddenNamespaces", []))
    if missing := sorted(required_namespaces - namespaces):
        raise ContractValidationError(
            f"Capability fixture misses namespaces: {missing}"
        )
    if present := sorted(forbidden_namespaces & namespaces):
        raise ContractValidationError(
            f"Capability fixture exposes forbidden namespaces: {present}"
        )

    spreed = require_object(capabilities.get("spreed"), "spreed capability")
    talk_features = string_set(spreed.get("features"), "spreed.features")
    required_talk = set(fixture.get("requiredTalkFeatures", []))
    if missing := sorted(required_talk - talk_features):
        raise ContractValidationError(
            f"Capability fixture misses Talk features: {missing}"
        )

    required_push = set(fixture.get("requiredNotificationPush", []))
    if required_push:
        notifications = require_object(
            capabilities.get("notifications"), "notifications capability"
        )
        push_features = string_set(notifications.get("push"), "notifications.push")
        if missing := sorted(required_push - push_features):
            raise ContractValidationError(
                f"Capability fixture misses notification push features: {missing}"
            )

    context = fixture.get("capabilityContext")
    if context not in {"anonymous", "authenticated"}:
        raise ContractValidationError(f"Unknown capability context: {context}")
    return context, len(namespaces), len(talk_features)


def validate_fixture(
    document: dict[str, Any],
    fixture: dict[str, Any],
) -> dict[str, int]:
    fixture_path = FIXTURE_ROOT / fixture["file"]
    instance = load_json(fixture_path)
    operation = find_operation(document, fixture["operationId"])
    if fixture["direction"] == "request":
        schema = request_schema(document, operation, fixture)
        validate_required_headers(document, operation, fixture)
    elif fixture["direction"] == "response":
        schema = response_schema(document, operation, fixture)
    else:
        raise ContractValidationError(
            f"{fixture['name']} has unknown direction {fixture['direction']}"
        )

    errors = validate_json_schema(instance, expand_references(schema, document))
    expected_valid = fixture.get("valid", True)
    if expected_valid and errors:
        raise ContractValidationError(
            f"{fixture['name']} unexpectedly violates its schema: " + "; ".join(errors)
        )
    if not expected_valid and not errors:
        raise ContractValidationError(
            f"{fixture['name']} is a negative fixture but the schema accepted it"
        )

    if expected_valid and fixture.get("wireEncoding") == "form":
        assert_form_round_trip(fixture["name"], instance)

    counts = {"status": 0, "loginTrust": 0, "credentials": 0, "capabilities": 0}
    if expected_valid and "expectedStatusBlockers" in fixture:
        actual = status_blockers(instance)
        if actual != fixture["expectedStatusBlockers"]:
            raise ContractValidationError(
                f"{fixture['name']} classifies to {actual}, "
                f"expected {fixture['expectedStatusBlockers']}"
            )
        counts["status"] += 1

    if expected_valid and "loginBaseUrl" in fixture:
        trusted = True
        try:
            validate_login_initialization(
                instance,
                fixture["loginBaseUrl"],
                fixture.get("allowDebugHttp", False),
            )
        except ContractValidationError:
            trusted = False
        if trusted != fixture["expectedTrusted"]:
            raise ContractValidationError(
                f"{fixture['name']} trust result is {trusted}, "
                f"expected {fixture['expectedTrusted']}"
            )
        counts["loginTrust"] += 1

    if expected_valid and "credentialBaseUrl" in fixture:
        trusted = True
        try:
            validate_credentials(
                instance,
                fixture["credentialBaseUrl"],
                fixture["syntheticSecretPrefix"],
                fixture.get("allowDebugHttp", False),
            )
        except ContractValidationError:
            trusted = False
        if trusted != fixture["expectedTrustedCredentials"]:
            raise ContractValidationError(
                f"{fixture['name']} credential trust result is {trusted}, "
                f"expected {fixture['expectedTrustedCredentials']}"
            )
        counts["credentials"] += 1

    if expected_valid and "capabilityContext" in fixture:
        validate_capability_snapshot(instance, fixture)
        counts["capabilities"] += 1

    return counts


def validate_normalization_cases(path: Path) -> int:
    document = require_object(load_json(path), path.name)
    cases = document.get("cases")
    if not isinstance(cases, list) or not cases:
        raise ContractValidationError("Normalization fixture must contain cases")

    ids: list[str] = []
    for case in cases:
        value = require_object(case, "normalization case")
        case_id = value.get("id")
        if not isinstance(case_id, str):
            raise ContractValidationError("Normalization case has no string id")
        ids.append(case_id)
        expected_error = value.get("expectedError", False)
        try:
            actual = normalize_server_base(
                value["input"], value.get("allowDebugHttp", False)
            )
        except ContractValidationError:
            if not expected_error:
                raise
        else:
            if expected_error:
                raise ContractValidationError(
                    f"Normalization case {case_id} unexpectedly accepted {actual}"
                )
            if actual != value.get("expected"):
                raise ContractValidationError(
                    f"Normalization case {case_id} returned {actual}, "
                    f"expected {value.get('expected')}"
                )

    if len(ids) != len(set(ids)):
        raise ContractValidationError("Normalization case ids must be unique")
    if set(ids) != REQUIRED_NORMALIZATION_IDS:
        raise ContractValidationError(
            "Normalization coverage mismatch; "
            f"missing={sorted(REQUIRED_NORMALIZATION_IDS - set(ids))}, "
            f"unexpected={sorted(set(ids) - REQUIRED_NORMALIZATION_IDS)}"
        )
    return len(cases)


def walk_json(value: Any) -> Any:
    if isinstance(value, dict):
        for key, item in value.items():
            yield key, item
            yield from walk_json(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk_json(item)


def scan_fixture_secrets(paths: set[Path]) -> None:
    forbidden_raw = [
        re.compile(r"nks-garage", re.IGNORECASE),
        re.compile(r"-----BEGIN (?:RSA )?PRIVATE KEY-----"),
        re.compile(
            r"\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\b"
        ),
        re.compile(
            r'"(?:private_key|client_email|refresh_token|access_token)"\s*:',
            re.IGNORECASE,
        ),
    ]
    for path in paths:
        raw = path.read_text(encoding="utf-8")
        for pattern in forbidden_raw:
            if pattern.search(raw):
                raise ContractValidationError(
                    f"Fixture secret scan rejected {path.name}: {pattern.pattern}"
                )
        for key, value in walk_json(load_json(path)):
            if key == "appPassword" and (
                not isinstance(value, str) or not value.startswith("fixture-")
            ):
                raise ContractValidationError(
                    f"Fixture {path.name} contains a non-synthetic app password"
                )


def fetch_json(url: str, headers: dict[str, str]) -> Any:
    request = Request(
        url,
        method="GET",
        headers={
            "Accept": "application/json",
            "User-Agent": "com.nkshub.nextcloudtalk bootstrap-contract/0.1",
            **headers,
        },
    )
    opener = build_opener(NoRedirectHandler())
    try:
        with opener.open(request, timeout=15) as response:
            content_length = response.headers.get("Content-Length")
            if (
                content_length is not None
                and int(content_length) > MAX_LIVE_RESPONSE_BYTES
            ):
                raise ContractValidationError("Live response exceeds the byte limit")
            payload = response.read(MAX_LIVE_RESPONSE_BYTES + 1)
            if len(payload) > MAX_LIVE_RESPONSE_BYTES:
                raise ContractValidationError("Live response exceeds the byte limit")
            if response.status != 200:
                raise ContractValidationError(
                    f"Live endpoint returned unexpected HTTP {response.status}"
                )
    except (HTTPError, URLError, TimeoutError, ValueError) as error:
        raise ContractValidationError(f"Live request failed: {error}") from error

    try:
        return json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ContractValidationError(
            "Live endpoint did not return UTF-8 JSON"
        ) from error


def live_smoke(document: dict[str, Any], raw_origin: str) -> tuple[int, int]:
    origin = normalize_server_base(raw_origin)
    status = fetch_json(f"{origin}/status.php", {})
    status_operation = find_operation(document, "getServerStatus")
    status_fixture = {"status": "200", "mediaType": "application/json"}
    status_schema = response_schema(document, status_operation, status_fixture)
    errors = validate_json_schema(status, expand_references(status_schema, document))
    if errors:
        raise ContractValidationError(
            "Live status violates the contract: " + "; ".join(errors)
        )
    blockers = status_blockers(status)
    if blockers:
        raise ContractValidationError(f"Live server is not ready: {blockers}")

    capabilities = fetch_json(
        f"{origin}/ocs/v2.php/cloud/capabilities?format=json",
        {"OCS-APIRequest": "true"},
    )
    capability_operation = find_operation(document, "getCapabilities")
    capability_fixture = {"status": "200", "mediaType": "application/json"}
    capability_schema = response_schema(
        document, capability_operation, capability_fixture
    )
    errors = validate_json_schema(
        capabilities, expand_references(capability_schema, document)
    )
    if errors:
        raise ContractValidationError(
            "Live capabilities violate the contract: " + "; ".join(errors)
        )

    value = require_object(capabilities, "live capabilities")
    ocs = require_object(value.get("ocs"), "live OCS envelope")
    meta = require_object(ocs.get("meta"), "live OCS metadata")
    data = require_object(ocs.get("data"), "live OCS data")
    namespaces = require_object(data.get("capabilities"), "live capability namespaces")
    if meta.get("status") != "ok" or meta.get("statuscode") != 200:
        raise ContractValidationError("Live capability OCS status is not successful")
    spreed = require_object(namespaces.get("spreed"), "live spreed capability")
    talk_features = string_set(spreed.get("features"), "live spreed.features")
    return len(namespaces), len(talk_features)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate the Nextcloud client bootstrap compatibility contract."
    )
    parser.add_argument(
        "--live-origin",
        help="Run an additional read-only status and anonymous-capability smoke.",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        manifest = require_object(load_json(MANIFEST_PATH), MANIFEST_PATH.name)
        contract_path = (FIXTURE_ROOT / manifest["contract"]).resolve()
        if (
            contract_path.parent != CONTRACT_ROOT
            or contract_path.name != "openapi.json"
        ):
            raise ContractValidationError(
                "Manifest contract must resolve to openapi.json"
            )
        document = require_object(load_json(contract_path), contract_path.name)
        validate_spec(document)

        fixtures = manifest.get("fixtures")
        if not isinstance(fixtures, list) or not fixtures:
            raise ContractValidationError("Manifest must contain at least one fixture")

        fixture_ids: list[str] = []
        listed_paths: set[Path] = set()
        totals = {"status": 0, "loginTrust": 0, "credentials": 0, "capabilities": 0}
        for raw_fixture in fixtures:
            fixture = require_object(raw_fixture, "fixture manifest entry")
            fixture_id = fixture.get("id")
            fixture_file = fixture.get("file")
            if not isinstance(fixture_id, str) or not isinstance(fixture_file, str):
                raise ContractValidationError("Every fixture needs string id and file")
            fixture_ids.append(fixture_id)
            fixture_path = (FIXTURE_ROOT / fixture_file).resolve()
            if fixture_path.parent != FIXTURE_ROOT or fixture_path.suffix != ".json":
                raise ContractValidationError(f"Invalid fixture path: {fixture_file}")
            if fixture_path in listed_paths:
                raise ContractValidationError(
                    f"Fixture is listed twice: {fixture_file}"
                )
            listed_paths.add(fixture_path)
            counts = validate_fixture(document, fixture)
            for key, value in counts.items():
                totals[key] += value

        if len(fixture_ids) != len(set(fixture_ids)):
            raise ContractValidationError("Fixture ids must be unique")
        if set(fixture_ids) != REQUIRED_FIXTURE_IDS:
            raise ContractValidationError(
                "Fixture coverage mismatch; "
                f"missing={sorted(REQUIRED_FIXTURE_IDS - set(fixture_ids))}, "
                f"unexpected={sorted(set(fixture_ids) - REQUIRED_FIXTURE_IDS)}"
            )

        normalization_name = manifest.get("normalizationCasesFile")
        if not isinstance(normalization_name, str):
            raise ContractValidationError("Manifest has no normalizationCasesFile")
        normalization_path = (FIXTURE_ROOT / normalization_name).resolve()
        if normalization_path.parent != FIXTURE_ROOT:
            raise ContractValidationError("Normalization fixture must stay in fixtures")
        listed_paths.add(normalization_path)
        normalization_count = validate_normalization_cases(normalization_path)

        actual_paths = {
            path.resolve()
            for path in FIXTURE_ROOT.glob("*.json")
            if path.name != MANIFEST_PATH.name
        }
        if actual_paths != listed_paths:
            raise ContractValidationError(
                "Fixture manifest mismatch; "
                f"unlisted={sorted(path.name for path in actual_paths - listed_paths)}, "
                f"missing={sorted(path.name for path in listed_paths - actual_paths)}"
            )
        scan_fixture_secrets(listed_paths | {MANIFEST_PATH.resolve()})

        live_summary = ""
        if arguments.live_origin:
            namespace_count, feature_count = live_smoke(document, arguments.live_origin)
            live_summary = (
                f" Live smoke found {namespace_count} anonymous namespaces and "
                f"{feature_count} Talk features."
            )

        print(
            "Validated 1 OpenAPI document, "
            f"{len(fixtures)} fixtures, {normalization_count} origin cases, "
            f"{totals['status']} status classifications, "
            f"{totals['loginTrust']} login trust scenarios, "
            f"{totals['credentials']} credential scenarios and "
            f"{totals['capabilities']} capability snapshots."
            f"{live_summary}"
        )
        return 0
    except (
        ContractValidationError,
        KeyError,
        OSError,
        TypeError,
        json.JSONDecodeError,
    ) as error:
        print(f"Contract validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
