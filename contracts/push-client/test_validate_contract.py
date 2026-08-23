from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


CONTRACT_ROOT = Path(__file__).resolve().parent
MODULE_PATH = CONTRACT_ROOT / "validate_contract.py"
MODULE_SPEC = importlib.util.spec_from_file_location(
    "push_client_validate_contract",
    MODULE_PATH,
)
if MODULE_SPEC is None or MODULE_SPEC.loader is None:
    raise RuntimeError("Unable to load the push-client contract validator")
push_contract = importlib.util.module_from_spec(MODULE_SPEC)
sys.modules[MODULE_SPEC.name] = push_contract
MODULE_SPEC.loader.exec_module(push_contract)

ContractValidationError = push_contract.ContractValidationError
decode_canonical_base64 = push_contract.decode_canonical_base64
ephemeral_crypto_proof = push_contract.ephemeral_crypto_proof
scan_for_private_keys = push_contract.scan_for_private_keys
validate_contract = push_contract.validate_contract


class PushClientContractValidatorTest(unittest.TestCase):
    def test_noncanonical_base64_is_rejected(self) -> None:
        with self.assertRaisesRegex(ContractValidationError, "canonical Base64"):
            decode_canonical_base64("YQ==\n", "subject")

    def test_ephemeral_crypto_executes_both_padding_variants(self) -> None:
        self.assertEqual(
            ephemeral_crypto_proof(),
            {
                "decryptions": 2,
                "negativeChecks": 4,
                "schemaValidations": 2,
                "signatures": 2,
                "variants": 2,
            },
        )

    def test_all_supported_private_key_headers_are_rejected(self) -> None:
        for label in (
            "PRIVATE KEY",
            "ENCRYPTED PRIVATE KEY",
            "RSA PRIVATE KEY",
            "DSA PRIVATE KEY",
            "EC PRIVATE KEY",
            "OPENSSH PRIVATE KEY",
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "material.pem"
                path.write_text(
                    "-----BEGIN " + label + "-----\nsynthetic\n",
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(
                    ContractValidationError,
                    "Private key is forbidden",
                ):
                    scan_for_private_keys(Path(directory))

    def test_full_contract_has_expected_coverage(self) -> None:
        result = validate_contract()
        self.assertEqual(result["openapiDocuments"], 1)
        self.assertEqual(result["fixtures"], 8)
        self.assertEqual(result["validFixtures"], 7)
        self.assertEqual(result["identityChecks"], 1)
        self.assertEqual(result["cryptoVariants"], 2)
        self.assertEqual(result["ephemeralSignatures"], 2)
        self.assertEqual(result["ephemeralDecryptions"], 2)
        self.assertEqual(result["ephemeralSchemaValidations"], 2)
        self.assertEqual(result["cryptoNegativeChecks"], 4)
        self.assertGreaterEqual(result["scannedFiles"], 12)


if __name__ == "__main__":
    unittest.main()
