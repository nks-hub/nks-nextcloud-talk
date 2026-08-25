package cryptoidentity

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
)

const TokenEncryptionKeyLength = 32

var ErrTokenDecryption = errors.New("provider token decryption failed")

type EncryptedToken struct {
	Ciphertext []byte
	Nonce      []byte
}

type TokenCipher struct {
	aead cipher.AEAD
}

func NewTokenCipher(key []byte) (*TokenCipher, error) {
	if len(key) != TokenEncryptionKeyLength {
		return nil, fmt.Errorf("token encryption key must contain exactly %d bytes", TokenEncryptionKeyLength)
	}
	block, err := aes.NewCipher(append([]byte(nil), key...))
	if err != nil {
		return nil, errors.New("token encryption key is invalid")
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, errors.New("token encryption cipher could not be initialized")
	}
	return &TokenCipher{aead: aead}, nil
}

func (c *TokenCipher) Encrypt(token, deviceIdentifier string) (EncryptedToken, error) {
	if _, err := TokenHash(token); err != nil {
		return EncryptedToken{}, err
	}
	if _, err := DecodeDeviceIdentifier(deviceIdentifier); err != nil {
		return EncryptedToken{}, err
	}
	nonce := make([]byte, c.aead.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return EncryptedToken{}, errors.New("provider token nonce generation failed")
	}
	ciphertext := c.aead.Seal(nil, nonce, []byte(token), []byte(deviceIdentifier))
	return EncryptedToken{
		Ciphertext: ciphertext,
		Nonce:      nonce,
	}, nil
}

func (c *TokenCipher) Decrypt(encrypted EncryptedToken, deviceIdentifier string) (string, error) {
	if _, err := DecodeDeviceIdentifier(deviceIdentifier); err != nil {
		return "", err
	}
	if len(encrypted.Nonce) != c.aead.NonceSize() || len(encrypted.Ciphertext) <= c.aead.Overhead() {
		return "", ErrTokenDecryption
	}
	plaintext, err := c.aead.Open(nil, encrypted.Nonce, encrypted.Ciphertext, []byte(deviceIdentifier))
	if err != nil {
		return "", ErrTokenDecryption
	}
	token := string(plaintext)
	if _, err := TokenHash(token); err != nil {
		return "", ErrTokenDecryption
	}
	return token, nil
}
