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
            "threadId": None,
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
            "threadId": 700,
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


class NamedThreadContractTest(unittest.TestCase):
    def test_named_direct_post_remains_parentless(self) -> None:
        response = chat_contract.load_json(
            CONTRACT_ROOT / "fixtures" / "send-named-thread-success.response.json"
        )
        history = chat_contract.load_json(
            CONTRACT_ROOT / "fixtures" / "chat-thread-future.response.json"
        )
        response["ocs"]["data"]["parent"] = history["ocs"]["data"][0]["parent"]

        with self.assertRaises(chat_contract.ResponseSemanticError):
            chat_contract.classify_send_response(
                response,
                "201",
                {
                    "roomToken": "rooma123",
                    "referenceId": "66666666-6666-4666-8666-666666666666",
                    "threadId": 700,
                },
                {"X-Chat-Last-Common-Read": "110"},
            )

    def test_named_authoritative_history_accepts_its_bound_full_parent(self) -> None:
        history = chat_contract.load_json(
            CONTRACT_ROOT / "fixtures" / "chat-thread-future.response.json"
        )
        message = history["ocs"]["data"][0]
        operation = {
            "roomToken": "rooma123",
            "referenceId": "66666666-6666-4666-8666-666666666666",
            "replyTo": None,
            "threadId": 700,
        }

        self.assertTrue(
            chat_contract.authoritative_message_matches_operation(
                message,
                operation,
            )
        )

        parentless = deepcopy(message)
        parentless["parent"] = None
        self.assertFalse(
            chat_contract.authoritative_message_matches_operation(
                parentless,
                operation,
            )
        )

        for field, value in (
            ("id", 701),
            ("token", "roomb123"),
            ("threadId", 701),
        ):
            with self.subTest(field=field):
                mismatched = deepcopy(message)
                mismatched["parent"][field] = value
                self.assertFalse(
                    chat_contract.authoritative_message_matches_operation(
                        mismatched,
                        operation,
                    )
                )

    def test_named_authoritative_deleted_parent_requires_the_thread_root_id(
        self,
    ) -> None:
        operation = {
            "roomToken": "rooma123",
            "referenceId": "66666666-6666-4666-8666-666666666666",
            "replyTo": None,
            "threadId": 700,
        }
        message = {
            "id": 702,
            "token": "rooma123",
            "referenceId": "66666666-6666-4666-8666-666666666666",
            "threadId": 700,
            "parent": {"id": 700, "deleted": True},
        }

        self.assertTrue(
            chat_contract.authoritative_message_matches_operation(
                message,
                operation,
            )
        )
        message["parent"]["id"] = 701
        self.assertFalse(
            chat_contract.authoritative_message_matches_operation(
                message,
                operation,
            )
        )

    def test_named_authoritative_full_deleted_parent_remains_bound(self) -> None:
        operation = {
            "roomToken": "rooma123",
            "referenceId": "66666666-6666-4666-8666-666666666666",
            "replyTo": None,
            "threadId": 700,
        }
        message = {
            "id": 702,
            "token": "rooma123",
            "referenceId": "66666666-6666-4666-8666-666666666666",
            "threadId": 700,
            "parent": {
                "id": 700,
                "token": "rooma123",
                "threadId": 700,
                "deleted": True,
            },
        }

        self.assertTrue(
            chat_contract.authoritative_message_matches_operation(
                message,
                operation,
            )
        )
        for field, value in (("token", "roomb123"), ("threadId", 701)):
            with self.subTest(field=field):
                mismatched = deepcopy(message)
                mismatched["parent"][field] = value
                self.assertFalse(
                    chat_contract.authoritative_message_matches_operation(
                        mismatched,
                        operation,
                    )
                )

    def test_plain_root_uses_its_own_id_as_thread(self) -> None:
        response = chat_contract.load_json(
            CONTRACT_ROOT / "fixtures" / "send-success.response.json"
        )
        context = {
            "roomToken": "rooma123",
            "referenceId": "11111111-1111-4111-8111-111111111111",
        }

        result = chat_contract.classify_send_response(
            response,
            "201",
            context,
            {"X-Chat-Last-Common-Read": "110"},
        )
        self.assertEqual(result["classification"], "send-confirmed")

        response["ocs"]["data"]["threadId"] = 700
        with self.assertRaises(chat_contract.ResponseSemanticError):
            chat_contract.classify_send_response(
                response,
                "201",
                context,
                {"X-Chat-Last-Common-Read": "110"},
            )

    def test_same_room_reply_uses_the_parent_topmost_thread(self) -> None:
        response = chat_contract.load_json(
            CONTRACT_ROOT / "fixtures" / "send-reply-success.response.json"
        )
        context = {
            "roomToken": "rooma123",
            "referenceId": "22222222-2222-4222-8222-222222222222",
            "replyTo": 108,
            "parentRoomToken": "rooma123",
        }

        result = chat_contract.classify_send_response(
            response,
            "201",
            context,
            {"X-Chat-Last-Common-Read": "110"},
        )
        self.assertEqual(result["classification"], "send-confirmed")

        response["ocs"]["data"]["threadId"] = 109
        with self.assertRaises(chat_contract.ResponseSemanticError):
            chat_contract.classify_send_response(
                response,
                "201",
                context,
                {"X-Chat-Last-Common-Read": "110"},
            )

    def test_private_reply_uses_the_copied_parent_as_thread_root(self) -> None:
        response = chat_contract.load_json(
            CONTRACT_ROOT / "fixtures" / "send-cross-room-reply-success.response.json"
        )
        context = {
            "roomToken": "direct456",
            "referenceId": "33333333-3333-4333-8333-333333333333",
            "replyTo": 333,
            "replyToToken": "source789",
            "parentRoomToken": "source789",
        }

        result = chat_contract.classify_send_response(
            response,
            "201",
            context,
            {"X-Chat-Last-Common-Read": "110"},
        )
        self.assertEqual(result["classification"], "send-confirmed")

        response["ocs"]["data"]["parent"]["threadId"] = 1210
        with self.assertRaises(chat_contract.ResponseSemanticError):
            chat_contract.classify_send_response(
                response,
                "201",
                context,
                {"X-Chat-Last-Common-Read": "110"},
            )

    def test_plain_send_rejects_a_thread_message(self) -> None:
        response = chat_contract.load_json(
            CONTRACT_ROOT / "fixtures" / "send-named-thread-success.response.json"
        )

        with self.assertRaises(chat_contract.ResponseSemanticError):
            chat_contract.classify_send_response(
                response,
                "201",
                {
                    "roomToken": "rooma123",
                    "referenceId": "66666666-6666-4666-8666-666666666666",
                },
                {"X-Chat-Last-Common-Read": "110"},
            )

    def test_send_response_rejects_a_different_named_thread(self) -> None:
        response = chat_contract.load_json(
            CONTRACT_ROOT / "fixtures" / "send-named-thread-success.response.json"
        )
        response["ocs"]["data"]["threadId"] = 701

        with self.assertRaises(chat_contract.ResponseSemanticError):
            chat_contract.classify_send_response(
                response,
                "201",
                {
                    "roomToken": "rooma123",
                    "referenceId": "66666666-6666-4666-8666-666666666666",
                    "threadId": 700,
                },
                {"X-Chat-Last-Common-Read": "110"},
            )

    def test_outbox_normalizer_rejects_mixed_reply_context(self) -> None:
        operation = {
            "operationId": "aaaaaaaa-0000-4000-8000-000000000099",
            "operationKind": "textSend",
            "roomToken": "rooma123",
            "referenceId": "99999999-9999-4999-8999-999999999999",
            "message": "Synthetic mixed reply context",
            "replayContractRevision": chat_contract.TEXT_SEND_REVISION,
            "enqueueSequence": 1,
            "replyTo": 108,
            "threadId": 700,
            "parentRoomToken": "rooma123",
        }

        with self.assertRaises(chat_contract.ContractValidationError):
            chat_contract.normalize_outbox_operation(
                operation,
                "test operation",
                False,
            )

    def test_plain_operation_does_not_match_a_thread_message(self) -> None:
        operation = {
            "roomToken": "rooma123",
            "referenceId": "99999999-9999-4999-8999-999999999999",
            "replyTo": None,
            "threadId": None,
        }
        message = {
            "id": 120,
            "token": "rooma123",
            "referenceId": "99999999-9999-4999-8999-999999999999",
            "threadId": 700,
        }

        self.assertFalse(
            chat_contract.authoritative_message_matches_operation(
                message,
                operation,
            )
        )

    def test_authoritative_root_and_reply_thread_semantics_match(self) -> None:
        reference = "99999999-9999-4999-8999-999999999999"
        cases = (
            (
                {
                    "id": 120,
                    "token": "rooma123",
                    "referenceId": reference,
                    "threadId": 120,
                },
                {
                    "roomToken": "rooma123",
                    "referenceId": reference,
                    "replyTo": None,
                    "threadId": None,
                },
            ),
            (
                {
                    "id": 121,
                    "token": "rooma123",
                    "referenceId": reference,
                    "threadId": 108,
                    "parent": {
                        "id": 108,
                        "token": "rooma123",
                        "threadId": 108,
                    },
                },
                {
                    "roomToken": "rooma123",
                    "referenceId": reference,
                    "replyTo": 108,
                    "threadId": None,
                    "replyToToken": None,
                    "parentRoomToken": "rooma123",
                },
            ),
            (
                {
                    "id": 122,
                    "token": "direct456",
                    "referenceId": reference,
                    "threadId": 1210,
                    "parent": {
                        "id": 1210,
                        "token": "source789",
                        "threadId": 0,
                        "metaData": {
                            "replyToMessageId": 333,
                            "replyToConversationToken": "source789",
                        },
                    },
                },
                {
                    "roomToken": "direct456",
                    "referenceId": reference,
                    "replyTo": 333,
                    "threadId": None,
                    "replyToToken": "source789",
                    "parentRoomToken": "source789",
                },
            ),
        )

        for message, operation in cases:
            with self.subTest(message_id=message["id"]):
                self.assertTrue(
                    chat_contract.authoritative_message_matches_operation(
                        message,
                        operation,
                    )
                )

    def test_named_replay_requires_the_full_capability_set(self) -> None:
        operation = {
            "replayContractRevision": chat_contract.TEXT_SEND_REVISION,
            "threadId": 700,
        }

        for capabilities in (
            ["chat-reference-id", "threads"],
            ["chat-v2", "threads"],
            ["chat-v2", "chat-reference-id"],
        ):
            with self.subTest(capabilities=capabilities):
                self.assertFalse(
                    chat_contract.outbox_replay_is_allowed(
                        operation,
                        {"capabilities": capabilities, "federated": False},
                    )
                )

        self.assertTrue(
            chat_contract.outbox_replay_is_allowed(
                operation,
                {
                    "capabilities": [
                        "chat-v2",
                        "chat-reference-id",
                        "threads",
                    ],
                    "federated": False,
                },
            )
        )
        self.assertFalse(
            chat_contract.outbox_replay_is_allowed(
                operation,
                {
                    "capabilities": [
                        "chat-v2",
                        "chat-reference-id",
                        "threads",
                    ],
                    "federated": True,
                },
            )
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
