package identityproof

import "testing"

func TestParseCloudIDMatchesPinnedNextcloudCases(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name       string
		value      string
		wantUser   string
		wantOrigin string
	}{
		{name: "basic", value: "test@example.com", wantUser: "test", wantOrigin: "https://example.com"},
		{name: "subpath", value: "test@example.com/cloud", wantUser: "test", wantOrigin: "https://example.com/cloud"},
		{name: "trailing slash", value: "test@example.com/cloud/", wantUser: "test", wantOrigin: "https://example.com/cloud"},
		{name: "index path", value: "test@example.com/cloud/index.php", wantUser: "test", wantOrigin: "https://example.com/cloud"},
		{name: "at in user", value: "test@example.com@example.com", wantUser: "test@example.com", wantOrigin: "https://example.com"},
		{name: "equals in user", value: "test==@example.com", wantUser: "test==", wantOrigin: "https://example.com"},
		{name: "explicit https", value: "test@https://example.com/nextcloud", wantUser: "test", wantOrigin: "https://example.com/nextcloud"},
		{name: "custom port", value: "test@example.com:8443/cloud", wantUser: "test", wantOrigin: "https://example.com:8443/cloud"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			cloudID, err := ParseCloudID(test.value)
			if err != nil {
				t.Fatalf("ParseCloudID() error = %v", err)
			}
			if cloudID.User != test.wantUser {
				t.Fatalf("ParseCloudID().User = %q, want %q", cloudID.User, test.wantUser)
			}
			if actual := cloudID.Origin.String(); actual != test.wantOrigin {
				t.Fatalf("ParseCloudID().Origin = %q, want %q", actual, test.wantOrigin)
			}
		})
	}
}

func TestParseCloudIDRejectsUnsafeOrAmbiguousValues(t *testing.T) {
	t.Parallel()

	values := []string{
		"example.com",
		"test:foo@example.com",
		"test/foo@example.com",
		"test@http://example.com",
		" test@example.com",
		"test @example.com",
		".@example.com",
		"test@https://user@example.com",
		"test@example.com/cloud?secret=value",
		"test@example.com/cloud#fragment",
		"test@example.com/cloud/%2f/admin",
		"test@example.com/cloud/../admin",
		"test@example.com//cloud",
	}
	for _, value := range values {
		value := value
		t.Run(value, func(t *testing.T) {
			t.Parallel()
			if _, err := ParseCloudID(value); err == nil {
				t.Fatalf("ParseCloudID(%q) unexpectedly succeeded", value)
			}
		})
	}
}

func TestIdentityProofURLPreservesBasePathAndEscapesUser(t *testing.T) {
	t.Parallel()

	cloudID, err := ParseCloudID("demo user@example.com/nextcloud")
	if err != nil {
		t.Fatalf("ParseCloudID() error = %v", err)
	}
	actual := identityProofURL(cloudID).String()
	want := "https://example.com/nextcloud/ocs/v2.php/identityproof/key/demo%20user?format=json"
	if actual != want {
		t.Fatalf("identityProofURL() = %q, want %q", actual, want)
	}
}
