package config

import (
	"bytes"
	"encoding/base64"
	"strings"
	"testing"
	"time"
)

func TestLoadRequiresSecretsAndAppliesBoundedDefaults(t *testing.T) {
	t.Parallel()

	values := validEnvironment()
	config, err := Load(mapLookup(values))
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if config.ListenAddress != "127.0.0.1:8080" || config.WorkerCount != 4 ||
		config.ClaimSize != 32 || config.QueueMaximumDepth != 100000 ||
		config.LeaseDuration != 30*time.Second || config.ProviderTimeout != 10*time.Second {
		t.Fatalf("Load() returned unexpected defaults: %+v", config)
	}
	if !bytes.Equal(config.TokenEncryptionKey, bytes.Repeat([]byte{0x42}, TokenEncryptionKeyLength)) {
		t.Fatal("Load() decoded an unexpected token encryption key")
	}
}

func TestLoadRejectsMissingRequiredValuesWithoutLeakingSecrets(t *testing.T) {
	t.Parallel()

	for _, name := range []string{
		"PUSH_GATEWAY_LISTEN_ADDRESS",
		"PUSH_GATEWAY_DATABASE_URL",
		"PUSH_GATEWAY_TOKEN_ENCRYPTION_KEY",
		"PUSH_GATEWAY_FIREBASE_PROJECT_ID",
	} {
		values := validEnvironment()
		delete(values, name)
		if _, err := Load(mapLookup(values)); err == nil || !strings.Contains(err.Error(), name) {
			t.Fatalf("Load() missing %s error = %v", name, err)
		}
	}

	values := validEnvironment()
	secret := "not-a-valid-secret-value"
	values["PUSH_GATEWAY_TOKEN_ENCRYPTION_KEY"] = secret
	_, err := Load(mapLookup(values))
	if err == nil {
		t.Fatal("Load() accepted an invalid encryption key")
	}
	if strings.Contains(err.Error(), secret) {
		t.Fatal("Load() included a secret in its error")
	}
}

func TestLoadRejectsInvalidOriginsAndBounds(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name  string
		key   string
		value string
	}{
		{name: "listen address", key: "PUSH_GATEWAY_LISTEN_ADDRESS", value: "8080"},
		{name: "database scheme", key: "PUSH_GATEWAY_DATABASE_URL", value: "mysql://localhost/gateway"},
		{name: "firebase project", key: "PUSH_GATEWAY_FIREBASE_PROJECT_ID", value: "INVALID"},
		{name: "worker count", key: "PUSH_GATEWAY_WORKER_COUNT", value: "0"},
		{name: "claim size", key: "PUSH_GATEWAY_CLAIM_SIZE", value: "501"},
		{name: "provider timeout", key: "PUSH_GATEWAY_PROVIDER_TIMEOUT", value: "31s"},
		{name: "provider exceeds shutdown", key: "PUSH_GATEWAY_PROVIDER_TIMEOUT", value: "20s"},
		{name: "shutdown reaches lease", key: "PUSH_GATEWAY_SHUTDOWN_TIMEOUT", value: "30s"},
		{name: "rate burst", key: "PUSH_GATEWAY_RATE_LIMIT_BURST", value: "601"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			values := validEnvironment()
			values[test.key] = test.value
			if _, err := Load(mapLookup(values)); err == nil {
				t.Fatalf("Load() accepted %s=%q", test.key, test.value)
			}
		})
	}
}

func validEnvironment() map[string]string {
	return map[string]string{
		"PUSH_GATEWAY_LISTEN_ADDRESS":       "127.0.0.1:8080",
		"PUSH_GATEWAY_DATABASE_URL":         "postgres://gateway:password@localhost/gateway",
		"PUSH_GATEWAY_TOKEN_ENCRYPTION_KEY": base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x42}, TokenEncryptionKeyLength)),
		"PUSH_GATEWAY_FIREBASE_PROJECT_ID":  "nks-talk-test",
	}
}

func mapLookup(values map[string]string) Lookup {
	return func(name string) (string, bool) {
		value, found := values[name]
		return value, found
	}
}
