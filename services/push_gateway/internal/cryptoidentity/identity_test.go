package cryptoidentity

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha512"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"testing"
)

func TestVerifyDeviceAndNotificationIdentity(t *testing.T) {
	t.Parallel()

	privateKey := generatePrivateKey(t, 2048)
	identity := parsePrivatePublicIdentity(t, privateKey)
	preimageDigest := sha512.Sum512([]byte(`["demo@example.invalid",1]`))
	deviceSignature, err := rsa.SignPKCS1v15(rand.Reader, privateKey, crypto.SHA512, preimageDigest[:])
	if err != nil {
		t.Fatalf("SignPKCS1v15(device) error = %v", err)
	}
	identifier := base64.StdEncoding.EncodeToString(preimageDigest[:])
	if err := VerifyDeviceIdentity(identifier, base64.StdEncoding.EncodeToString(deviceSignature), identity); err != nil {
		t.Fatalf("VerifyDeviceIdentity() error = %v", err)
	}

	subject := make([]byte, privateKey.Size())
	if _, err := rand.Read(subject); err != nil {
		t.Fatalf("rand.Read() error = %v", err)
	}
	subjectDigest := sha512.Sum512(subject)
	notificationSignature, err := rsa.SignPKCS1v15(rand.Reader, privateKey, crypto.SHA512, subjectDigest[:])
	if err != nil {
		t.Fatalf("SignPKCS1v15(notification) error = %v", err)
	}
	if err := VerifyNotification(
		base64.StdEncoding.EncodeToString(subject),
		base64.StdEncoding.EncodeToString(notificationSignature),
		identity,
	); err != nil {
		t.Fatalf("VerifyNotification() error = %v", err)
	}
}

func TestVerifyDeviceIdentityRejectsDoubleHashAndNonCanonicalBase64(t *testing.T) {
	t.Parallel()

	privateKey := generatePrivateKey(t, 2048)
	identity := parsePrivatePublicIdentity(t, privateKey)
	digest := sha512.Sum512([]byte("device preimage"))
	doubleDigest := sha512.Sum512(digest[:])
	signature, err := rsa.SignPKCS1v15(rand.Reader, privateKey, crypto.SHA512, doubleDigest[:])
	if err != nil {
		t.Fatalf("SignPKCS1v15() error = %v", err)
	}
	if err := VerifyDeviceIdentity(
		base64.StdEncoding.EncodeToString(digest[:]),
		base64.StdEncoding.EncodeToString(signature),
		identity,
	); !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("VerifyDeviceIdentity() error = %v, want ErrInvalidSignature", err)
	}

	validSignature, err := rsa.SignPKCS1v15(rand.Reader, privateKey, crypto.SHA512, digest[:])
	if err != nil {
		t.Fatalf("SignPKCS1v15() error = %v", err)
	}
	if err := VerifyDeviceIdentity(
		base64.StdEncoding.EncodeToString(digest[:])+"\n",
		base64.StdEncoding.EncodeToString(validSignature),
		identity,
	); !errors.Is(err, ErrInvalidIdentifier) {
		t.Fatalf("VerifyDeviceIdentity() error = %v, want ErrInvalidIdentifier", err)
	}
}

func TestParsePublicIdentityRequiresRSA2048SPKI(t *testing.T) {
	t.Parallel()

	privateKey := generatePrivateKey(t, 1024)
	der, err := x509.MarshalPKIXPublicKey(&privateKey.PublicKey)
	if err != nil {
		t.Fatalf("MarshalPKIXPublicKey() error = %v", err)
	}
	value := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})
	if _, err := ParsePublicIdentity(string(value)); !errors.Is(err, ErrInvalidPublicKey) {
		t.Fatalf("ParsePublicIdentity() error = %v, want ErrInvalidPublicKey", err)
	}
}

func TestTokenHashIsCanonicalSHA512(t *testing.T) {
	t.Parallel()

	hash, err := TokenHash("provider-token")
	if err != nil {
		t.Fatalf("TokenHash() error = %v", err)
	}
	if len(hash) != 128 {
		t.Fatalf("TokenHash() length = %d, want 128", len(hash))
	}
	if err := ValidateTokenHash(hash); err != nil {
		t.Fatalf("ValidateTokenHash() error = %v", err)
	}
	if err := ValidateTokenHash("A" + hash[1:]); !errors.Is(err, ErrInvalidTokenHash) {
		t.Fatalf("ValidateTokenHash() error = %v, want ErrInvalidTokenHash", err)
	}
}

func generatePrivateKey(t *testing.T, bits int) *rsa.PrivateKey {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, bits)
	if err != nil {
		t.Fatalf("GenerateKey(%d) error = %v", bits, err)
	}
	return key
}

func parsePrivatePublicIdentity(t *testing.T, privateKey *rsa.PrivateKey) PublicIdentity {
	t.Helper()
	der, err := x509.MarshalPKIXPublicKey(&privateKey.PublicKey)
	if err != nil {
		t.Fatalf("MarshalPKIXPublicKey() error = %v", err)
	}
	value := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})
	identity, err := ParsePublicIdentity(string(value))
	if err != nil {
		t.Fatalf("ParsePublicIdentity() error = %v", err)
	}
	return identity
}
