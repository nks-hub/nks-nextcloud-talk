package identityproof

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"sync"
	"testing"

	"nks-nextcloud-talk/services/push_gateway/internal/cryptoidentity"
)

var publicTestAddress = netip.MustParseAddr("93.184.216.34")

func TestVerifierFetchesBoundedPublicIdentityProof(t *testing.T) {
	t.Parallel()

	identity := generateIdentity(t)
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.EscapedPath() != "/nextcloud/ocs/v2.php/identityproof/key/demo@example.com" {
			t.Errorf("request path = %q", request.URL.EscapedPath())
		}
		if request.URL.Query().Get("format") != "json" {
			t.Errorf("request format = %q", request.URL.Query().Get("format"))
		}
		if request.Header.Get("Authorization") != "" || request.Header.Get("Cookie") != "" {
			t.Error("identity proof request forwarded credentials")
		}
		writer.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(writer).Encode(map[string]any{
			"ocs": map[string]any{
				"meta": map[string]any{"statuscode": http.StatusOK},
				"data": map[string]any{"public": identity.CanonicalPEM},
			},
		})
	}))
	defer server.Close()

	serverName := server.Certificate().DNSNames[0]
	rootCAs := x509.NewCertPool()
	rootCAs.AddCert(server.Certificate())
	verifier, err := NewVerifier(VerifierConfig{
		Resolver: &sequenceResolver{answers: [][]netip.Addr{{publicTestAddress}, {publicTestAddress}}},
		Dialer:   rewriteDialer{address: server.Listener.Addr().String()},
		RootCAs:  rootCAs,
	})
	if err != nil {
		t.Fatalf("NewVerifier() error = %v", err)
	}
	cloudID := "demo@example.com@https://" + serverName + "/nextcloud"
	if err := verifier.Verify(context.Background(), cloudID, identity); err != nil {
		t.Fatalf("Verify() error = %v", err)
	}
}

func TestVerifierRejectsPrivatePreflightAndDNSRebinding(t *testing.T) {
	t.Parallel()

	identity := generateIdentity(t)
	for _, test := range []struct {
		name    string
		answers [][]netip.Addr
	}{
		{name: "private preflight", answers: [][]netip.Addr{{netip.MustParseAddr("127.0.0.1")}}},
		{name: "private second lookup", answers: [][]netip.Addr{{publicTestAddress}, {netip.MustParseAddr("10.0.0.1")}}},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			verifier, err := NewVerifier(VerifierConfig{
				Resolver: &sequenceResolver{answers: test.answers},
				Dialer:   failingDialer{},
			})
			if err != nil {
				t.Fatalf("NewVerifier() error = %v", err)
			}
			if err := verifier.Verify(context.Background(), "demo@example.com", identity); !errors.Is(err, ErrNonPublicAddress) {
				t.Fatalf("Verify() error = %v, want ErrNonPublicAddress", err)
			}
		})
	}
}

func TestVerifierDoesNotFollowRedirect(t *testing.T) {
	t.Parallel()

	identity := generateIdentity(t)
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		http.Redirect(writer, &http.Request{}, "https://redirect.example.invalid/", http.StatusFound)
	}))
	defer server.Close()
	serverName := server.Certificate().DNSNames[0]
	rootCAs := x509.NewCertPool()
	rootCAs.AddCert(server.Certificate())
	verifier, err := NewVerifier(VerifierConfig{
		Resolver: &sequenceResolver{answers: [][]netip.Addr{{publicTestAddress}, {publicTestAddress}}},
		Dialer:   rewriteDialer{address: server.Listener.Addr().String()},
		RootCAs:  rootCAs,
	})
	if err != nil {
		t.Fatalf("NewVerifier() error = %v", err)
	}
	if err := verifier.Verify(context.Background(), "demo@"+serverName, identity); !errors.Is(err, ErrIdentityProofRedirect) {
		t.Fatalf("Verify() error = %v, want ErrIdentityProofRedirect", err)
	}
}

type sequenceResolver struct {
	mu      sync.Mutex
	answers [][]netip.Addr
	calls   int
}

func (r *sequenceResolver) LookupNetIP(_ context.Context, _, _ string) ([]netip.Addr, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.answers) == 0 {
		return nil, errors.New("no DNS answer configured")
	}
	index := r.calls
	if index >= len(r.answers) {
		index = len(r.answers) - 1
	}
	r.calls++
	return append([]netip.Addr(nil), r.answers[index]...), nil
}

type rewriteDialer struct {
	address string
}

func (d rewriteDialer) DialContext(ctx context.Context, network, _ string) (net.Conn, error) {
	return (&net.Dialer{}).DialContext(ctx, network, d.address)
}

type failingDialer struct{}

func (failingDialer) DialContext(context.Context, string, string) (net.Conn, error) {
	return nil, errors.New("dial should not succeed")
}

func generateIdentity(t *testing.T) cryptoidentity.PublicIdentity {
	t.Helper()
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("GenerateKey() error = %v", err)
	}
	der, err := x509.MarshalPKIXPublicKey(&privateKey.PublicKey)
	if err != nil {
		t.Fatalf("MarshalPKIXPublicKey() error = %v", err)
	}
	identity, err := cryptoidentity.ParsePublicIdentity(string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})))
	if err != nil {
		t.Fatalf("ParsePublicIdentity() error = %v", err)
	}
	return identity
}
