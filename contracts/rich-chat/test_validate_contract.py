from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch


CONTRACT_ROOT = Path(__file__).resolve().parent
MODULE_PATH = CONTRACT_ROOT / "validate_contract.py"
MODULE_SPEC = importlib.util.spec_from_file_location(
    "rich_chat_validate_contract",
    MODULE_PATH,
)
if MODULE_SPEC is None or MODULE_SPEC.loader is None:
    raise RuntimeError("Unable to load the rich-chat contract validator")
rich_contract = importlib.util.module_from_spec(MODULE_SPEC)
sys.modules[MODULE_SPEC.name] = rich_contract
MODULE_SPEC.loader.exec_module(rich_contract)


def fixture_cases(name: str) -> list[dict[str, object]]:
    document = rich_contract.load_json(CONTRACT_ROOT / "fixtures" / name)
    return document["cases"]


def response_records() -> dict[str, dict[str, object]]:
    document = rich_contract.load_json(CONTRACT_ROOT / "openapi.json")
    return rich_contract.validate_response_cases(
        document,
        fixture_cases("responses.cases.json"),
    )


class CompleteContractTest(unittest.TestCase):
    def test_complete_contract_passes_with_manifested_counts(self) -> None:
        self.assertEqual(
            {
                "operations": 21,
                "responses": 23,
                "requests": 28,
                "capabilities": 8,
                "render": 9,
                "state": 7,
                "stateSteps": 8,
            },
            rich_contract.validate_contract(),
        )


class ResponsePolicyTest(unittest.TestCase):
    def test_http_and_ocs_success_codes_must_match_exactly(self) -> None:
        document = rich_contract.load_json(CONTRACT_ROOT / "openapi.json")
        case = next(
            deepcopy(case)
            for case in fixture_cases("responses.cases.json")
            if case["id"] == "schedule-created"
        )
        case["body"]["ocs"]["meta"]["statuscode"] = 200

        with self.assertRaises(rich_contract.ResponseSemanticError) as raised:
            rich_contract.validate_response_cases(document, [case])

        self.assertEqual(
            "HTTP status and OCS statuscode do not match",
            str(raised.exception),
        )

    def test_thread_messages_require_canonical_thread_identity(self) -> None:
        document = rich_contract.load_json(CONTRACT_ROOT / "openapi.json")
        fixture = next(
            case
            for case in fixture_cases("responses.cases.json")
            if case["id"] == "thread-detail-success"
        )

        for field in ("first", "last"):
            with self.subTest(field=field):
                case = deepcopy(fixture)
                case["body"]["ocs"]["data"][field]["threadId"] = 999

                with self.assertRaises(rich_contract.ResponseSemanticError) as raised:
                    rich_contract.validate_response_cases(document, [case])

                self.assertEqual(
                    f"Thread {field} message thread id mismatch",
                    str(raised.exception),
                )


class CapabilityPolicyTest(unittest.TestCase):
    def test_scheduled_messages_are_local_and_non_federated_only(self) -> None:
        global_only = rich_contract.resolve_capabilities(
            ["chat-v2", "scheduled-messages"],
            [],
            False,
            False,
            0,
        )
        federated = rich_contract.resolve_capabilities(
            ["chat-v2"],
            ["scheduled-messages"],
            True,
            False,
            0,
        )
        local = rich_contract.resolve_capabilities(
            ["chat-v2"],
            ["scheduled-messages"],
            False,
            False,
            0,
        )

        self.assertFalse(global_only["scheduled"])
        self.assertFalse(federated["scheduled"])
        self.assertTrue(local["scheduled"])


class RequestPrivacyTest(unittest.TestCase):
    def test_form_round_trip_error_does_not_disclose_message(self) -> None:
        private_message = "PRIVATE_MESSAGE_VALUE"
        request = rich_contract.build_wire_request(
            "editMessage",
            {
                "roomToken": "rooma123",
                "messageId": 120,
                "message": private_message,
            },
            {
                "talkFeatures": ["chat-v2", "edit-messages"],
                "talkLocalFeatures": [],
                "federated": False,
                "moderator": False,
                "participantPermissions": 0,
            },
        )
        document = rich_contract.load_json(CONTRACT_ROOT / "openapi.json")

        with (
            patch.object(
                rich_contract,
                "parse_qs",
                return_value={"message": ["DIFFERENT_PRIVATE_MESSAGE"]},
            ),
            self.assertRaises(rich_contract.ContractValidationError) as raised,
        ):
            rich_contract.validate_request_against_openapi(document, request)

        self.assertEqual(
            "Form round trip changed wire section: body",
            str(raised.exception),
        )
        self.assertNotIn(private_message, str(raised.exception))


class ThreadRequestBindingTest(unittest.TestCase):
    def test_notification_requires_positive_canonical_thread_id(self) -> None:
        profile = {
            "talkFeatures": ["chat-v2", "threads"],
            "talkLocalFeatures": [],
            "federated": True,
            "moderator": False,
            "participantPermissions": 0,
        }
        for invalid_thread_id in (None, 0):
            values = {
                "roomToken": "rooma123",
                "level": 3,
            }
            if invalid_thread_id is not None:
                values["threadId"] = invalid_thread_id

            with (
                self.subTest(thread_id=invalid_thread_id),
                self.assertRaises(rich_contract.ContractValidationError),
            ):
                rich_contract.build_wire_request("notifyThread", values, profile)

    def test_notification_targets_only_the_canonical_thread_root(self) -> None:
        profile = {
            "talkFeatures": ["chat-v2", "threads"],
            "talkLocalFeatures": [],
            "federated": True,
            "moderator": False,
            "participantPermissions": 0,
        }

        request = rich_contract.build_wire_request(
            "notifyThread",
            {"roomToken": "rooma123", "threadId": 120, "level": 3},
            profile,
        )

        self.assertEqual(
            "/ocs/v2.php/apps/spreed/api/v1/chat/rooma123/threads/120/notify",
            request["path"],
        )

    def test_notification_response_requires_canonical_thread_context(self) -> None:
        document = rich_contract.load_json(CONTRACT_ROOT / "openapi.json")
        case = next(
            deepcopy(case)
            for case in fixture_cases("responses.cases.json")
            if case["id"] == "thread-notify-success"
        )
        case["context"].pop("threadId")
        case["body"]["ocs"]["data"]["thread"]["id"] = 122

        with self.assertRaises(rich_contract.ResponseSemanticError) as raised:
            rich_contract.validate_response_cases(document, [case])

        self.assertEqual(
            "Thread notification canonical id context missing",
            str(raised.exception),
        )

    def test_notification_response_rejects_legacy_message_context(self) -> None:
        document = rich_contract.load_json(CONTRACT_ROOT / "openapi.json")
        case = next(
            deepcopy(case)
            for case in fixture_cases("responses.cases.json")
            if case["id"] == "thread-notify-success"
        )
        case["context"]["messageId"] = 122

        with self.assertRaises(rich_contract.ResponseSemanticError) as raised:
            rich_contract.validate_response_cases(document, [case])

        self.assertEqual(
            "Thread notification legacy message id context is forbidden",
            str(raised.exception),
        )

    def test_notification_response_rejects_reply_identity_as_root(self) -> None:
        document = rich_contract.load_json(CONTRACT_ROOT / "openapi.json")
        case = next(
            deepcopy(case)
            for case in fixture_cases("responses.cases.json")
            if case["id"] == "thread-notify-success"
        )
        case["body"]["ocs"]["data"]["thread"]["id"] = 122

        with self.assertRaises(rich_contract.ResponseSemanticError) as raised:
            rich_contract.validate_response_cases(document, [case])

        self.assertEqual(
            "Thread response id binding mismatch",
            str(raised.exception),
        )


class RenderPolicyTest(unittest.TestCase):
    def test_code_placeholder_and_unsafe_link_remain_inert(self) -> None:
        result = rich_contract.render_contract(
            "\x60{user}\x60 {user} [bad](javascript:alert(1))",
            True,
            {
                "user": {
                    "type": "user",
                    "id": "user-a",
                    "name": "User A",
                }
            },
        )

        self.assertEqual(1, result["richObjects"])
        self.assertEqual(["{user}"], result["codeLiterals"])
        self.assertEqual([], result["activeLinks"])


class StatePlanTest(unittest.TestCase):
    def setUp(self) -> None:
        self.responses = response_records()
        self.case = next(
            deepcopy(case)
            for case in fixture_cases("state.cases.json")
            if case["id"] == "edit-updates-message-thread-and-preview"
        )

    def test_failed_persistence_keeps_every_copy_unchanged(self) -> None:
        state = rich_contract.initial_state()
        plan = rich_contract.prepare_state_plan(
            state,
            self.case,
            self.responses["edit-message-success"],
        )

        rolled_back = plan.commit(state, persisted=False)

        self.assertIs(state, rolled_back)
        self.assertEqual(
            {
                "message": "Original text",
                "threadFirstMessage": "Original text",
                "roomPreviewMessage": "Original text",
                "deleted": False,
            },
            rich_contract.state_summary(rolled_back, self.case),
        )

    def test_plan_is_single_use_and_source_identity_bound(self) -> None:
        state = rich_contract.initial_state()
        plan = rich_contract.prepare_state_plan(
            state,
            self.case,
            self.responses["edit-message-success"],
        )
        candidate = plan.commit(state, persisted=True)
        self.assertEqual(
            "Edited **text**",
            rich_contract.state_summary(candidate, self.case)["message"],
        )
        with self.assertRaises(rich_contract.ContractValidationError):
            plan.commit(candidate, persisted=True)

        stale_plan = rich_contract.prepare_state_plan(
            state,
            self.case,
            self.responses["edit-message-success"],
        )
        with self.assertRaises(rich_contract.ContractValidationError):
            stale_plan.commit(deepcopy(state), persisted=True)


class SecretScanTest(unittest.TestCase):
    def test_secret_scan_rejects_credentials_without_echoing_them(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.json"
            secret = "DO_NOT_DISCLOSE_THIS_PASSWORD"
            path.write_text(
                json.dumps({"pass" + "word": secret}),
                encoding="utf-8",
            )

            with self.assertRaises(rich_contract.ContractValidationError) as raised:
                rich_contract.scan_secrets({path})

        self.assertNotIn(secret, str(raised.exception))


if __name__ == "__main__":
    unittest.main()
