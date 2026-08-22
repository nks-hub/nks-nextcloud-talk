from __future__ import annotations

import importlib.util
import sys
import unittest
import uuid
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch


CONTRACT_ROOT = Path(__file__).resolve().parent
MODULE_PATH = CONTRACT_ROOT / "validate_contract.py"
MODULE_SPEC = importlib.util.spec_from_file_location(
    "chat_messages_validate_contract",
    MODULE_PATH,
)
if MODULE_SPEC is None or MODULE_SPEC.loader is None:
    raise RuntimeError("Unable to load the chat messages contract validator")
chat_contract = importlib.util.module_from_spec(MODULE_SPEC)
sys.modules[MODULE_SPEC.name] = chat_contract
MODULE_SPEC.loader.exec_module(chat_contract)


class LiveWriteSmokeTest(unittest.TestCase):
    def test_send_response_is_confirmed_by_bounded_catch_up(self) -> None:
        document = chat_contract.load_json(CONTRACT_ROOT / "openapi.json")
        send_response = chat_contract.load_json(
            CONTRACT_ROOT / "fixtures" / "send-success.response.json"
        )
        confirmation_response = chat_contract.load_json(
            CONTRACT_ROOT / "fixtures" / "chat-send-confirmation.response.json"
        )
        responses = [
            (
                "201",
                send_response,
                {"X-Chat-Last-Common-Read": "110"},
            ),
            (
                "200",
                confirmation_response,
                {
                    "X-Chat-Last-Given": "120",
                    "X-Chat-Last-Common-Read": "110",
                },
            ),
        ]
        fixed_reference = uuid.UUID("11111111-1111-4111-8111-111111111111")

        with (
            patch.object(chat_contract.uuid, "uuid4", return_value=fixed_reference),
            patch.object(
                chat_contract,
                "fetch_live_response",
                side_effect=responses,
            ) as fetch,
        ):
            confirmations = chat_contract.live_write_smoke(
                document,
                "https://nextcloud.example.com",
                "rooma123",
                "Basic REDACTED",
                "114",
                "110",
            )

        self.assertEqual(1, confirmations)
        self.assertEqual(2, fetch.call_count)
        self.assertEqual("POST", fetch.call_args_list[0].args[0])
        self.assertEqual("GET", fetch.call_args_list[1].args[0])


class SendResponseContextTest(unittest.TestCase):
    def test_every_send_context_field_is_bound_to_the_operation(self) -> None:
        context = {
            "roomToken": "direct456",
            "referenceId": "33333333-3333-4333-8333-333333333333",
            "replyTo": 333,
            "replyToToken": "source789",
            "parentRoomToken": "source789",
        }
        record = {
            "metadata": {
                "direction": "response",
                "operationId": "sendChatMessage",
                "context": context,
            },
            "result": {"classification": "send-confirmed"},
        }
        self.assertTrue(chat_contract.send_response_matches_operation(record, context))

        mismatches = {
            "roomToken": "other456",
            "referenceId": "44444444-4444-4444-8444-444444444444",
            "replyTo": 334,
            "replyToToken": "source000",
            "parentRoomToken": "source000",
        }
        for field, value in mismatches.items():
            with self.subTest(field=field):
                operation = deepcopy(context)
                operation[field] = value
                self.assertFalse(
                    chat_contract.send_response_matches_operation(record, operation)
                )


class DiagnosticRedactionTest(unittest.TestCase):
    def test_form_round_trip_diagnostic_redacts_values(self) -> None:
        private_marker = "PRIVATE_MESSAGE_VALUE_REDACTION_GUARD"
        reference = "11111111-1111-4111-8111-111111111111"
        document = chat_contract.load_json(CONTRACT_ROOT / "openapi.json")
        request = chat_contract.build_wire_request(
            "send",
            {
                "message": private_marker,
                "referenceId": reference,
                "federated": False,
            },
            ["chat-v2", "chat-reference-id"],
        )
        parsed = {
            "message": ["DIFFERENT_PRIVATE_MESSAGE"],
            "referenceId": [reference],
        }

        with (
            patch.object(chat_contract, "parse_qs", return_value=parsed),
            self.assertRaises(chat_contract.ContractValidationError) as raised,
        ):
            chat_contract.validate_request_against_openapi(document, request)

        diagnostic = str(raised.exception)
        self.assertEqual("Form round trip changed wire section: body", diagnostic)
        self.assertNotIn(private_marker, diagnostic)
        self.assertNotIn(reference, diagnostic)

    def test_outbox_mismatch_diagnostic_redacts_room_tokens(self) -> None:
        private_marker = "PRIVATE_ROOM_TOKEN_REDACTION_GUARD"
        actual = {field: None for field in chat_contract.OUTBOX_SUMMARY_FIELDS}
        expected = deepcopy(actual)
        expected["replyToToken"] = private_marker
        expected["parentRoomToken"] = private_marker

        diagnostic = chat_contract.outbox_summary_mismatch_message(
            "redaction-guard",
            actual,
            expected,
        )

        self.assertEqual(
            "Outbox case redaction-guard differs in operation fields: "
            "replyToToken, parentRoomToken",
            diagnostic,
        )
        self.assertNotIn(private_marker, diagnostic)


if __name__ == "__main__":
    unittest.main()
