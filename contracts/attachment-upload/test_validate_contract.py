from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from copy import deepcopy
from pathlib import Path


CONTRACT_ROOT = Path(__file__).resolve().parent
MODULE_PATH = CONTRACT_ROOT / "validate_contract.py"
MODULE_SPEC = importlib.util.spec_from_file_location(
    "attachment_upload_validate_contract",
    MODULE_PATH,
)
if MODULE_SPEC is None or MODULE_SPEC.loader is None:
    raise RuntimeError("Unable to load the attachment-upload contract validator")
attachment_contract = importlib.util.module_from_spec(MODULE_SPEC)
sys.modules[MODULE_SPEC.name] = attachment_contract
MODULE_SPEC.loader.exec_module(attachment_contract)


def base_operation() -> dict[str, object]:
    state_cases = attachment_contract.load_json(
        CONTRACT_ROOT / "fixtures" / "state.cases.json"
    )
    return deepcopy(state_cases["baseOperation"])


def operation_binding(operation: dict[str, object]) -> dict[str, object]:
    return {
        "accountId": operation["accountId"],
        "server": operation["server"],
        "roomToken": operation["roomToken"],
    }


class CompleteContractTest(unittest.TestCase):
    def test_complete_contract_passes_with_manifested_counts(self) -> None:
        self.assertEqual(
            {
                "fixtures": 12,
                "capabilityCases": 15,
                "wireCases": 20,
                "davPlans": 7,
                "davStatuses": 11,
                "davXmlFixtures": 3,
                "stateCases": 25,
            },
            attachment_contract.validate_contract(),
        )


class BoundedParserTest(unittest.TestCase):
    def test_json_duplicate_depth_and_byte_budgets_are_enforced(self) -> None:
        nested: object = 0
        for _ in range(attachment_contract.MAX_JSON_DEPTH + 1):
            nested = [nested]
        cases = {
            "duplicate": b'{"safe":1,"safe":2}',
            "depth": json.dumps(nested).encode("utf-8"),
            "bytes": b" " * (attachment_contract.MAX_JSON_BYTES + 1),
        }

        for name, raw in cases.items():
            with self.subTest(name=name):
                with self.assertRaises(attachment_contract.ContractValidationError):
                    attachment_contract.decode_json_bytes(raw)

    def test_xml_declarations_and_byte_budget_are_rejected(self) -> None:
        cases = {
            "doctype": (
                b'<!DOCTYPE d:multistatus SYSTEM "private.dtd">'
                b'<d:multistatus xmlns:d="DAV:" />'
            ),
            "entity": (
                b'<d:multistatus xmlns:d="DAV:">'
                b'<!ENTITY private "value">'
                b"</d:multistatus>"
            ),
            "utf16-doctype": (
                '<?xml version="1.0" encoding="utf-16"?>'
                '<!DOCTYPE d:multistatus [<!ENTITY private "value">]>'
                '<d:multistatus xmlns:d="DAV:">&private;</d:multistatus>'
            ).encode("utf-16"),
            "depth": (
                '<d:multistatus xmlns:d="DAV:">'
                + "<x>" * attachment_contract.MAX_XML_DEPTH
                + "</x>" * attachment_contract.MAX_XML_DEPTH
                + "</d:multistatus>"
            ).encode("utf-8"),
            "bytes": b" " * (attachment_contract.MAX_XML_BYTES + 1),
        }

        for name, raw in cases.items():
            with self.subTest(name=name):
                with self.assertRaises(attachment_contract.ContractValidationError):
                    attachment_contract.parse_dav_multistatus_bytes(raw)


class PathAndDavPlanTest(unittest.TestCase):
    def test_unsafe_relative_paths_are_rejected(self) -> None:
        unsafe_paths = (
            "/Talk/file.bin",
            "Talk/../file.bin",
            "Talk//file.bin",
            "Talk\\file.bin",
            "Talk/%2e%2e/file.bin",
            "Talk/file.bin?download=1",
            "Talk/file.bin#fragment",
            "https://other.example.test/file.bin",
        )

        for path in unsafe_paths:
            with self.subTest(path=path):
                with self.assertRaises(attachment_contract.ContractValidationError):
                    attachment_contract.normalize_relative_path(path)

    def test_exact_multiple_chunk_plan_has_no_empty_chunk_or_range_header(self) -> None:
        chunk_size = 1_024_000
        file_size = chunk_size * 2
        plan = attachment_contract.build_dav_plan(
            "upload",
            {
                "accountId": "account-a",
                "server": "https://cloud.example.test",
                "userId": "user-a",
                "draftPath": "Talk/room-a/archive.bin",
                "uploadId": "11111111-1111-4111-8111-111111111111",
                "fileSize": file_size,
                "chunkThreshold": 1_048_576,
                "chunkSize": chunk_size,
                "existingChunks": [],
            },
        )

        self.assertEqual("chunked", plan["mode"])
        self.assertEqual(
            {
                "accountId": "account-a",
                "server": "https://cloud.example.test",
            },
            plan["binding"],
        )
        put_steps = [step for step in plan["steps"] if step["method"] == "PUT"]
        self.assertEqual(
            [chunk_size, chunk_size], [step["contentLength"] for step in put_steps]
        )
        self.assertEqual(
            [
                "0000000000000000-0000000001023999",
                "0000000001024000-0000000002047999",
            ],
            [step["uri"].rsplit("/", 1)[-1] for step in put_steps],
        )
        for step in plan["steps"]:
            self.assertNotIn("Range", step["headers"])
            self.assertNotIn("Content-Range", step["headers"])
        move = next(step for step in plan["steps"] if step["method"] == "MOVE")
        self.assertEqual(str(file_size), move["headers"]["OC-Total-Length"])


class OpenApiPolicyTest(unittest.TestCase):
    def test_both_talk_requests_require_literal_allow_update_false(self) -> None:
        document = attachment_contract.load_json(CONTRACT_ROOT / "openapi.json")
        self.assertEqual("3.1.0", document["openapi"])

        for operation_id in ("probeAttachmentFolder", "finalizeAttachment"):
            with self.subTest(operation_id=operation_id):
                _, _, operation = attachment_contract.find_operation(
                    document,
                    operation_id,
                )
                schema = attachment_contract.request_schema(
                    document,
                    operation,
                    "application/json",
                )
                self.assertIn("allowUpdate", schema["required"])
                self.assertIs(False, schema["properties"]["allowUpdate"]["const"])

    def test_openapi_rejects_dot_segments_like_runtime(self) -> None:
        document = attachment_contract.load_json(CONTRACT_ROOT / "openapi.json")
        _, _, operation = attachment_contract.find_operation(
            document,
            "finalizeAttachment",
        )
        schema = attachment_contract.request_schema(
            document,
            operation,
            "application/json",
        )

        errors = attachment_contract.validate_json_schema(
            {
                "filePath": "Talk/../private.bin",
                "referenceId": "22222222-2222-4222-8222-222222222222",
                "talkMetaData": "{}",
                "fileName": "private.bin",
                "allowUpdate": False,
            },
            schema,
        )

        self.assertIn("$.filePath [pattern]", errors)

        errors = attachment_contract.validate_json_schema(
            {
                "filePath": "Talk/private.bin",
                "referenceId": "22222222-2222-4222-8222-222222222222",
                "talkMetaData": "{}",
                "fileName": "private\u007f.bin",
                "allowUpdate": False,
            },
            schema,
        )
        self.assertIn("$.fileName [pattern]", errors)


class FinalizeMessageTypeBindingTest(unittest.TestCase):
    def test_finalize_metadata_must_match_job_message_type(self) -> None:
        base = {
            "accountId": "account-a",
            "requestId": "finalize-a",
            "server": "https://cloud.example.test",
            "roomToken": "rooma123",
            "filePath": "Talk/room-a/voice.upload",
            "referenceId": "22222222-2222-4222-8222-222222222222",
            "fileName": "voice.mp3",
            "allowUpdate": False,
        }
        mismatches = (
            {
                **base,
                "expectedMessageType": "voice-message",
                "metadata": {},
            },
            {
                **base,
                "expectedMessageType": "comment",
                "metadata": {"messageType": "voice-message"},
            },
        )

        for raw_input in mismatches:
            with self.subTest(expected=raw_input["expectedMessageType"]):
                with self.assertRaises(attachment_contract.ContractValidationError):
                    attachment_contract.build_wire_case("finalize", raw_input)

        request = attachment_contract.build_wire_case(
            "finalize",
            {
                **base,
                "expectedMessageType": "voice-message",
                "metadata": {"messageType": "voice-message"},
            },
        )
        self.assertEqual(
            '{"messageType":"voice-message"}',
            request["body"]["talkMetaData"],
        )

    def test_thread_title_is_bound_to_thread_metadata(self) -> None:
        base = {
            "accountId": "account-a",
            "requestId": "finalize-thread",
            "server": "https://cloud.example.test",
            "roomToken": "rooma123",
            "filePath": "Talk/room-a/photo.upload",
            "referenceId": "22222222-2222-4222-8222-222222222222",
            "fileName": "photo.jpg",
            "expectedMessageType": "comment",
            "allowUpdate": False,
        }
        request = attachment_contract.build_wire_case(
            "finalize",
            {
                **base,
                "metadata": {"threadId": 101, "threadTitle": "Synthetic thread"},
            },
        )
        self.assertEqual(
            '{"threadId":101,"threadTitle":"Synthetic thread"}',
            request["body"]["talkMetaData"],
        )

        with self.assertRaises(attachment_contract.ContractValidationError):
            attachment_contract.build_wire_case(
                "finalize",
                {**base, "metadata": {"threadTitle": "Synthetic thread"}},
            )

        with self.assertRaises(attachment_contract.ContractValidationError):
            attachment_contract.build_wire_case(
                "finalize",
                {
                    **base,
                    "metadata": {"replyTo": 101, "threadId": 101},
                },
            )

        invalid_titles = (" Synthetic thread", "Synthetic thread ", "x" * 201)
        for title in invalid_titles:
            with self.subTest(title_length=len(title)):
                with self.assertRaises(attachment_contract.ContractValidationError):
                    attachment_contract.build_wire_case(
                        "finalize",
                        {
                            **base,
                            "metadata": {"threadId": 101, "threadTitle": title},
                        },
                    )


class StateSafetyTest(unittest.TestCase):
    def test_reply_deleted_parent_scope_is_exact(self) -> None:
        operation = base_operation()
        operation.update(
            {
                "replyTo": 42,
                "phase": "awaitingConfirmation",
                "remoteTempPath": "Talk/room-a/upload.bin",
                "finalizationDispatched": True,
                "lastOutcome": "awaiting-confirmation",
            }
        )
        binding = operation_binding(operation)

        def confirmation(
            message_id: int,
            *,
            parent_id: int = 42,
            parent_room: str | None = None,
            parent_thread: int | None = None,
            thread_id: int = 77,
        ) -> dict[str, object]:
            return {
                **binding,
                "referenceId": operation["referenceId"],
                "systemMessage": "",
                "messageType": "comment",
                "messageId": message_id,
                "hasFileRichObject": True,
                "parentMessageId": parent_id,
                "parentRoomToken": parent_room,
                "parentThreadId": parent_thread,
                "parentDeleted": True,
                "replyToMessageId": None,
                "replyToRoomToken": None,
                "threadId": thread_id,
            }

        invalid_scopes = (
            confirmation(601, parent_id=41),
            confirmation(602, thread_id=0),
            confirmation(603, parent_room="rooma123"),
            confirmation(604, parent_thread=77),
        )
        for candidate in invalid_scopes:
            with self.subTest(message_id=candidate["messageId"]):
                attempt = deepcopy(operation)
                self.assertEqual(
                    "no-match",
                    attachment_contract.apply_state_step(
                        attempt,
                        {
                            "action": "confirm",
                            "binding": binding,
                            "matches": [candidate],
                        },
                    ),
                )

        self.assertEqual(
            "completed",
            attachment_contract.apply_state_step(
                operation,
                {
                    "action": "confirm",
                    "binding": binding,
                    "matches": [confirmation(605)],
                },
            ),
        )
        self.assertEqual([605], operation["messageIds"])

    def test_operation_rejects_mixed_reply_and_named_thread_scope(self) -> None:
        operation = base_operation()
        operation.update({"replyTo": 42, "threadId": 84})

        with self.assertRaises(attachment_contract.ContractValidationError):
            attachment_contract.validate_operation(operation)

    def test_blind_finalize_replay_is_rejected_without_mutation(self) -> None:
        operation = base_operation()
        operation.update(
            {
                "phase": "awaitingConfirmation",
                "remoteTempPath": "Talk/room-a/upload.bin",
                "finalizationDispatched": True,
                "lastOutcome": "awaiting-confirmation",
            }
        )
        attachment_contract.validate_operation(operation)
        before = deepcopy(operation)

        outcome = attachment_contract.apply_state_step(
            operation,
            {
                "action": "blindFinalizeReplay",
                "binding": operation_binding(operation),
            },
        )

        self.assertEqual("rejected", outcome)
        self.assertEqual(before, operation)

    def test_cross_account_and_origin_transitions_are_rejected(self) -> None:
        source = base_operation()
        bindings = {
            "account": {
                "accountId": "other-account",
                "server": source["server"],
                "roomToken": source["roomToken"],
            },
            "origin": {
                "accountId": source["accountId"],
                "server": "https://other.example.test",
                "roomToken": source["roomToken"],
            },
        }

        for name, binding in bindings.items():
            with self.subTest(name=name):
                operation = deepcopy(source)
                before = deepcopy(operation)
                outcome = attachment_contract.apply_state_step(
                    operation,
                    {
                        "action": "probeStart",
                        "allowUpdate": False,
                        "binding": binding,
                    },
                )
                self.assertEqual("rejected", outcome)
                self.assertEqual(before, operation)

    def test_missing_transition_binding_is_rejected_without_mutation(self) -> None:
        operation = base_operation()
        before = deepcopy(operation)

        outcome = attachment_contract.apply_state_step(
            operation,
            {"action": "probeStart", "allowUpdate": False},
        )

        self.assertEqual("rejected", outcome)
        self.assertEqual(before, operation)

    def test_upload_and_resume_require_fresh_source_verification(self) -> None:
        operation = base_operation()
        operation.update(
            {
                "phase": "draftResolved",
                "remoteTempPath": "Talk/room-a/upload.bin",
                "lastOutcome": "draft-resolved",
            }
        )
        binding = operation_binding(operation)

        self.assertEqual(
            "rejected",
            attachment_contract.apply_state_step(
                operation,
                {"action": "uploadStart", "binding": binding},
            ),
        )
        self.assertEqual(
            "source-valid",
            attachment_contract.apply_state_step(
                operation,
                {
                    "action": "sourceCheck",
                    "binding": binding,
                    "size": operation["source"]["size"],
                    "sha256": operation["source"]["sha256"],
                },
            ),
        )
        self.assertTrue(operation["sourceVerified"])
        self.assertEqual(
            "uploading",
            attachment_contract.apply_state_step(
                operation,
                {"action": "uploadStart", "binding": binding},
            ),
        )
        self.assertFalse(operation["sourceVerified"])

    def test_voice_confirmation_requires_exact_message_type(self) -> None:
        operation = base_operation()
        operation.update(
            {
                "expectedMessageType": "voice-message",
                "phase": "awaitingConfirmation",
                "remoteTempPath": "Talk/room-a/voice.upload",
                "finalizationDispatched": True,
                "lastOutcome": "awaiting-confirmation",
                "source": {
                    "handle": "app-owned-voice-a",
                    "size": 4096,
                    "sha256": "b" * 64,
                    "mime": "audio/mpeg",
                    "displayName": "voice.mp3",
                },
            }
        )
        binding = operation_binding(operation)

        def confirmation(message_id: int, message_type: str) -> dict[str, object]:
            return {
                **binding,
                "referenceId": operation["referenceId"],
                "systemMessage": "",
                "messageType": message_type,
                "messageId": message_id,
                "hasFileRichObject": True,
                "parentMessageId": None,
                "parentRoomToken": None,
                "parentThreadId": None,
                "parentDeleted": False,
                "replyToMessageId": None,
                "replyToRoomToken": None,
                "threadId": message_id,
            }

        self.assertEqual(
            "no-match",
            attachment_contract.apply_state_step(
                operation,
                {
                    "action": "confirm",
                    "binding": binding,
                    "matches": [confirmation(501, "comment")],
                },
            ),
        )
        self.assertEqual(
            "ambiguous-match",
            attachment_contract.apply_state_step(
                operation,
                {
                    "action": "confirm",
                    "binding": binding,
                    "matches": [
                        confirmation(501, "voice-message"),
                        confirmation(502, "voice-message"),
                    ],
                },
            ),
        )
        self.assertEqual([501, 502], operation["messageIds"])


class DiagnosticRedactionTest(unittest.TestCase):
    def test_request_schema_diagnostic_does_not_disclose_private_value(self) -> None:
        private_marker = "PRIVATE_ATTACHMENT_NAME_REDACTION_GUARD"
        document = attachment_contract.load_json(CONTRACT_ROOT / "openapi.json")
        request = attachment_contract.build_wire_case(
            "finalize",
            {
                "accountId": "account-a",
                "requestId": "request-a",
                "server": "https://cloud.example.test",
                "roomToken": "rooma123",
                "filePath": "Talk/room-a/image.png",
                "referenceId": "22222222-2222-4222-8222-222222222222",
                "metadata": {"caption": "Safe caption"},
                "fileName": "image.png",
                "expectedMessageType": "comment",
                "allowUpdate": False,
            },
        )
        request["body"]["fileName"] = private_marker * 10

        with self.assertRaises(attachment_contract.ContractValidationError) as raised:
            attachment_contract.validate_built_request(document, request)

        diagnostic = str(raised.exception)
        self.assertIn("$.fileName [maxLength]", diagnostic)
        self.assertNotIn(private_marker, diagnostic)

    def test_state_mismatch_diagnostic_reports_fields_only(self) -> None:
        private_marker = "PRIVATE_REMOTE_PATH_REDACTION_GUARD"
        actual = {field: None for field in attachment_contract.STATE_SUMMARY_FIELDS}
        expected = deepcopy(actual)
        expected["lastOutcome"] = private_marker

        diagnostic = attachment_contract.state_summary_mismatch_message(
            "redaction-guard",
            actual,
            expected,
        )

        self.assertEqual(
            "State case redaction-guard differs in operation fields: lastOutcome",
            diagnostic,
        )
        self.assertNotIn(private_marker, diagnostic)


if __name__ == "__main__":
    unittest.main()
