package cryptoidentity

import (
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"strings"
)

const (
	DeviceIdentifierEncodedLength = 88
	SignatureEncodedLength        = 344
	EncryptedSubjectEncodedLength = 344
	PublicKeyMaximumLength        = 8192
	PushTokenMaximumLength        = 4096
)

var (
	ErrInvalidBase64     = errors.New("value is not canonical base64")
	ErrInvalidPublicKey  = errors.New("public key is not a canonical RSA-2048 SPKI key")
	ErrInvalidSignature  = errors.New("RSA/SHA-512 signature verification failed")
	ErrInvalidToken      = errors.New("provider token is invalid")
	ErrInvalidTokenHash  = errors.New("provider token hash is invalid")
	ErrInvalidCiphertext = errors.New("encrypted subject is invalid")
	ErrInvalidIdentifier = errors.New("device identifier is invalid")
)

type PublicIdentity struct {
	Key          *rsa.PublicKey
	CanonicalPEM string
	DER          []byte
	Fingerprint  [sha256.Size]byte
}

func ParsePublicIdentity(value string) (PublicIdentity, error) {
	if len(value) < 1 || len(value) > PublicKeyMaximumLength {
		return PublicIdentity{}, ErrInvalidPublicKey
	}
	block, remainder := pem.Decode([]byte(value))
	if block == nil || block.Type != "PUBLIC KEY" || len(block.Headers) != 0 ||
		len(strings.TrimSpace(string(remainder))) != 0 {
		return PublicIdentity{}, ErrInvalidPublicKey
	}
	parsed, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return PublicIdentity{}, ErrInvalidPublicKey
	}
	key, ok := parsed.(*rsa.PublicKey)
	if !ok || key.Size() != 256 || key.N.BitLen() != 2048 {
		return PublicIdentity{}, ErrInvalidPublicKey
	}
	der, err := x509.MarshalPKIXPublicKey(key)
	if err != nil {
		return PublicIdentity{}, ErrInvalidPublicKey
	}
	canonical := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})
	return PublicIdentity{
		Key:          key,
		CanonicalPEM: string(canonical),
		DER:          append([]byte(nil), der...),
		Fingerprint:  sha256.Sum256(der),
	}, nil
}

func VerifyDeviceIdentity(identifier, signature string, identity PublicIdentity) error {
	digest, err := decodeCanonicalBase64(identifier, DeviceIdentifierEncodedLength, sha512.Size)
	if err != nil {
		return fmt.Errorf("%w: %w", ErrInvalidIdentifier, err)
	}
	signatureBytes, err := decodeCanonicalBase64(signature, SignatureEncodedLength, identity.Key.Size())
	if err != nil {
		return fmt.Errorf("%w: %w", ErrInvalidSignature, err)
	}
	if err := rsa.VerifyPKCS1v15(identity.Key, crypto.SHA512, digest, signatureBytes); err != nil {
		return ErrInvalidSignature
	}
	return nil
}

func VerifyNotification(subject, signature string, identity PublicIdentity) error {
	ciphertext, err := decodeCanonicalBase64(subject, EncryptedSubjectEncodedLength, identity.Key.Size())
	if err != nil {
		return fmt.Errorf("%w: %w", ErrInvalidCiphertext, err)
	}
	signatureBytes, err := decodeCanonicalBase64(signature, SignatureEncodedLength, identity.Key.Size())
	if err != nil {
		return fmt.Errorf("%w: %w", ErrInvalidSignature, err)
	}
	digest := sha512.Sum512(ciphertext)
	if err := rsa.VerifyPKCS1v15(identity.Key, crypto.SHA512, digest[:], signatureBytes); err != nil {
		return ErrInvalidSignature
	}
	return nil
}

func TokenHash(token string) (string, error) {
	if len(token) < 1 || len(token) > PushTokenMaximumLength || strings.TrimSpace(token) != token {
		return "", ErrInvalidToken
	}
	digest := sha512.Sum512([]byte(token))
	return hex.EncodeToString(digest[:]), nil
}

func ValidateTokenHash(value string) error {
	if len(value) != sha512.Size*2 || strings.ToLower(value) != value {
		return ErrInvalidTokenHash
	}
	decoded, err := hex.DecodeString(value)
	if err != nil || len(decoded) != sha512.Size {
		return ErrInvalidTokenHash
	}
	return nil
}

func DecodeDeviceIdentifier(value string) ([]byte, error) {
	decoded, err := decodeCanonicalBase64(value, DeviceIdentifierEncodedLength, sha512.Size)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrInvalidIdentifier, err)
	}
	return decoded, nil
}

func decodeCanonicalBase64(value string, encodedLength, decodedLength int) ([]byte, error) {
	if len(value) != encodedLength || strings.TrimSpace(value) != value {
		return nil, ErrInvalidBase64
	}
	decoded, err := base64.StdEncoding.Strict().DecodeString(value)
	if err != nil || len(decoded) != decodedLength {
		return nil, ErrInvalidBase64
	}
	if base64.StdEncoding.EncodeToString(decoded) != value {
		return nil, ErrInvalidBase64
	}
	return decoded, nil
}
