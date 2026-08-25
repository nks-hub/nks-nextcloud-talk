package cryptoidentity

import (
	"bytes"
	"crypto/sha512"
	"encoding/base64"
	"errors"
	"testing"
)

func TestTokenCipherRoundTripAndRandomNonce(t *testing.T) {
	t.Parallel()

	cipher, err := NewTokenCipher(bytes.Repeat([]byte{0x42}, TokenEncryptionKeyLength))
	if err != nil {
		t.Fatalf("NewTokenCipher() error = %v", err)
	}
	digest := sha512.Sum512([]byte("device"))
	identifier := base64.StdEncoding.EncodeToString(digest[:])
	first, err := cipher.Encrypt("provider-token", identifier)
	if err != nil {
		t.Fatalf("Encrypt(first) error = %v", err)
	}
	second, err := cipher.Encrypt("provider-token", identifier)
	if err != nil {
		t.Fatalf("Encrypt(second) error = %v", err)
	}
	if bytes.Equal(first.Nonce, second.Nonce) || bytes.Equal(first.Ciphertext, second.Ciphertext) {
		t.Fatal("Encrypt() reused a nonce or ciphertext")
	}
	plaintext, err := cipher.Decrypt(first, identifier)
	if err != nil {
		t.Fatalf("Decrypt() error = %v", err)
	}
	if plaintext != "provider-token" {
		t.Fatalf("Decrypt() = %q, want provider-token", plaintext)
	}
}

func TestTokenCipherBindsDeviceIdentifier(t *testing.T) {
	t.Parallel()

	cipher, err := NewTokenCipher(bytes.Repeat([]byte{0x24}, TokenEncryptionKeyLength))
	if err != nil {
		t.Fatalf("NewTokenCipher() error = %v", err)
	}
	firstDigest := sha512.Sum512([]byte("first"))
	secondDigest := sha512.Sum512([]byte("second"))
	firstID := base64.StdEncoding.EncodeToString(firstDigest[:])
	secondID := base64.StdEncoding.EncodeToString(secondDigest[:])
	encrypted, err := cipher.Encrypt("provider-token", firstID)
	if err != nil {
		t.Fatalf("Encrypt() error = %v", err)
	}
	if _, err := cipher.Decrypt(encrypted, secondID); !errors.Is(err, ErrTokenDecryption) {
		t.Fatalf("Decrypt() error = %v, want ErrTokenDecryption", err)
	}
}

func TestNewTokenCipherRequiresAES256Key(t *testing.T) {
	t.Parallel()

	if _, err := NewTokenCipher(make([]byte, TokenEncryptionKeyLength-1)); err == nil {
		t.Fatal("NewTokenCipher() accepted a non-256-bit key")
	}
}
