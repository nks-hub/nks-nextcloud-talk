#!/usr/bin/env python3
"""Probes every pattern in the public repository gate, positively and negatively.

A gate is only worth its output if each of its rules still matches what it was
written for. A rule that matches nothing fails open and says the same thing a
clean tree says. That is not hypothetical: the checkout-path rule below was
committed once in a form that matched none of the paths it was written for, and
only a probe like this one caught it.

Every literal here is invented. The file is on the gate's own exemption list
because, by construction, it contains strings the gate is meant to reject.

    python3 tool/test_public_repo_gate.py
"""
import importlib.util
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "public_repo_gate", os.path.join(ROOT, "tool", "public_repo_gate.py")
)
gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate)

# rule name -> (lines it must flag, lines it must leave alone)
PROBES = {
    "private IPv4": (
        ["ssh root@10.0.2.15", "proxy 192.168.2.9:8082", "172.16.0.1", "172.31.255.254"],
        # RFC 5737 documentation ranges, and the two neighbours of 172.16/12.
        ["203.0.113.5", "198.51.100.7", "192.0.2.1", "172.32.0.1", "11.0.0.1"],
    ),
    "home path": (
        ["/Users/someone/Library", "/home/operator/.ssh", r"C:\Users\someone\AppData"],
        # Hosted CI and the conventional placeholder accounts.
        ["/home/runner/work", "/Users/builder/x", r"C:\Users\runneradmin\x", "/home/user/x"],
    ),
    "sudo -u user": (
        ["sudo -u someone -H bash", "sudo -u www-data php occ"],
        ["sudo -u <user> bash", "sudo apt-get install"],
    ),
    "Apple team id": (
        ["DEVELOPMENT_TEAM = ABCDE12345;"],
        ["DEVELOPMENT_TEAM = $(TEAM_ID);", "DEVELOPMENT_TEAM = ;"],
    ),
    "signing identity": (
        ["Developer ID Application: Some Person (ABCDE12345)"],
        ["Developer ID Application: $IDENTITY", 'Developer ID Application: "$1"'],
    ),
    "local checkout path": (
        [r"C:\work\sources\some-sdk\bin", r"D:\dev\thing\file", r"E:\repos\x\y"],
        # Honest examples: an install script's help and a filename fixture.
        [r"C:\build\Release", r"C:\incoming\report.csv", r"C:\Program Files\Git\bin"],
    ),
    "private tool wrapper": (
        ["rtk proxy python x.py", "  rtk gain", "`rtk analyze`"],
        ["python x.py", "the artkeeper rtkey", "network"],
    ),
    "24-hex id in docs": (
        ["build id 0123456789abcdef01234567"],
        ["sha 0123456789abcdef0123456", "0123456789abcdef012345678"],
    ),
}

RULES = dict(gate.PATTERNS + gate.MARKDOWN_PATTERNS)


class GatePatternTest(unittest.TestCase):
    def test_every_rule_has_a_probe(self) -> None:
        self.assertEqual(
            sorted(RULES),
            sorted(PROBES),
            "a rule was added or removed without a probe beside it",
        )

    def test_rules_catch_what_they_are_for(self) -> None:
        for name, (should_flag, _) in PROBES.items():
            for line in should_flag:
                with self.subTest(rule=name, line=line):
                    self.assertTrue(RULES[name].search(line), "rule fails open")

    def test_rules_leave_honest_lines_alone(self) -> None:
        for name, (_, should_pass) in PROBES.items():
            for line in should_pass:
                with self.subTest(rule=name, line=line):
                    self.assertIsNone(RULES[name].search(line), "rule is noisy")


class GateMailTest(unittest.TestCase):
    def test_fixture_domains_are_allowed(self) -> None:
        for address in (
            "someone@example.invalid",
            "a@test.localhost",
            "1234+x@users.noreply.github.com",
        ):
            with self.subTest(address=address):
                self.assertTrue(gate.ALLOWED_MAIL.search(address))

    def test_a_real_looking_address_is_not(self) -> None:
        self.assertIsNone(gate.ALLOWED_MAIL.search("someone@a-real-company.cz"))


class GateExemptionTest(unittest.TestCase):
    def test_this_file_is_exempt(self) -> None:
        # It has to be: every positive probe above is a string the gate rejects.
        self.assertTrue(
            any("test_public_repo_gate" in entry for entry in gate.EXEMPT),
            "the probe file must be exempt or the gate fails on its own test",
        )


if __name__ == "__main__":
    unittest.main(verbosity=1)
