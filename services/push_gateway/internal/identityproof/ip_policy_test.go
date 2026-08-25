package identityproof

import (
	"net/netip"
	"testing"
)

func TestValidatePublicAddress(t *testing.T) {
	t.Parallel()

	for _, value := range []string{
		"8.8.8.8",
		"1.1.1.1",
		"2606:4700:4700::1111",
	} {
		if err := ValidatePublicAddress(netip.MustParseAddr(value)); err != nil {
			t.Fatalf("ValidatePublicAddress(%s) error = %v", value, err)
		}
	}
}

func TestValidatePublicAddressRejectsSpecialRanges(t *testing.T) {
	t.Parallel()

	for _, value := range []string{
		"0.0.0.1",
		"10.0.0.1",
		"100.64.0.1",
		"127.0.0.1",
		"169.254.1.1",
		"172.16.0.1",
		"192.0.0.1",
		"192.0.2.1",
		"192.168.0.1",
		"198.18.0.1",
		"198.51.100.1",
		"203.0.113.1",
		"224.0.0.1",
		"240.0.0.1",
		"::",
		"::1",
		"::ffff:127.0.0.1",
		"64:ff9b::7f00:1",
		"100::1",
		"2001::1",
		"2001:db8::1",
		"2002::1",
		"fc00::1",
		"fe80::1",
		"ff00::1",
	} {
		if err := ValidatePublicAddress(netip.MustParseAddr(value)); err == nil {
			t.Fatalf("ValidatePublicAddress(%s) unexpectedly succeeded", value)
		}
	}
}
