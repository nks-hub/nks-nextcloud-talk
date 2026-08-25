package store

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"regexp"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

var errorClassPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)

func (s *Store) Enqueue(ctx context.Context, notifications []Notification) ([]EnqueueOutcome, error) {
	outcomes := make([]EnqueueOutcome, len(notifications))
	if len(notifications) == 0 {
		return outcomes, nil
	}
	for _, notification := range notifications {
		if err := validateNotification(notification); err != nil {
			return nil, err
		}
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, errors.New("enqueue transaction could not start")
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := acquireAdvisoryLocks(ctx, tx, advisoryKey("queue", "delivery")); err != nil {
		return nil, err
	}

	type notificationKey struct {
		deviceIdentifier string
		digest           [32]byte
	}
	leaders := make(map[notificationKey]int, len(notifications))
	duplicates := make(map[int][]int)
	uniqueIndices := make([]int, 0, len(notifications))
	deviceSet := make(map[string]struct{})
	for index, notification := range notifications {
		key := notificationKey{
			deviceIdentifier: notification.DeviceIdentifier,
			digest:           notification.EnvelopeDigest,
		}
		if leader, exists := leaders[key]; exists {
			duplicates[leader] = append(duplicates[leader], index)
			continue
		}
		leaders[key] = index
		uniqueIndices = append(uniqueIndices, index)
		deviceSet[notification.DeviceIdentifier] = struct{}{}
	}

	deviceIdentifiers := make([]string, 0, len(deviceSet))
	for deviceIdentifier := range deviceSet {
		deviceIdentifiers = append(deviceIdentifiers, deviceIdentifier)
	}
	sort.Strings(deviceIdentifiers)
	rows, err := tx.Query(ctx, `
		SELECT device_identifier, generation
		FROM registrations
		WHERE device_identifier = ANY($1::text[])
		  AND revoked_at IS NULL
		ORDER BY device_identifier
		FOR UPDATE`, deviceIdentifiers)
	if err != nil {
		return nil, errors.New("registrations could not be locked for enqueue")
	}
	activeGenerations := make(map[string]int64, len(deviceIdentifiers))
	for rows.Next() {
		var deviceIdentifier string
		var generation int64
		if err := rows.Scan(&deviceIdentifier, &generation); err != nil {
			rows.Close()
			return nil, errors.New("registrations could not be read for enqueue")
		}
		activeGenerations[deviceIdentifier] = generation
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, errors.New("registrations could not be read for enqueue")
	}
	rows.Close()

	newIndices := make([]int, 0, len(uniqueIndices))
	for _, index := range uniqueIndices {
		notification := notifications[index]
		if activeGenerations[notification.DeviceIdentifier] != notification.RegistrationGeneration {
			outcomes[index].RegistrationChanged = true
			continue
		}
		var exists bool
		if err := tx.QueryRow(ctx, `
			SELECT EXISTS (
				SELECT 1
				FROM delivery_jobs
				WHERE device_identifier = $1 AND envelope_digest = $2
			)`, notification.DeviceIdentifier, notification.EnvelopeDigest[:]).Scan(&exists); err != nil {
			return nil, errors.New("delivery dedupe evidence could not be checked")
		}
		if exists {
			outcomes[index] = EnqueueOutcome{Accepted: true, Duplicate: true}
			continue
		}
		newIndices = append(newIndices, index)
	}

	var activeDepth int
	if err := tx.QueryRow(ctx, `
		SELECT count(*)
		FROM delivery_jobs
		WHERE status IN ('pending', 'leased')`).Scan(&activeDepth); err != nil {
		return nil, errors.New("delivery queue depth could not be read")
	}
	if activeDepth+len(newIndices) > s.queueMaximumDepth {
		return nil, ErrQueueFull
	}

	for _, index := range newIndices {
		notification := notifications[index]
		if _, err := tx.Exec(ctx, `
			INSERT INTO delivery_jobs (
				device_identifier, registration_generation, envelope_digest,
				subject, signature, priority, notification_type
			) VALUES ($1, $2, $3, $4, $5, $6, $7)`,
			notification.DeviceIdentifier,
			notification.RegistrationGeneration,
			notification.EnvelopeDigest[:],
			notification.Subject,
			notification.Signature,
			notification.Priority,
			notification.Type,
		); err != nil {
			return nil, errors.New("delivery job could not be inserted")
		}
		outcomes[index].Accepted = true
	}

	for leader, duplicateIndices := range duplicates {
		for _, index := range duplicateIndices {
			outcomes[index] = outcomes[leader]
			if outcomes[index].Accepted {
				outcomes[index].Duplicate = true
			}
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, errors.New("enqueue transaction could not commit")
	}
	return outcomes, nil
}

func (s *Store) Claim(ctx context.Context, limit int, leaseDuration time.Duration) ([]ClaimedJob, error) {
	if limit < 1 || leaseDuration <= 0 {
		return nil, ErrInvalidMutation
	}
	leaseID, err := newLeaseID()
	if err != nil {
		return nil, err
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, errors.New("claim transaction could not start")
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `
		UPDATE delivery_jobs
		SET status = 'pending', lease_id = NULL, lease_until = NULL,
			available_at = clock_timestamp(), last_error_class = 'lease_expired',
			updated_at = clock_timestamp()
		WHERE status = 'leased' AND lease_until <= clock_timestamp()`); err != nil {
		return nil, errors.New("expired delivery leases could not be recovered")
	}
	if _, err := tx.Exec(ctx, `
		UPDATE delivery_jobs AS job
		SET status = 'cancelled', lease_id = NULL, lease_until = NULL,
			last_error_class = 'registration_stale', updated_at = clock_timestamp()
		WHERE job.status = 'pending'
		  AND NOT EXISTS (
			SELECT 1
			FROM registrations AS registration
			WHERE registration.device_identifier = job.device_identifier
			  AND registration.generation = job.registration_generation
			  AND registration.revoked_at IS NULL
		  )`); err != nil {
		return nil, errors.New("stale delivery jobs could not be cancelled")
	}

	rows, err := tx.Query(ctx, `
		SELECT job.id
		FROM delivery_jobs AS job
		JOIN registrations AS registration
		  ON registration.device_identifier = job.device_identifier
		 AND registration.generation = job.registration_generation
		 AND registration.revoked_at IS NULL
		WHERE job.status = 'pending'
		  AND job.available_at <= clock_timestamp()
		ORDER BY CASE job.priority WHEN 'high' THEN 0 ELSE 1 END,
			job.created_at, job.id
		FOR UPDATE OF job SKIP LOCKED
		LIMIT $1`, limit)
	if err != nil {
		return nil, errors.New("delivery jobs could not be claimed")
	}
	jobIDs := make([]int64, 0, limit)
	for rows.Next() {
		var jobID int64
		if err := rows.Scan(&jobID); err != nil {
			rows.Close()
			return nil, errors.New("claimed delivery job could not be read")
		}
		jobIDs = append(jobIDs, jobID)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, errors.New("claimed delivery jobs could not be read")
	}
	rows.Close()
	if len(jobIDs) == 0 {
		if err := tx.Commit(ctx); err != nil {
			return nil, errors.New("empty claim transaction could not commit")
		}
		return []ClaimedJob{}, nil
	}

	if _, err := tx.Exec(ctx, `
		UPDATE delivery_jobs
		SET status = 'leased', lease_id = $2,
			lease_until = clock_timestamp() + $3::interval,
			attempt_count = attempt_count + 1,
			updated_at = clock_timestamp()
		WHERE id = ANY($1::bigint[])`, jobIDs, leaseID, leaseDuration.String()); err != nil {
		return nil, errors.New("delivery jobs could not be leased")
	}

	rows, err = tx.Query(ctx, `
		SELECT job.id, job.lease_id, job.device_identifier,
			job.registration_generation, job.subject, job.signature,
			job.priority, job.notification_type, job.attempt_count,
			registration.encrypted_token, registration.token_nonce
		FROM delivery_jobs AS job
		JOIN registrations AS registration
		  ON registration.device_identifier = job.device_identifier
		 AND registration.generation = job.registration_generation
		 AND registration.revoked_at IS NULL
		WHERE job.id = ANY($1::bigint[]) AND job.lease_id = $2
		ORDER BY job.id`, jobIDs, leaseID)
	if err != nil {
		return nil, errors.New("leased delivery jobs could not be loaded")
	}
	claimed := make([]ClaimedJob, 0, len(jobIDs))
	for rows.Next() {
		var job ClaimedJob
		if err := rows.Scan(
			&job.ID,
			&job.LeaseID,
			&job.DeviceIdentifier,
			&job.RegistrationGeneration,
			&job.Subject,
			&job.Signature,
			&job.Priority,
			&job.Type,
			&job.Attempt,
			&job.EncryptedToken.Ciphertext,
			&job.EncryptedToken.Nonce,
		); err != nil {
			rows.Close()
			return nil, errors.New("leased delivery job could not be decoded")
		}
		claimed = append(claimed, job)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, errors.New("leased delivery jobs could not be decoded")
	}
	rows.Close()
	if len(claimed) != len(jobIDs) {
		return nil, errors.New("registration changed while delivery jobs were claimed")
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, errors.New("claim transaction could not commit")
	}
	return claimed, nil
}

func (s *Store) MarkDelivered(ctx context.Context, jobID int64, leaseID string) error {
	if !validLease(jobID, leaseID) {
		return ErrInvalidMutation
	}
	tag, err := s.pool.Exec(ctx, `
		UPDATE delivery_jobs
		SET status = 'delivered', lease_id = NULL, lease_until = NULL,
			delivered_at = clock_timestamp(), last_error_class = NULL,
			updated_at = clock_timestamp()
		WHERE id = $1 AND status = 'leased' AND lease_id = $2`, jobID, leaseID)
	if err != nil {
		return errors.New("delivered job could not be committed")
	}
	if tag.RowsAffected() != 1 {
		return ErrLeaseLost
	}
	return nil
}

func (s *Store) Retry(
	ctx context.Context,
	jobID int64,
	leaseID string,
	errorClass string,
	nextAttempt time.Time,
	maxAttempts int,
) (RetryResult, error) {
	if !validLease(jobID, leaseID) || !validErrorClass(errorClass) || nextAttempt.IsZero() || maxAttempts < 1 {
		return RetryResult{}, ErrInvalidMutation
	}
	var status string
	err := s.pool.QueryRow(ctx, `
		UPDATE delivery_jobs
		SET status = CASE
				WHEN attempt_count >= $5 THEN 'permanent_failure'
				ELSE 'pending'
			END,
			lease_id = NULL,
			lease_until = NULL,
			available_at = CASE
				WHEN attempt_count >= $5 THEN available_at
				ELSE $4
			END,
			last_error_class = $3,
			updated_at = clock_timestamp()
		WHERE id = $1 AND status = 'leased' AND lease_id = $2
		RETURNING status`, jobID, leaseID, errorClass, nextAttempt.UTC(), maxAttempts).Scan(&status)
	if errors.Is(err, pgx.ErrNoRows) {
		return RetryResult{}, ErrLeaseLost
	}
	if err != nil {
		return RetryResult{}, errors.New("delivery retry could not be committed")
	}
	return RetryResult{Exhausted: status == "permanent_failure"}, nil
}

func (s *Store) MarkPermanent(ctx context.Context, jobID int64, leaseID, errorClass string) error {
	if !validLease(jobID, leaseID) || !validErrorClass(errorClass) {
		return ErrInvalidMutation
	}
	tag, err := s.pool.Exec(ctx, `
		UPDATE delivery_jobs
		SET status = 'permanent_failure', lease_id = NULL, lease_until = NULL,
			last_error_class = $3, updated_at = clock_timestamp()
		WHERE id = $1 AND status = 'leased' AND lease_id = $2`, jobID, leaseID, errorClass)
	if err != nil {
		return errors.New("permanent delivery failure could not be committed")
	}
	if tag.RowsAffected() != 1 {
		return ErrLeaseLost
	}
	return nil
}

func (s *Store) RevokeInvalidToken(ctx context.Context, jobID int64, leaseID string) error {
	if !validLease(jobID, leaseID) {
		return ErrInvalidMutation
	}
	var deviceIdentifier string
	if err := s.pool.QueryRow(ctx, `
		SELECT device_identifier
		FROM delivery_jobs
		WHERE id = $1 AND status = 'leased' AND lease_id = $2`, jobID, leaseID).Scan(&deviceIdentifier); errors.Is(err, pgx.ErrNoRows) {
		return ErrLeaseLost
	} else if err != nil {
		return errors.New("invalid-token job could not be read")
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return errors.New("invalid-token transaction could not start")
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := acquireAdvisoryLocks(ctx, tx, advisoryKey("device", deviceIdentifier)); err != nil {
		return err
	}
	var generation int64
	if err := tx.QueryRow(ctx, `
		SELECT registration_generation
		FROM delivery_jobs
		WHERE id = $1 AND status = 'leased' AND lease_id = $2
		FOR UPDATE`, jobID, leaseID).Scan(&generation); errors.Is(err, pgx.ErrNoRows) {
		return ErrLeaseLost
	} else if err != nil {
		return errors.New("invalid-token job could not be locked")
	}

	var currentGeneration int64
	var revokedAt *time.Time
	err = tx.QueryRow(ctx, `
		SELECT generation, revoked_at
		FROM registrations
		WHERE device_identifier = $1
		FOR UPDATE`, deviceIdentifier).Scan(&currentGeneration, &revokedAt)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return errors.New("invalid-token registration could not be locked")
	}
	if err == nil && revokedAt == nil && currentGeneration == generation {
		if _, err := tx.Exec(ctx, `
			UPDATE registrations
			SET revoked_at = clock_timestamp(), updated_at = clock_timestamp()
			WHERE device_identifier = $1 AND generation = $2`, deviceIdentifier, generation); err != nil {
			return errors.New("invalid provider token could not revoke registration")
		}
		if _, err := tx.Exec(ctx, `
			UPDATE delivery_jobs
			SET status = 'cancelled', lease_id = NULL, lease_until = NULL,
				last_error_class = 'invalid_token', updated_at = clock_timestamp()
			WHERE device_identifier = $1
			  AND registration_generation = $2
			  AND status IN ('pending', 'leased')`, deviceIdentifier, generation); err != nil {
			return errors.New("invalid provider token jobs could not be cancelled")
		}
	} else {
		tag, updateErr := tx.Exec(ctx, `
			UPDATE delivery_jobs
			SET status = 'cancelled', lease_id = NULL, lease_until = NULL,
				last_error_class = 'registration_stale', updated_at = clock_timestamp()
			WHERE id = $1 AND status = 'leased' AND lease_id = $2`, jobID, leaseID)
		if updateErr != nil {
			return errors.New("stale invalid-token job could not be cancelled")
		}
		if tag.RowsAffected() != 1 {
			return ErrLeaseLost
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return errors.New("invalid-token transaction could not commit")
	}
	return nil
}

func (s *Store) Cleanup(ctx context.Context, retention time.Duration) (int64, error) {
	if retention <= 0 {
		return 0, ErrInvalidMutation
	}
	tag, err := s.pool.Exec(ctx, `
		DELETE FROM delivery_jobs
		WHERE status IN ('delivered', 'permanent_failure', 'cancelled')
		  AND updated_at < clock_timestamp() - $1::interval`, retention.String())
	if err != nil {
		return 0, errors.New("delivery dedupe cleanup failed")
	}
	return tag.RowsAffected(), nil
}

func (s *Store) QueueStats(ctx context.Context) (QueueStats, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT status, count(*)
		FROM delivery_jobs
		GROUP BY status`)
	if err != nil {
		return QueueStats{}, errors.New("delivery queue statistics could not be read")
	}
	defer rows.Close()
	var stats QueueStats
	for rows.Next() {
		var status string
		var count int64
		if err := rows.Scan(&status, &count); err != nil {
			return QueueStats{}, errors.New("delivery queue statistics could not be decoded")
		}
		switch status {
		case "pending":
			stats.Pending = count
		case "leased":
			stats.Leased = count
		case "delivered":
			stats.Delivered = count
		case "permanent_failure":
			stats.PermanentFailure = count
		case "cancelled":
			stats.Cancelled = count
		}
	}
	if rows.Err() != nil {
		return QueueStats{}, errors.New("delivery queue statistics could not be read")
	}
	return stats, nil
}

func validateNotification(notification Notification) error {
	if notification.RegistrationGeneration < 1 ||
		len(notification.DeviceIdentifier) != 88 ||
		len(notification.Subject) != 344 ||
		len(notification.Signature) != 344 ||
		(notification.Priority != "high" && notification.Priority != "normal") ||
		(notification.Type != "alert" && notification.Type != "voip" && notification.Type != "background") {
		return ErrInvalidMutation
	}
	return nil
}

func validLease(jobID int64, leaseID string) bool {
	if jobID < 1 || len(leaseID) != 32 {
		return false
	}
	_, err := hex.DecodeString(leaseID)
	return err == nil
}

func validErrorClass(errorClass string) bool {
	return errorClassPattern.MatchString(errorClass)
}

func newLeaseID() (string, error) {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return "", errors.New("delivery lease identifier could not be generated")
	}
	return hex.EncodeToString(value), nil
}
