package store

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"nks-nextcloud-talk/services/push_gateway/internal/cryptoidentity"
)

type Store struct {
	pool              *pgxpool.Pool
	queueMaximumDepth int
}

func Open(ctx context.Context, databaseURL string, queueMaximumDepth int) (*Store, error) {
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return nil, errors.New("PostgreSQL configuration is invalid")
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, errors.New("PostgreSQL is unavailable")
	}
	if err := Migrate(ctx, pool); err != nil {
		pool.Close()
		return nil, err
	}
	store, err := New(pool, queueMaximumDepth)
	if err != nil {
		pool.Close()
		return nil, err
	}
	return store, nil
}

func New(pool *pgxpool.Pool, queueMaximumDepth int) (*Store, error) {
	if pool == nil || queueMaximumDepth < 1 {
		return nil, ErrInvalidMutation
	}
	return &Store{pool: pool, queueMaximumDepth: queueMaximumDepth}, nil
}

func (s *Store) Close() {
	s.pool.Close()
}

func (s *Store) Ping(ctx context.Context) error {
	return s.pool.Ping(ctx)
}

func (s *Store) Ready(ctx context.Context) error {
	if err := s.pool.Ping(ctx); err != nil {
		return errors.New("PostgreSQL is unavailable")
	}
	current, err := MigrationsCurrent(ctx, s.pool)
	if err != nil || !current {
		return errors.New("PostgreSQL migrations are not current")
	}
	return nil
}

func (s *Store) Register(ctx context.Context, mutation RegistrationMutation) (Registration, error) {
	if err := validateRegistrationMutation(mutation); err != nil {
		return Registration{}, err
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return Registration{}, errors.New("registration transaction could not start")
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if err := acquireAdvisoryLocks(ctx, tx,
		advisoryKey("device", mutation.DeviceIdentifier),
		advisoryKey("token", mutation.TokenHash),
	); err != nil {
		return Registration{}, err
	}

	existing, found, err := registrationByIdentifier(ctx, tx, mutation.DeviceIdentifier, true)
	if err != nil {
		return Registration{}, err
	}
	if found && !bytes.Equal(existing.PublicKeyFingerprint, mutation.PublicKeyFingerprint) {
		return Registration{}, ErrIdentityForbidden
	}

	idempotentActive := found && existing.RevokedAt == nil && existing.TokenHash == mutation.TokenHash
	if !idempotentActive {
		var conflict bool
		if err := tx.QueryRow(ctx, `
			SELECT EXISTS (
				SELECT 1
				FROM registrations
				WHERE token_hash = $1
				  AND device_identifier <> $2
				  AND revoked_at IS NULL
			)`, mutation.TokenHash, mutation.DeviceIdentifier).Scan(&conflict); err != nil {
			return Registration{}, errors.New("registration conflict check failed")
		}
		if conflict && !mutation.RecoveryVerified {
			return Registration{}, ErrTokenConflict
		}
	}

	if !found {
		if _, err := tx.Exec(ctx, `
			INSERT INTO registrations (
				device_identifier, device_signature, public_key_pem, public_key_der,
				public_key_fingerprint, token_hash, encrypted_token, token_nonce, generation
			) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 1)`,
			mutation.DeviceIdentifier,
			mutation.DeviceSignature,
			mutation.PublicKeyPEM,
			mutation.PublicKeyDER,
			mutation.PublicKeyFingerprint,
			mutation.TokenHash,
			mutation.EncryptedToken.Ciphertext,
			mutation.EncryptedToken.Nonce,
		); err != nil {
			return Registration{}, errors.New("registration could not be inserted")
		}
	} else if idempotentActive {
		if _, err := tx.Exec(ctx, `
			UPDATE registrations
			SET device_signature = $2, updated_at = clock_timestamp()
			WHERE device_identifier = $1`,
			mutation.DeviceIdentifier,
			mutation.DeviceSignature,
		); err != nil {
			return Registration{}, errors.New("registration could not be refreshed")
		}
	} else {
		if _, err := tx.Exec(ctx, `
			UPDATE delivery_jobs
			SET status = 'cancelled', lease_id = NULL, lease_until = NULL,
				last_error_class = 'registration_rotated', updated_at = clock_timestamp()
			WHERE device_identifier = $1
			  AND registration_generation = $2
			  AND status IN ('pending', 'leased')`,
			mutation.DeviceIdentifier,
			existing.Generation,
		); err != nil {
			return Registration{}, errors.New("stale registration jobs could not be cancelled")
		}
		if _, err := tx.Exec(ctx, `
			UPDATE registrations
			SET device_signature = $2,
				public_key_pem = $3,
				public_key_der = $4,
				public_key_fingerprint = $5,
				token_hash = $6,
				encrypted_token = $7,
				token_nonce = $8,
				generation = generation + 1,
				revoked_at = NULL,
				updated_at = clock_timestamp()
			WHERE device_identifier = $1`,
			mutation.DeviceIdentifier,
			mutation.DeviceSignature,
			mutation.PublicKeyPEM,
			mutation.PublicKeyDER,
			mutation.PublicKeyFingerprint,
			mutation.TokenHash,
			mutation.EncryptedToken.Ciphertext,
			mutation.EncryptedToken.Nonce,
		); err != nil {
			return Registration{}, errors.New("registration could not be rotated")
		}
	}

	registration, found, err := registrationByIdentifier(ctx, tx, mutation.DeviceIdentifier, false)
	if err != nil || !found {
		return Registration{}, errors.New("registration could not be read after mutation")
	}
	if err := tx.Commit(ctx); err != nil {
		return Registration{}, errors.New("registration transaction could not commit")
	}
	return registration, nil
}

func (s *Store) Unregister(ctx context.Context, deviceIdentifier string, fingerprint []byte) error {
	if _, err := cryptoidentity.DecodeDeviceIdentifier(deviceIdentifier); err != nil || len(fingerprint) != sha256.Size {
		return ErrInvalidMutation
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return errors.New("unregistration transaction could not start")
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := acquireAdvisoryLocks(ctx, tx, advisoryKey("device", deviceIdentifier)); err != nil {
		return err
	}
	registration, found, err := registrationByIdentifier(ctx, tx, deviceIdentifier, true)
	if err != nil {
		return err
	}
	if !found {
		return tx.Commit(ctx)
	}
	if !bytes.Equal(registration.PublicKeyFingerprint, fingerprint) {
		return ErrIdentityForbidden
	}
	if registration.RevokedAt == nil {
		if _, err := tx.Exec(ctx, `
			UPDATE delivery_jobs
			SET status = 'cancelled', lease_id = NULL, lease_until = NULL,
				last_error_class = 'registration_revoked', updated_at = clock_timestamp()
			WHERE device_identifier = $1
			  AND registration_generation = $2
			  AND status IN ('pending', 'leased')`,
			deviceIdentifier,
			registration.Generation,
		); err != nil {
			return errors.New("registration jobs could not be revoked")
		}
		if _, err := tx.Exec(ctx, `
			UPDATE registrations
			SET revoked_at = clock_timestamp(), updated_at = clock_timestamp()
			WHERE device_identifier = $1`, deviceIdentifier); err != nil {
			return errors.New("registration could not be revoked")
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return errors.New("unregistration transaction could not commit")
	}
	return nil
}

func (s *Store) Registrations(ctx context.Context, deviceIdentifiers []string) (map[string]Registration, error) {
	if len(deviceIdentifiers) == 0 {
		return map[string]Registration{}, nil
	}
	rows, err := s.pool.Query(ctx, `
		SELECT device_identifier, device_signature, public_key_pem, public_key_der,
			public_key_fingerprint, token_hash, encrypted_token, token_nonce,
			generation, revoked_at, created_at, updated_at
		FROM registrations
		WHERE device_identifier = ANY($1::text[])
		  AND revoked_at IS NULL`, deviceIdentifiers)
	if err != nil {
		return nil, errors.New("registrations could not be read")
	}
	defer rows.Close()
	registrations := make(map[string]Registration, len(deviceIdentifiers))
	for rows.Next() {
		registration, scanErr := scanRegistration(rows)
		if scanErr != nil {
			return nil, scanErr
		}
		registrations[registration.DeviceIdentifier] = registration
	}
	if rows.Err() != nil {
		return nil, errors.New("registrations could not be read")
	}
	return registrations, nil
}

func validateRegistrationMutation(mutation RegistrationMutation) error {
	if _, err := cryptoidentity.DecodeDeviceIdentifier(mutation.DeviceIdentifier); err != nil ||
		len(mutation.DeviceSignature) != cryptoidentity.SignatureEncodedLength ||
		len(mutation.PublicKeyPEM) < 450 || len(mutation.PublicKeyPEM) > cryptoidentity.PublicKeyMaximumLength ||
		len(mutation.PublicKeyDER) < 256 || len(mutation.PublicKeyDER) > 1024 ||
		len(mutation.PublicKeyFingerprint) != sha256.Size ||
		cryptoidentity.ValidateTokenHash(mutation.TokenHash) != nil ||
		len(mutation.EncryptedToken.Nonce) != 12 ||
		len(mutation.EncryptedToken.Ciphertext) < 17 || len(mutation.EncryptedToken.Ciphertext) > 4112 {
		return ErrInvalidMutation
	}
	return nil
}

type registrationScanner interface {
	Scan(dest ...any) error
}

func registrationByIdentifier(
	ctx context.Context,
	tx pgx.Tx,
	deviceIdentifier string,
	forUpdate bool,
) (Registration, bool, error) {
	query := `
		SELECT device_identifier, device_signature, public_key_pem, public_key_der,
			public_key_fingerprint, token_hash, encrypted_token, token_nonce,
			generation, revoked_at, created_at, updated_at
		FROM registrations
		WHERE device_identifier = $1`
	if forUpdate {
		query += " FOR UPDATE"
	}
	registration, err := scanRegistration(tx.QueryRow(ctx, query, deviceIdentifier))
	if errors.Is(err, pgx.ErrNoRows) {
		return Registration{}, false, nil
	}
	if err != nil {
		return Registration{}, false, errors.New("registration could not be read")
	}
	return registration, true, nil
}

func scanRegistration(scanner registrationScanner) (Registration, error) {
	var registration Registration
	var revokedAt *time.Time
	if err := scanner.Scan(
		&registration.DeviceIdentifier,
		&registration.DeviceSignature,
		&registration.PublicKeyPEM,
		&registration.PublicKeyDER,
		&registration.PublicKeyFingerprint,
		&registration.TokenHash,
		&registration.EncryptedToken.Ciphertext,
		&registration.EncryptedToken.Nonce,
		&registration.Generation,
		&revokedAt,
		&registration.CreatedAt,
		&registration.UpdatedAt,
	); err != nil {
		return Registration{}, err
	}
	registration.RevokedAt = revokedAt
	return registration, nil
}

func acquireAdvisoryLocks(ctx context.Context, tx pgx.Tx, keys ...int64) error {
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	var previous int64
	for index, key := range keys {
		if index > 0 && key == previous {
			continue
		}
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1)", key); err != nil {
			return errors.New("database advisory lock could not be acquired")
		}
		previous = key
	}
	return nil
}

func advisoryKey(namespace, value string) int64 {
	digest := sha256.Sum256([]byte(namespace + "\x00" + value))
	return int64(binary.BigEndian.Uint64(digest[:8]))
}
