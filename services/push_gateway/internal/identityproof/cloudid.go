package identityproof

import (
	"errors"
	"net"
	"net/netip"
	"net/url"
	"path"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"golang.org/x/net/idna"
)

var (
	ErrInvalidCloudID = errors.New("cloud ID is invalid")
	validUserPattern  = regexp.MustCompile(`^[a-zA-Z0-9 _.@\-'=]+$`)
)

type CloudID struct {
	User   string
	Origin *url.URL
}

func ParseCloudID(value string) (CloudID, error) {
	if len(value) < 3 || len(value) > 255 || !utf8.ValidString(value) || containsControl(value) {
		return CloudID{}, ErrInvalidCloudID
	}

	cleaned := strings.ReplaceAll(value, `\`, "/")
	if index := strings.Index(cleaned, "/index.php"); index > 0 {
		cleaned = cleaned[:index]
	}
	cleaned = strings.TrimRight(cleaned, "/")

	invalidPosition := len(cleaned)
	if index := strings.IndexAny(cleaned, "/:"); index >= 0 {
		invalidPosition = index
	}
	separator := strings.LastIndex(cleaned[:invalidPosition], "@")
	if separator <= 0 || separator == len(cleaned)-1 {
		return CloudID{}, ErrInvalidCloudID
	}
	user := cleaned[:separator]
	remote := cleaned[separator+1:]
	if !validUserPattern.MatchString(user) || strings.TrimSpace(user) != user ||
		user == "." || user == ".." || len(user+"@"+remote) > 255 {
		return CloudID{}, ErrInvalidCloudID
	}

	origin, err := parsePublicHTTPSOrigin(remote)
	if err != nil {
		return CloudID{}, err
	}
	return CloudID{User: user, Origin: origin}, nil
}

func parsePublicHTTPSOrigin(remote string) (*url.URL, error) {
	if !strings.Contains(remote, "://") {
		remote = "https://" + remote
	}
	parsed, err := url.Parse(remote)
	if err != nil || parsed.Scheme != "https" || parsed.Opaque != "" ||
		parsed.User != nil || parsed.Host == "" || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, ErrInvalidCloudID
	}
	if parsed.Port() != "" {
		port, portErr := strconv.ParseUint(parsed.Port(), 10, 16)
		if portErr != nil || port == 0 {
			return nil, ErrInvalidCloudID
		}
	}

	host := strings.TrimSuffix(parsed.Hostname(), ".")
	if host == "" {
		return nil, ErrInvalidCloudID
	}
	if address, addressErr := netip.ParseAddr(host); addressErr == nil {
		host = address.String()
	} else {
		host, err = idna.Lookup.ToASCII(host)
		if err != nil || host == "" || len(host) > 253 {
			return nil, ErrInvalidCloudID
		}
		host = strings.ToLower(host)
	}

	decodedPath := parsed.Path
	escapedPath := strings.ToLower(parsed.EscapedPath())
	if strings.Contains(escapedPath, "%2f") || strings.Contains(escapedPath, "%5c") ||
		strings.Contains(decodedPath, "//") || strings.Contains(decodedPath, `\`) {
		return nil, ErrInvalidCloudID
	}
	for _, segment := range strings.Split(decodedPath, "/") {
		if segment == "." || segment == ".." {
			return nil, ErrInvalidCloudID
		}
	}
	cleanPath := strings.TrimRight(decodedPath, "/")
	if cleanPath != "" && path.Clean(cleanPath) != cleanPath {
		return nil, ErrInvalidCloudID
	}

	canonicalHost := host
	if strings.Contains(host, ":") {
		canonicalHost = "[" + host + "]"
	}
	if parsed.Port() != "" {
		canonicalHost = net.JoinHostPort(host, parsed.Port())
	}
	return &url.URL{
		Scheme: "https",
		Host:   canonicalHost,
		Path:   cleanPath,
	}, nil
}

func containsControl(value string) bool {
	for _, character := range value {
		if character < 0x20 || character == 0x7f {
			return true
		}
	}
	return false
}
