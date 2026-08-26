from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


CONTRACT_ROOT = Path(__file__).resolve().parent
MODULE_PATH = CONTRACT_ROOT / "validate_contract.py"
MODULE_SPEC = importlib.util.spec_from_file_location(
    "signaling_validate_contract",
    MODULE_PATH,
)
if MODULE_SPEC is None or MODULE_SPEC.loader is None:
    raise RuntimeError("Unable to load the signaling contract validator")
signaling_contract = importlib.util.module_from_spec(MODULE_SPEC)
sys.modules[MODULE_SPEC.name] = signaling_contract
MODULE_SPEC.loader.exec_module(signaling_contract)

ContractValidationError = signaling_contract.ContractValidationError
decode_json_bytes = signaling_contract.decode_json_bytes
normalize_hpb_endpoint = signaling_contract.normalize_hpb_endpoint
normalize_nextcloud_server = signaling_contract.normalize_nextcloud_server
simulate_runtime = signaling_contract.simulate_runtime
validate_contract = signaling_contract.validate_contract
validate_hpb_case = signaling_contract.validate_hpb_case
validate_settings_case = signaling_contract.validate_settings_case
validate_peer_message = sys.modules["validator_signaling_hpb"].validate_peer_message


class SignalingContractValidatorTest(unittest.TestCase):
    def test_duplicate_json_members_are_rejected(self) -> None:
        with self.assertRaisesRegex(ContractValidationError, "duplicate member"):
            decode_json_bytes(b'{"type":"welcome","type":"hello"}')

    def test_hpb_endpoint_is_canonicalized_to_spreed_websocket(self) -> None:
        self.assertEqual(
            normalize_hpb_endpoint("https://hpb.example.invalid/signaling/"),
            "wss://hpb.example.invalid/signaling/spreed",
        )
        self.assertEqual(
            normalize_hpb_endpoint("wss://hpb.example.invalid/spreed"),
            "wss://hpb.example.invalid/spreed",
        )

    def test_cleartext_and_ambiguous_endpoints_are_rejected(self) -> None:
        for endpoint in (
            "http://hpb.example.invalid",
            "https://user@hpb.example.invalid",
            "https://hpb.example.invalid?tenant=synthetic",
            "https://hpb.example.invalid/#fragment",
        ):
            with self.subTest(endpoint=endpoint):
                with self.assertRaises(ContractValidationError):
                    normalize_hpb_endpoint(endpoint)

    def test_nextcloud_server_requires_https(self) -> None:
        self.assertEqual(
            normalize_nextcloud_server(
                "https://remote-cloud.example.invalid/nextcloud/"
            ),
            "https://remote-cloud.example.invalid/nextcloud",
        )
        with self.assertRaises(ContractValidationError):
            normalize_nextcloud_server("http://remote-cloud.example.invalid")

    def test_invalid_settings_case_must_fail_for_declared_reason(self) -> None:
        validate_settings_case(
            {
                "id": "missing-auth",
                "valid": False,
                "data": {
                    "signalingMode": "external",
                    "userId": "synthetic-user-a",
                    "hideWarning": True,
                    "server": "https://hpb.example.invalid",
                    "federation": None,
                    "stunservers": [],
                    "turnservers": [],
                    "sipDialinInfo": "",
                    "helloAuthParams": {},
                },
                "error": "helloAuthParams",
            }
        )

    def test_unknown_server_frame_is_bounded_and_unsupported(self) -> None:
        validate_hpb_case(
            {
                "id": "future-frame",
                "direction": "server",
                "valid": True,
                "frame": {
                    "type": "synthetic-future",
                    "synthetic-future": {"bounded": True},
                },
                "expectedType": "unsupported",
            }
        )

    def test_known_malformed_server_frame_is_rejected(self) -> None:
        validate_hpb_case(
            {
                "id": "bad-update",
                "direction": "server",
                "valid": False,
                "frame": {
                    "type": "event",
                    "event": {
                        "target": "participants",
                        "type": "update",
                        "update": {
                            "roomid": "rooma123",
                            "all": False,
                            "incall": 1,
                        },
                    },
                },
                "error": "event.update.all",
            }
        )

    def test_payload_free_typing_messages_are_valid(self) -> None:
        for message_type in ("startedTyping", "stoppedTyping"):
            with self.subTest(message_type=message_type):
                validate_peer_message(
                    {"type": message_type},
                    "message.data",
                )

    def test_non_typing_message_without_payload_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            ContractValidationError,
            "message.data.payload",
        ):
            validate_peer_message(
                {"type": "offer"},
                "message.data",
            )

    def test_typing_payload_must_be_an_object_when_present(self) -> None:
        for message_type in ("startedTyping", "stoppedTyping"):
            for payload in (None, [], "not-an-object"):
                with self.subTest(
                    message_type=message_type,
                    payload_type=type(payload).__name__,
                ):
                    with self.assertRaisesRegex(
                        ContractValidationError,
                        r"message\.data\.payload",
                    ):
                        validate_peer_message(
                            {"type": message_type, "payload": payload},
                            "message.data",
                        )

    def test_failed_federation_resume_preserves_local_peers_only(self) -> None:
        state = simulate_runtime(
            {
                "initial": {
                    "mode": "external",
                    "phase": "signalingReady",
                    "connectionEpoch": 2,
                    "roomEpoch": 3,
                    "hasSession": True,
                    "hasResume": True,
                    "roomConfirmed": True,
                    "localPeers": 2,
                    "federatedPeers": 3,
                    "federationInterrupted": True,
                },
                "actions": [
                    {
                        "type": "federationResumed",
                        "resumed": False,
                    }
                ],
            }
        )
        self.assertEqual(state["localPeers"], 2)
        self.assertEqual(state["federatedPeers"], 0)
        self.assertTrue(state["renegotiationRequired"])

    def test_full_contract_has_expected_coverage(self) -> None:
        self.assertEqual(
            validate_contract(),
            {
                "operations": 3,
                "runtimeSteps": 33,
                "http": 15,
                "settings": 9,
                "hpb": 31,
                "runtime": 21,
            },
        )


if __name__ == "__main__":
    unittest.main()
