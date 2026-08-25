//go:build integration

package store

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	embeddedpostgres "github.com/fergusstrange/embedded-postgres"
	"github.com/jackc/pgx/v5/pgxpool"

	"nks-nextcloud-talk/services/push_gateway/internal/cryptoidentity"
)

var integrationDatabaseURL string

func TestMain(m *testing.M) {
	runtimeRoot, err := os.MkdirTemp("", "nks-push-gateway-postgres-")
	if err != nil {
		panic(err)
	}
	port, err := availableTCPPort()
	if err != nil {
		_ = os.RemoveAll(runtimeRoot)
		panic(err)
	}
	configuration := embeddedpostgres.DefaultConfig().
		Version(embeddedpostgres.V18).
		Port(uint32(port)).
		Database("push_gateway").
		Username("gateway").
		Password("integration-only-password").
		RuntimePath(filepath.Join(runtimeRoot, "runtime")).
		DataPath(filepath.Join(runtimeRoot, "data")).
		StartTimeout(2 * time.Minute).
		Logger(io.Discard)
	database := embeddedpostgres.NewDatabase(configuration)
	if err := database.Start(); err != nil {
		_ = os.RemoveAll(runtimeRoot)
		panic(err)
	}
	integrationDatabaseURL = configuration.GetConnectionURL() + "?sslmode=disable"

	code := m.Run()
	if err := database.Stop(); err != nil && code == 0 {
		code = 1
	}
	if err := os.RemoveAll(runtimeRoot); err != nil && code == 0 {
		code = 1
	}
	os.Exit(code)
}

func TestPostgresRegistrationAndEncryption(t *testing.T) {
	store, pool := freshIntegrationStore(t, 10)
	firstIdentity := newTestIdentity(t, "first-device")
	first := registerTestIdentity(t, store, firstIdentity, "shared-provider-token", false)
	if first.Generation != 1 || first.RevokedAt != nil {
		t.Fatalf("first registration = %+v", first)
	}
	refreshed := registerTestIdentity(t, store, firstIdentity, "shared-provider-token", false)
	if refreshed.Generation != first.Generation {
		t.Fatalf("idempotent refresh generation = %d, want %d", refreshed.Generation, first.Generation)
	}

	var encryptedToken []byte
	if err := pool.QueryRow(
		context.Background(),
		"SELECT encrypted_token FROM registrations WHERE device_identifier = $1",
		firstIdentity.deviceIdentifier,
	).Scan(&encryptedToken); err != nil {
		t.Fatalf("read encrypted token: %v", err)
	}
	if bytes.Contains(encryptedToken, []byte("shared-provider-token")) ||
		bytes.Equal(encryptedToken, []byte("shared-provider-token")) {
		t.Fatal("database contains the plaintext provider token")
	}
	var plaintextColumns int
	if err := pool.QueryRow(context.Background(), `
		SELECT count(*)
		FROM information_schema.columns
		WHERE table_schema = 'public'
		  AND table_name = 'registrations'
		  AND column_name IN ('push_token', 'provider_token', 'token')`).Scan(&plaintextColumns); err != nil {
		t.Fatalf("inspect registration columns: %v", err)
	}
	if plaintextColumns != 0 {
		t.Fatalf("registration table exposes %d plaintext token columns", plaintextColumns)
	}

	secondIdentity := newTestIdentity(t, "second-device")
	_, err := store.Register(context.Background(), mutationForIdentity(
		t,
		secondIdentity,
		"shared-provider-token",
		false,
	))
	if !errors.Is(err, ErrTokenConflict) {
		t.Fatalf("shared token registration error = %v, want ErrTokenConflict", err)
	}
	second := registerTestIdentity(t, store, secondIdentity, "shared-provider-token", true)
	if second.Generation != 1 {
		t.Fatalf("recovery registration generation = %d, want 1", second.Generation)
	}

	wrongKey := newTestIdentity(t, "wrong-key")
	wrongMutation := mutationForIdentity(t, wrongKey, "new-provider-token", false)
	wrongMutation.DeviceIdentifier = firstIdentity.deviceIdentifier
	_, err = store.Register(context.Background(), wrongMutation)
	if !errors.Is(err, ErrIdentityForbidden) {
		t.Fatalf("public key replacement error = %v, want ErrIdentityForbidden", err)
	}
	if err := store.Unregister(context.Background(), firstIdentity.deviceIdentifier, wrongKey.fingerprint); !errors.Is(err, ErrIdentityForbidden) {
		t.Fatalf("wrong-key unregistration error = %v, want ErrIdentityForbidden", err)
	}
	if err := store.Unregister(context.Background(), firstIdentity.deviceIdentifier, firstIdentity.fingerprint); err != nil {
		t.Fatalf("Unregister() error = %v", err)
	}
	if err := store.Unregister(context.Background(), firstIdentity.deviceIdentifier, firstIdentity.fingerprint); err != nil {
		t.Fatalf("idempotent Unregister() error = %v", err)
	}
}

func TestPostgresConcurrentTokenConflict(t *testing.T) {
	store, _ := freshIntegrationStore(t, 10)
	identities := []testIdentity{
		newTestIdentity(t, "concurrent-first"),
		newTestIdentity(t, "concurrent-second"),
	}
	mutations := []RegistrationMutation{
		mutationForIdentity(t, identities[0], "one-physical-token", false),
		mutationForIdentity(t, identities[1], "one-physical-token", false),
	}
	start := make(chan struct{})
	errorsByCall := make(chan error, len(mutations))
	var waitGroup sync.WaitGroup
	for _, mutation := range mutations {
		mutation := mutation
		waitGroup.Add(1)
		go func() {
			defer waitGroup.Done()
			<-start
			_, err := store.Register(context.Background(), mutation)
			errorsByCall <- err
		}()
	}
	close(start)
	waitGroup.Wait()
	close(errorsByCall)
	successes := 0
	conflicts := 0
	for err := range errorsByCall {
		switch {
		case err == nil:
			successes++
		case errors.Is(err, ErrTokenConflict):
			conflicts++
		default:
			t.Fatalf("concurrent Register() error = %v", err)
		}
	}
	if successes != 1 || conflicts != 1 {
		t.Fatalf("concurrent registration results success=%d conflict=%d", successes, conflicts)
	}
}

func TestPostgresQueueLeaseRetryAndCleanup(t *testing.T) {
	store, pool := freshIntegrationStore(t, 1)
	identity := newTestIdentity(t, "queue-device")
	registration := registerTestIdentity(t, store, identity, "queue-provider-token", false)
	firstNotification := testNotification(identity.deviceIdentifier, registration.Generation, "first-envelope")
	secondNotification := testNotification(identity.deviceIdentifier, registration.Generation, "second-envelope")

	outcomes, err := store.Enqueue(context.Background(), []Notification{firstNotification, firstNotification})
	if err != nil {
		t.Fatalf("Enqueue(first + duplicate) error = %v", err)
	}
	if !outcomes[0].Accepted || outcomes[0].Duplicate || !outcomes[1].Accepted || !outcomes[1].Duplicate {
		t.Fatalf("duplicate enqueue outcomes = %+v", outcomes)
	}
	if _, err := store.Enqueue(context.Background(), []Notification{secondNotification}); !errors.Is(err, ErrQueueFull) {
		t.Fatalf("full queue error = %v, want ErrQueueFull", err)
	}

	claimed, err := store.Claim(context.Background(), 1, 60*time.Millisecond)
	if err != nil || len(claimed) != 1 {
		t.Fatalf("Claim(first) jobs=%d error=%v", len(claimed), err)
	}
	if token := decryptClaimedToken(t, claimed[0]); token != "queue-provider-token" {
		t.Fatalf("claimed provider token = %q", token)
	}
	if err := store.MarkDelivered(context.Background(), claimed[0].ID, stringsOfLength("0", 32)); !errors.Is(err, ErrLeaseLost) {
		t.Fatalf("wrong lease completion error = %v, want ErrLeaseLost", err)
	}
	time.Sleep(90 * time.Millisecond)
	reclaimed, err := store.Claim(context.Background(), 1, time.Second)
	if err != nil || len(reclaimed) != 1 {
		t.Fatalf("Claim(recovered) jobs=%d error=%v", len(reclaimed), err)
	}
	if reclaimed[0].Attempt != 2 || reclaimed[0].LeaseID == claimed[0].LeaseID {
		t.Fatalf("reclaimed job = %+v", reclaimed[0])
	}
	retry, err := store.Retry(
		context.Background(),
		reclaimed[0].ID,
		reclaimed[0].LeaseID,
		"provider_timeout",
		time.Now().Add(-time.Second),
		3,
	)
	if err != nil || retry.Exhausted {
		t.Fatalf("Retry() result=%+v error=%v", retry, err)
	}
	thirdClaim, err := store.Claim(context.Background(), 1, time.Second)
	if err != nil || len(thirdClaim) != 1 || thirdClaim[0].Attempt != 3 {
		t.Fatalf("Claim(third) jobs=%+v error=%v", thirdClaim, err)
	}
	if err := store.MarkDelivered(context.Background(), thirdClaim[0].ID, thirdClaim[0].LeaseID); err != nil {
		t.Fatalf("MarkDelivered() error = %v", err)
	}

	if _, err := store.Enqueue(context.Background(), []Notification{secondNotification}); err != nil {
		t.Fatalf("Enqueue(after delivery) error = %v", err)
	}
	secondClaim, err := store.Claim(context.Background(), 1, time.Second)
	if err != nil || len(secondClaim) != 1 {
		t.Fatalf("Claim(second) jobs=%d error=%v", len(secondClaim), err)
	}
	if err := store.MarkPermanent(context.Background(), secondClaim[0].ID, secondClaim[0].LeaseID, "invalid_envelope"); err != nil {
		t.Fatalf("MarkPermanent() error = %v", err)
	}
	if _, err := pool.Exec(context.Background(), `
		UPDATE delivery_jobs
		SET updated_at = clock_timestamp() - interval '2 hours'
		WHERE status IN ('delivered', 'permanent_failure')`); err != nil {
		t.Fatalf("age terminal jobs: %v", err)
	}
	deleted, err := store.Cleanup(context.Background(), time.Hour)
	if err != nil || deleted != 2 {
		t.Fatalf("Cleanup() deleted=%d error=%v", deleted, err)
	}
	if _, err := store.Enqueue(context.Background(), []Notification{firstNotification}); err != nil {
		t.Fatalf("Enqueue(after dedupe retention) error = %v", err)
	}
}

func TestPostgresConcurrentClaimsAreDisjoint(t *testing.T) {
	store, _ := freshIntegrationStore(t, 100)
	identity := newTestIdentity(t, "claim-device")
	registration := registerTestIdentity(t, store, identity, "claim-provider-token", false)
	notifications := make([]Notification, 20)
	for index := range notifications {
		notifications[index] = testNotification(
			identity.deviceIdentifier,
			registration.Generation,
			"claim-envelope-"+strconv.Itoa(index),
		)
	}
	if _, err := store.Enqueue(context.Background(), notifications); err != nil {
		t.Fatalf("Enqueue(20) error = %v", err)
	}

	start := make(chan struct{})
	results := make(chan []ClaimedJob, 4)
	errorsByWorker := make(chan error, 4)
	var waitGroup sync.WaitGroup
	for range 4 {
		waitGroup.Add(1)
		go func() {
			defer waitGroup.Done()
			<-start
			jobs, err := store.Claim(context.Background(), 5, time.Second)
			results <- jobs
			errorsByWorker <- err
		}()
	}
	close(start)
	waitGroup.Wait()
	close(results)
	close(errorsByWorker)
	for err := range errorsByWorker {
		if err != nil {
			t.Fatalf("concurrent Claim() error = %v", err)
		}
	}
	seen := make(map[int64]struct{}, len(notifications))
	for jobs := range results {
		for _, job := range jobs {
			if _, exists := seen[job.ID]; exists {
				t.Fatalf("job %d was claimed more than once", job.ID)
			}
			seen[job.ID] = struct{}{}
			if err := store.MarkDelivered(context.Background(), job.ID, job.LeaseID); err != nil {
				t.Fatalf("MarkDelivered(%d) error = %v", job.ID, err)
			}
		}
	}
	if len(seen) != len(notifications) {
		t.Fatalf("claimed %d unique jobs, want %d", len(seen), len(notifications))
	}
}

func TestPostgresRotationInvalidTokenAndRestart(t *testing.T) {
	store, pool := freshIntegrationStore(t, 10)
	identity := newTestIdentity(t, "rotation-device")
	first := registerTestIdentity(t, store, identity, "old-provider-token", false)
	oldNotification := testNotification(identity.deviceIdentifier, first.Generation, "old-generation")
	if _, err := store.Enqueue(context.Background(), []Notification{oldNotification}); err != nil {
		t.Fatalf("Enqueue(old) error = %v", err)
	}
	rotated := registerTestIdentity(t, store, identity, "new-provider-token", false)
	if rotated.Generation != first.Generation+1 {
		t.Fatalf("rotated generation = %d, want %d", rotated.Generation, first.Generation+1)
	}
	outcomes, err := store.Enqueue(context.Background(), []Notification{oldNotification})
	if err != nil || !outcomes[0].RegistrationChanged || outcomes[0].Accepted {
		t.Fatalf("old generation enqueue outcomes=%+v error=%v", outcomes, err)
	}
	currentNotification := testNotification(identity.deviceIdentifier, rotated.Generation, "current-generation")
	if _, err := store.Enqueue(context.Background(), []Notification{currentNotification}); err != nil {
		t.Fatalf("Enqueue(current) error = %v", err)
	}

	pool.Close()
	reopenedPool, err := pgxpool.New(context.Background(), integrationDatabaseURL)
	if err != nil {
		t.Fatalf("reopen pool: %v", err)
	}
	t.Cleanup(reopenedPool.Close)
	if err := Migrate(context.Background(), reopenedPool); err != nil {
		t.Fatalf("Migrate(restart) error = %v", err)
	}
	reopenedStore, err := New(reopenedPool, 10)
	if err != nil {
		t.Fatalf("New(restarted) error = %v", err)
	}
	jobs, err := reopenedStore.Claim(context.Background(), 10, time.Second)
	if err != nil || len(jobs) != 1 {
		t.Fatalf("Claim(after restart) jobs=%d error=%v", len(jobs), err)
	}
	if err := reopenedStore.RevokeInvalidToken(context.Background(), jobs[0].ID, jobs[0].LeaseID); err != nil {
		t.Fatalf("RevokeInvalidToken() error = %v", err)
	}
	registrations, err := reopenedStore.Registrations(context.Background(), []string{identity.deviceIdentifier})
	if err != nil || len(registrations) != 0 {
		t.Fatalf("active registrations after invalid token = %d error=%v", len(registrations), err)
	}
	reactivated := registerTestIdentity(t, reopenedStore, identity, "new-provider-token", false)
	if reactivated.Generation != rotated.Generation+1 {
		t.Fatalf("reactivated generation = %d, want %d", reactivated.Generation, rotated.Generation+1)
	}
}

type testIdentity struct {
	deviceIdentifier string
	deviceSignature  string
	publicKeyPEM     string
	publicKeyDER     []byte
	fingerprint      []byte
}

func newTestIdentity(t *testing.T, label string) testIdentity {
	t.Helper()
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate RSA key: %v", err)
	}
	der, err := x509.MarshalPKIXPublicKey(&privateKey.PublicKey)
	if err != nil {
		t.Fatalf("marshal RSA public key: %v", err)
	}
	digest := sha512.Sum512([]byte(label))
	signature := make([]byte, privateKey.Size())
	if _, err := rand.Read(signature); err != nil {
		t.Fatalf("generate identity signature fixture: %v", err)
	}
	fingerprint := sha256.Sum256(der)
	return testIdentity{
		deviceIdentifier: base64.StdEncoding.EncodeToString(digest[:]),
		deviceSignature:  base64.StdEncoding.EncodeToString(signature),
		publicKeyPEM: string(pem.EncodeToMemory(&pem.Block{
			Type:  "PUBLIC KEY",
			Bytes: der,
		})),
		publicKeyDER: append([]byte(nil), der...),
		fingerprint:  append([]byte(nil), fingerprint[:]...),
	}
}

func mutationForIdentity(
	t *testing.T,
	identity testIdentity,
	token string,
	recoveryVerified bool,
) RegistrationMutation {
	t.Helper()
	cipher, err := cryptoidentity.NewTokenCipher(bytes.Repeat([]byte{0x42}, cryptoidentity.TokenEncryptionKeyLength))
	if err != nil {
		t.Fatalf("NewTokenCipher() error = %v", err)
	}
	encryptedToken, err := cipher.Encrypt(token, identity.deviceIdentifier)
	if err != nil {
		t.Fatalf("Encrypt() error = %v", err)
	}
	tokenHash, err := cryptoidentity.TokenHash(token)
	if err != nil {
		t.Fatalf("TokenHash() error = %v", err)
	}
	return RegistrationMutation{
		DeviceIdentifier:     identity.deviceIdentifier,
		DeviceSignature:      identity.deviceSignature,
		PublicKeyPEM:         identity.publicKeyPEM,
		PublicKeyDER:         identity.publicKeyDER,
		PublicKeyFingerprint: identity.fingerprint,
		TokenHash:            tokenHash,
		EncryptedToken:       encryptedToken,
		RecoveryVerified:     recoveryVerified,
	}
}

func registerTestIdentity(
	t *testing.T,
	store *Store,
	identity testIdentity,
	token string,
	recoveryVerified bool,
) Registration {
	t.Helper()
	registration, err := store.Register(
		context.Background(),
		mutationForIdentity(t, identity, token, recoveryVerified),
	)
	if err != nil {
		t.Fatalf("Register() error = %v", err)
	}
	return registration
}

func testNotification(deviceIdentifier string, generation int64, label string) Notification {
	digest := sha256.Sum256([]byte(label))
	subject := bytes.Repeat([]byte{byte(len(label))}, 256)
	signature := bytes.Repeat([]byte{byte(len(label) + 1)}, 256)
	return Notification{
		DeviceIdentifier:       deviceIdentifier,
		RegistrationGeneration: generation,
		EnvelopeDigest:         digest,
		Subject:                base64.StdEncoding.EncodeToString(subject),
		Signature:              base64.StdEncoding.EncodeToString(signature),
		Priority:               "high",
		Type:                   "alert",
	}
}

func freshIntegrationStore(t *testing.T, maximumDepth int) (*Store, *pgxpool.Pool) {
	t.Helper()
	pool, err := pgxpool.New(context.Background(), integrationDatabaseURL)
	if err != nil {
		t.Fatalf("pgxpool.New() error = %v", err)
	}
	t.Cleanup(pool.Close)
	if err := Migrate(context.Background(), pool); err != nil {
		t.Fatalf("Migrate(first) error = %v", err)
	}
	if err := Migrate(context.Background(), pool); err != nil {
		t.Fatalf("Migrate(idempotent) error = %v", err)
	}
	current, err := MigrationsCurrent(context.Background(), pool)
	if err != nil || !current {
		t.Fatalf("MigrationsCurrent() current=%v error=%v", current, err)
	}
	if _, err := pool.Exec(context.Background(), "TRUNCATE delivery_jobs, registrations RESTART IDENTITY CASCADE"); err != nil {
		t.Fatalf("truncate integration tables: %v", err)
	}
	store, err := New(pool, maximumDepth)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	return store, pool
}

func decryptClaimedToken(t *testing.T, job ClaimedJob) string {
	t.Helper()
	cipher, err := cryptoidentity.NewTokenCipher(bytes.Repeat([]byte{0x42}, cryptoidentity.TokenEncryptionKeyLength))
	if err != nil {
		t.Fatalf("NewTokenCipher() error = %v", err)
	}
	token, err := cipher.Decrypt(job.EncryptedToken, job.DeviceIdentifier)
	if err != nil {
		t.Fatalf("Decrypt() error = %v", err)
	}
	return token
}

func availableTCPPort() (int, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		return 0, err
	}
	return port, nil
}

func stringsOfLength(value string, length int) string {
	buffer := make([]byte, 0, len(value)*length)
	for range length {
		buffer = append(buffer, value...)
	}
	return string(buffer)
}

func TestLeaseFixtureIsCanonicalHex(t *testing.T) {
	value := stringsOfLength("0", 32)
	decoded, err := hex.DecodeString(value)
	if err != nil || len(decoded) != 16 {
		t.Fatalf("lease fixture decoded=%d error=%v", len(decoded), err)
	}
}
