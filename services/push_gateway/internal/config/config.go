package config

import (
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	TokenEncryptionKeyLength = 32
)

var projectIDPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]$`)

type Lookup func(string) (string, bool)

type Config struct {
	ListenAddress      string
	DatabaseURL        string
	TokenEncryptionKey []byte
	FirebaseProjectID  string
	WorkerCount        int
	ClaimSize          int
	QueueMaximumDepth  int
	LeaseDuration      time.Duration
	ProviderTimeout    time.Duration
	ShutdownTimeout    time.Duration
	DedupeRetention    time.Duration
	RateLimitPerMinute int
	RateLimitBurst     int
}

func Load(lookup Lookup) (Config, error) {
	listenAddress, err := required(lookup, "PUSH_GATEWAY_LISTEN_ADDRESS")
	if err != nil {
		return Config{}, err
	}
	if _, _, err := net.SplitHostPort(listenAddress); err != nil {
		return Config{}, errors.New("PUSH_GATEWAY_LISTEN_ADDRESS must include a valid host and port")
	}

	databaseURL, err := required(lookup, "PUSH_GATEWAY_DATABASE_URL")
	if err != nil {
		return Config{}, err
	}
	parsedDatabaseURL, err := url.Parse(databaseURL)
	if err != nil || (parsedDatabaseURL.Scheme != "postgres" && parsedDatabaseURL.Scheme != "postgresql") ||
		parsedDatabaseURL.Host == "" {
		return Config{}, errors.New("PUSH_GATEWAY_DATABASE_URL must be a PostgreSQL URL")
	}

	encodedKey, err := required(lookup, "PUSH_GATEWAY_TOKEN_ENCRYPTION_KEY")
	if err != nil {
		return Config{}, err
	}
	key, err := base64.StdEncoding.Strict().DecodeString(encodedKey)
	if err != nil || len(key) != TokenEncryptionKeyLength ||
		base64.StdEncoding.EncodeToString(key) != encodedKey {
		return Config{}, fmt.Errorf(
			"PUSH_GATEWAY_TOKEN_ENCRYPTION_KEY must be canonical Base64 for exactly %d bytes",
			TokenEncryptionKeyLength,
		)
	}

	projectID, err := required(lookup, "PUSH_GATEWAY_FIREBASE_PROJECT_ID")
	if err != nil {
		return Config{}, err
	}
	if !projectIDPattern.MatchString(projectID) {
		return Config{}, errors.New("PUSH_GATEWAY_FIREBASE_PROJECT_ID is invalid")
	}

	workerCount, err := integer(lookup, "PUSH_GATEWAY_WORKER_COUNT", 4, 1, 64)
	if err != nil {
		return Config{}, err
	}
	claimSize, err := integer(lookup, "PUSH_GATEWAY_CLAIM_SIZE", 32, 1, 500)
	if err != nil {
		return Config{}, err
	}
	queueMaximumDepth, err := integer(lookup, "PUSH_GATEWAY_QUEUE_MAX_DEPTH", 100000, 1, 10000000)
	if err != nil {
		return Config{}, err
	}
	leaseDuration, err := duration(lookup, "PUSH_GATEWAY_LEASE_DURATION", 30*time.Second, 5*time.Second, 10*time.Minute)
	if err != nil {
		return Config{}, err
	}
	providerTimeout, err := duration(lookup, "PUSH_GATEWAY_PROVIDER_TIMEOUT", 10*time.Second, time.Second, leaseDuration)
	if err != nil {
		return Config{}, err
	}
	shutdownTimeout, err := duration(lookup, "PUSH_GATEWAY_SHUTDOWN_TIMEOUT", 20*time.Second, time.Second, 2*time.Minute)
	if err != nil {
		return Config{}, err
	}
	if providerTimeout >= shutdownTimeout || shutdownTimeout >= leaseDuration {
		return Config{}, errors.New(
			"PUSH_GATEWAY_PROVIDER_TIMEOUT must be shorter than PUSH_GATEWAY_SHUTDOWN_TIMEOUT, " +
				"which must be shorter than PUSH_GATEWAY_LEASE_DURATION",
		)
	}
	dedupeRetention, err := duration(lookup, "PUSH_GATEWAY_DEDUPE_RETENTION", 7*24*time.Hour, time.Hour, 90*24*time.Hour)
	if err != nil {
		return Config{}, err
	}
	rateLimitPerMinute, err := integer(lookup, "PUSH_GATEWAY_RATE_LIMIT_PER_MINUTE", 600, 1, 100000)
	if err != nil {
		return Config{}, err
	}
	rateLimitBurst, err := integer(lookup, "PUSH_GATEWAY_RATE_LIMIT_BURST", 100, 1, rateLimitPerMinute)
	if err != nil {
		return Config{}, err
	}

	return Config{
		ListenAddress:      listenAddress,
		DatabaseURL:        databaseURL,
		TokenEncryptionKey: append([]byte(nil), key...),
		FirebaseProjectID:  projectID,
		WorkerCount:        workerCount,
		ClaimSize:          claimSize,
		QueueMaximumDepth:  queueMaximumDepth,
		LeaseDuration:      leaseDuration,
		ProviderTimeout:    providerTimeout,
		ShutdownTimeout:    shutdownTimeout,
		DedupeRetention:    dedupeRetention,
		RateLimitPerMinute: rateLimitPerMinute,
		RateLimitBurst:     rateLimitBurst,
	}, nil
}

func required(lookup Lookup, name string) (string, error) {
	value, found := lookup(name)
	if !found || strings.TrimSpace(value) == "" || strings.TrimSpace(value) != value {
		return "", fmt.Errorf("%s is required", name)
	}
	return value, nil
}

func integer(lookup Lookup, name string, fallback, minimum, maximum int) (int, error) {
	raw, found := lookup(name)
	if !found || raw == "" {
		return fallback, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < minimum || value > maximum {
		return 0, fmt.Errorf("%s must be between %d and %d", name, minimum, maximum)
	}
	return value, nil
}

func duration(lookup Lookup, name string, fallback, minimum, maximum time.Duration) (time.Duration, error) {
	raw, found := lookup(name)
	if !found || raw == "" {
		return fallback, nil
	}
	value, err := time.ParseDuration(raw)
	if err != nil || value < minimum || value > maximum {
		return 0, fmt.Errorf("%s is outside its permitted duration range", name)
	}
	return value, nil
}
