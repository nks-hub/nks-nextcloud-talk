package store

import (
	"errors"
	"time"

	"nks-nextcloud-talk/services/push_gateway/internal/cryptoidentity"
)

var (
	ErrIdentityForbidden   = errors.New("registration identity is forbidden")
	ErrTokenConflict       = errors.New("provider token belongs to another identity")
	ErrQueueFull           = errors.New("delivery queue is full")
	ErrRegistrationChanged = errors.New("registration changed before durable enqueue")
	ErrLeaseLost           = errors.New("delivery job lease is no longer owned")
	ErrInvalidMutation     = errors.New("store mutation is invalid")
)

type RegistrationMutation struct {
	DeviceIdentifier     string
	DeviceSignature      string
	PublicKeyPEM         string
	PublicKeyDER         []byte
	PublicKeyFingerprint []byte
	TokenHash            string
	EncryptedToken       cryptoidentity.EncryptedToken
	RecoveryVerified     bool
}

type Registration struct {
	DeviceIdentifier     string
	DeviceSignature      string
	PublicKeyPEM         string
	PublicKeyDER         []byte
	PublicKeyFingerprint []byte
	TokenHash            string
	EncryptedToken       cryptoidentity.EncryptedToken
	Generation           int64
	RevokedAt            *time.Time
	CreatedAt            time.Time
	UpdatedAt            time.Time
}

type Notification struct {
	DeviceIdentifier       string
	RegistrationGeneration int64
	EnvelopeDigest         [32]byte
	Subject                string
	Signature              string
	Priority               string
	Type                   string
}

type EnqueueOutcome struct {
	Accepted            bool
	Duplicate           bool
	RegistrationChanged bool
}

type ClaimedJob struct {
	ID                     int64
	LeaseID                string
	DeviceIdentifier       string
	RegistrationGeneration int64
	Subject                string
	Signature              string
	Priority               string
	Type                   string
	Attempt                int
	EncryptedToken         cryptoidentity.EncryptedToken
}

type RetryResult struct {
	Exhausted bool
}

type QueueStats struct {
	Pending          int64
	Leased           int64
	Delivered        int64
	PermanentFailure int64
	Cancelled        int64
}
