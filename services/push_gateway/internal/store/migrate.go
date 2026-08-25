package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"nks-nextcloud-talk/services/push_gateway/migrations"
)

const migrationAdvisoryLock int64 = 0x4e4b535055534847

func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	entries, err := fs.ReadDir(migrations.Files, ".")
	if err != nil {
		return errors.New("database migrations could not be listed")
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })

	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".sql") {
			continue
		}
		body, readErr := fs.ReadFile(migrations.Files, entry.Name())
		if readErr != nil {
			return fmt.Errorf("database migration %s could not be read", entry.Name())
		}
		if err := applyMigration(ctx, pool, entry.Name(), body); err != nil {
			return err
		}
	}
	return nil
}

func applyMigration(ctx context.Context, pool *pgxpool.Pool, name string, body []byte) error {
	tx, err := pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return errors.New("database migration transaction could not start")
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1)", migrationAdvisoryLock); err != nil {
		return errors.New("database migration lock could not be acquired")
	}
	if _, err := tx.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			name text PRIMARY KEY,
			checksum text NOT NULL,
			applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
		)`); err != nil {
		return errors.New("database migration ledger could not be created")
	}

	checksumBytes := sha256.Sum256(body)
	checksum := hex.EncodeToString(checksumBytes[:])
	var recordedChecksum string
	err = tx.QueryRow(ctx, "SELECT checksum FROM schema_migrations WHERE name = $1", name).Scan(&recordedChecksum)
	switch {
	case err == nil:
		if recordedChecksum != checksum {
			return fmt.Errorf("database migration %s checksum changed", name)
		}
		return tx.Commit(ctx)
	case !errors.Is(err, pgx.ErrNoRows):
		return errors.New("database migration ledger could not be read")
	}

	if _, err := tx.Exec(ctx, string(body)); err != nil {
		return fmt.Errorf("database migration %s failed: %w", name, err)
	}
	if _, err := tx.Exec(
		ctx,
		"INSERT INTO schema_migrations (name, checksum) VALUES ($1, $2)",
		name,
		checksum,
	); err != nil {
		return errors.New("database migration ledger could not be updated")
	}
	if err := tx.Commit(ctx); err != nil {
		return errors.New("database migration transaction could not commit")
	}
	return nil
}

func MigrationsCurrent(ctx context.Context, pool *pgxpool.Pool) (bool, error) {
	entries, err := fs.ReadDir(migrations.Files, ".")
	if err != nil {
		return false, errors.New("database migrations could not be listed")
	}
	expected := 0
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".sql") {
			expected++
		}
	}
	var applied int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM schema_migrations").Scan(&applied); err != nil {
		return false, nil
	}
	return applied == expected, nil
}
