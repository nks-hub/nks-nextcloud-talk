from __future__ import annotations

import unittest

from validate_contract import (
    ContractValidationError,
    decode_json_bytes,
    normalize_hpb_endpoint,
    normalize_nextcloud_server,
    simulate_runtime,
    validate_contract,
    validate_hpb_case,
    validate_settings_case,
)


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
                "hpb": 28,
                "runtime": 21,
            },
        )


if __name__ == "__main__":
    unittest.main()
