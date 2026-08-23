from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from validate_contract import (
    ContractValidationError,
    decode_canonical_base64,
    ephemeral_crypto_proof,
    scan_for_private_keys,
    validate_contract,
)


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
