package identityproof

import (
	"context"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"time"

	"nks-nextcloud-talk/services/push_gateway/internal/cryptoidentity"
	"nks-nextcloud-talk/services/push_gateway/internal/strictjson"
)

const (
	defaultConnectTimeout  = 3 * time.Second
	defaultRequestTimeout  = 6 * time.Second
	defaultResponseMaximum = int64(64 * 1024)
)

var (
	ErrIdentityProofFailed   = errors.New("public identity proof failed")
	ErrIdentityProofMismatch = errors.New("public identity proof key does not match")
	ErrIdentityProofRedirect = errors.New("public identity proof redirect is forbidden")
	ErrIdentityProofResponse = errors.New("public identity proof response is invalid")
)

type Resolver interface {
	LookupNetIP(context.Context, string, string) ([]netip.Addr, error)
}

type Dialer interface {
	DialContext(context.Context, string, string) (net.Conn, error)
}

type VerifierConfig struct {
	Resolver        Resolver
	Dialer          Dialer
	RootCAs         *x509.CertPool
	ConnectTimeout  time.Duration
	RequestTimeout  time.Duration
	ResponseMaximum int64
	UserAgent       string
}

type Verifier struct {
	resolver        Resolver
	dialer          Dialer
	rootCAs         *x509.CertPool
	connectTimeout  time.Duration
	requestTimeout  time.Duration
	responseMaximum int64
	userAgent       string
}

func NewVerifier(config VerifierConfig) (*Verifier, error) {
	resolver := config.Resolver
	if resolver == nil {
		resolver = net.DefaultResolver
	}
	connectTimeout := config.ConnectTimeout
	if connectTimeout == 0 {
		connectTimeout = defaultConnectTimeout
	}
	requestTimeout := config.RequestTimeout
	if requestTimeout == 0 {
		requestTimeout = defaultRequestTimeout
	}
	responseMaximum := config.ResponseMaximum
	if responseMaximum == 0 {
		responseMaximum = defaultResponseMaximum
	}
	if connectTimeout < 100*time.Millisecond || requestTimeout < connectTimeout ||
		responseMaximum < 1024 || responseMaximum > 1024*1024 {
		return nil, errors.New("identity proof verifier limits are invalid")
	}
	dialer := config.Dialer
	if dialer == nil {
		dialer = &net.Dialer{Timeout: connectTimeout, KeepAlive: -1}
	}
	userAgent := strings.TrimSpace(config.UserAgent)
	if userAgent == "" {
		userAgent = "NKS-Nextcloud-Talk-Push-Gateway"
	}
	return &Verifier{
		resolver:        resolver,
		dialer:          dialer,
		rootCAs:         config.RootCAs,
		connectTimeout:  connectTimeout,
		requestTimeout:  requestTimeout,
		responseMaximum: responseMaximum,
		userAgent:       userAgent,
	}, nil
}

func (v *Verifier) Verify(ctx context.Context, cloudIDValue string, expected cryptoidentity.PublicIdentity) error {
	cloudID, err := ParseCloudID(cloudIDValue)
	if err != nil {
		return err
	}
	host := cloudID.Origin.Hostname()
	if _, err := v.resolvePublic(ctx, host); err != nil {
		return err
	}

	proofURL := identityProofURL(cloudID)
	requestContext, cancel := context.WithTimeout(ctx, v.requestTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(requestContext, http.MethodGet, proofURL.String(), nil)
	if err != nil {
		return ErrIdentityProofFailed
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", v.userAgent)

	client, transport := v.clientFor(host)
	defer transport.CloseIdleConnections()
	response, err := client.Do(request)
	if err != nil {
		if errors.Is(err, ErrNonPublicAddress) {
			return ErrNonPublicAddress
		}
		return ErrIdentityProofFailed
	}
	defer response.Body.Close()
	if response.StatusCode >= 300 && response.StatusCode < 400 {
		return ErrIdentityProofRedirect
	}
	if response.StatusCode != http.StatusOK {
		return ErrIdentityProofResponse
	}
	mediaType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || (mediaType != "application/json" && mediaType != "application/ocs+json") {
		return ErrIdentityProofResponse
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, v.responseMaximum+1))
	if err != nil || int64(len(body)) > v.responseMaximum {
		return ErrIdentityProofResponse
	}
	if err := strictjson.Validate(body, 8); err != nil {
		return ErrIdentityProofResponse
	}
	actual, err := decodeIdentityProof(body)
	if err != nil {
		return err
	}
	if subtle.ConstantTimeCompare(actual.DER, expected.DER) != 1 {
		return ErrIdentityProofMismatch
	}
	return nil
}

func (v *Verifier) clientFor(expectedHost string) (*http.Client, *http.Transport) {
	transport := &http.Transport{
		Proxy:                 nil,
		DisableKeepAlives:     true,
		ForceAttemptHTTP2:     true,
		TLSHandshakeTimeout:   v.connectTimeout,
		ResponseHeaderTimeout: v.requestTimeout,
		TLSClientConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
			RootCAs:    v.rootCAs,
			ServerName: expectedHost,
		},
	}
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(address)
		if err != nil || !strings.EqualFold(strings.TrimSuffix(host, "."), expectedHost) {
			return nil, ErrIdentityProofFailed
		}
		addresses, err := v.resolvePublic(ctx, expectedHost)
		if err != nil {
			return nil, err
		}
		for _, candidate := range addresses {
			if err := ValidatePublicAddress(candidate); err != nil {
				return nil, err
			}
			connection, dialErr := v.dialer.DialContext(ctx, network, net.JoinHostPort(candidate.String(), port))
			if dialErr == nil {
				return connection, nil
			}
		}
		return nil, ErrIdentityProofFailed
	}
	return &http.Client{
		Transport: transport,
		Timeout:   v.requestTimeout,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}, transport
}

func (v *Verifier) resolvePublic(ctx context.Context, host string) ([]netip.Addr, error) {
	if address, err := netip.ParseAddr(host); err == nil {
		if err := ValidatePublicAddress(address); err != nil {
			return nil, err
		}
		return []netip.Addr{address}, nil
	}
	addresses, err := v.resolver.LookupNetIP(ctx, "ip", host)
	if err != nil || len(addresses) == 0 {
		return nil, ErrIdentityProofFailed
	}
	for _, address := range addresses {
		if err := ValidatePublicAddress(address); err != nil {
			return nil, err
		}
	}
	return addresses, nil
}

func identityProofURL(cloudID CloudID) *url.URL {
	result := *cloudID.Origin
	basePath := strings.TrimSuffix(cloudID.Origin.Path, "/")
	result.Path = basePath + "/ocs/v2.php/identityproof/key/" + cloudID.User
	result.RawPath = strings.TrimSuffix(cloudID.Origin.EscapedPath(), "/") +
		"/ocs/v2.php/identityproof/key/" + url.PathEscape(cloudID.User)
	result.RawQuery = "format=json"
	return &result
}

func decodeIdentityProof(body []byte) (cryptoidentity.PublicIdentity, error) {
	var response struct {
		OCS struct {
			Meta struct {
				StatusCode int `json:"statuscode"`
			} `json:"meta"`
			Data struct {
				Public string `json:"public"`
			} `json:"data"`
		} `json:"ocs"`
	}
	if err := json.Unmarshal(body, &response); err != nil ||
		response.OCS.Meta.StatusCode != http.StatusOK || response.OCS.Data.Public == "" {
		return cryptoidentity.PublicIdentity{}, ErrIdentityProofResponse
	}
	identity, err := cryptoidentity.ParsePublicIdentity(response.OCS.Data.Public)
	if err != nil {
		return cryptoidentity.PublicIdentity{}, fmt.Errorf("%w", ErrIdentityProofResponse)
	}
	return identity, nil
}
