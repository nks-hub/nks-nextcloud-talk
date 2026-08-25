package worker

import (
	"bytes"
	"context"
	"crypto/sha512"
	"encoding/base64"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"nks-nextcloud-talk/services/push_gateway/internal/cryptoidentity"
	"nks-nextcloud-talk/services/push_gateway/internal/provider"
	"nks-nextcloud-talk/services/push_gateway/internal/store"
)

func TestProcessCommitsProviderOutcomes(t *testing.T) {
	tests := []struct {
		name           string
		result         provider.Result
		wantMutation   string
		wantErrorClass string
	}{
		{
			name:         "delivered",
			result:       provider.Result{Outcome: provider.OutcomeDelivered},
			wantMutation: "delivered",
		},
		{
			name:         "invalid token",
			result:       provider.Result{Outcome: provider.OutcomeInvalidToken},
			wantMutation: "revoked",
		},
		{
			name:           "permanent message",
			result:         provider.Result{Outcome: provider.OutcomePermanentMessage},
			wantMutation:   "permanent",
			wantErrorClass: string(provider.OutcomePermanentMessage),
		},
		{
			name:           "retryable server failure",
			result:         provider.Result{Outcome: provider.OutcomeRetryServer},
			wantMutation:   "retry",
			wantErrorClass: string(provider.OutcomeRetryServer),
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			queue := &recordingQueue{}
			runner, job := testRunnerAndJob(t, queue, providerSenderFunc(func(context.Context, provider.Delivery) provider.Result {
				return test.result
			}))
			runner.random = func() float64 { return 0.5 }

			if err := runner.process(context.Background(), job); err != nil {
				t.Fatalf("process() error = %v", err)
			}
			if queue.mutation != test.wantMutation {
				t.Fatalf("mutation = %q, want %q", queue.mutation, test.wantMutation)
			}
			if queue.errorClass != test.wantErrorClass {
				t.Fatalf("error class = %q, want %q", queue.errorClass, test.wantErrorClass)
			}
		})
	}
}

func TestProcessUsesRetryAfterAsMinimum(t *testing.T) {
	queue := &recordingQueue{}
	runner, job := testRunnerAndJob(t, queue, providerSenderFunc(func(context.Context, provider.Delivery) provider.Result {
		return provider.Result{
			Outcome:    provider.OutcomeRetryRateLimited,
			RetryAfter: 90 * time.Second,
		}
	}))
	now := time.Date(2026, time.August, 23, 12, 0, 0, 0, time.UTC)
	runner.now = func() time.Time { return now }
	runner.random = func() float64 { return 0 }

	if err := runner.process(context.Background(), job); err != nil {
		t.Fatalf("process() error = %v", err)
	}
	if got := queue.nextAttempt.Sub(now); got != 90*time.Second {
		t.Fatalf("retry delay = %s, want 90s", got)
	}
	if queue.maxAttempts != maximumAttempts {
		t.Fatalf("max attempts = %d, want %d", queue.maxAttempts, maximumAttempts)
	}
}

func TestProcessDoesNotSendUndecryptableToken(t *testing.T) {
	queue := &recordingQueue{}
	providerCalls := 0
	runner, job := testRunnerAndJob(t, queue, providerSenderFunc(func(context.Context, provider.Delivery) provider.Result {
		providerCalls++
		return provider.Result{Outcome: provider.OutcomeDelivered}
	}))
	job.EncryptedToken.Ciphertext[0] ^= 0xff

	if err := runner.process(context.Background(), job); err != nil {
		t.Fatalf("process() error = %v", err)
	}
	if providerCalls != 0 {
		t.Fatalf("provider calls = %d, want 0", providerCalls)
	}
	if queue.mutation != "permanent" || queue.errorClass != "token_decryption" {
		t.Fatalf("queue mutation=%q class=%q", queue.mutation, queue.errorClass)
	}
}

func TestCrashAfterProviderAckPreservesAtLeastOnceWindow(t *testing.T) {
	queue := &recordingQueue{}
	providerCalls := 0
	runner, job := testRunnerAndJob(t, queue, providerSenderFunc(func(context.Context, provider.Delivery) provider.Result {
		providerCalls++
		return provider.Result{Outcome: provider.OutcomeDelivered}
	}))
	runner.afterAck = func() { panic("simulated process crash") }

	func() {
		defer func() {
			if recovered := recover(); recovered == nil {
				t.Fatal("process() did not reach the simulated crash window")
			}
		}()
		_ = runner.process(context.Background(), job)
	}()
	if queue.mutation != "" {
		t.Fatalf("provider ACK was committed before crash: %q", queue.mutation)
	}

	runner.afterAck = nil
	if err := runner.process(context.Background(), job); err != nil {
		t.Fatalf("reprocessed delivery error = %v", err)
	}
	if providerCalls != 2 || queue.mutation != "delivered" {
		t.Fatalf("provider calls=%d mutation=%q, want at-least-once duplicate then commit", providerCalls, queue.mutation)
	}
}

func TestRunBoundsProviderConcurrencyByWorkerCount(t *testing.T) {
	const jobCount = 12
	queue := newMemoryQueue(testJobs(t, jobCount))
	providerStarted := make(chan struct{}, jobCount)
	releaseProvider := make(chan struct{})
	var mutex sync.Mutex
	active := 0
	maximumActive := 0
	sender := providerSenderFunc(func(context.Context, provider.Delivery) provider.Result {
		mutex.Lock()
		active++
		if active > maximumActive {
			maximumActive = active
		}
		mutex.Unlock()
		providerStarted <- struct{}{}
		<-releaseProvider
		mutex.Lock()
		active--
		mutex.Unlock()
		return provider.Result{Outcome: provider.OutcomeDelivered}
	})
	cipher := testCipher(t)
	runner, err := New(Config{
		WorkerCount:     3,
		ClaimSize:       jobCount,
		LeaseDuration:   10 * time.Second,
		ProviderTimeout: 5 * time.Second,
		ShutdownTimeout: 8 * time.Second,
		DedupeRetention: time.Hour,
	}, queue, cipher, sender)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- runner.Run(ctx) }()

	for range 3 {
		select {
		case <-providerStarted:
		case <-time.After(2 * time.Second):
			t.Fatal("workers did not start provider delivery")
		}
	}
	select {
	case <-providerStarted:
		t.Fatal("provider concurrency exceeded worker count")
	case <-time.After(50 * time.Millisecond):
	}
	close(releaseProvider)
	deadline := time.After(3 * time.Second)
	for queue.deliveredCount() != jobCount {
		select {
		case <-deadline:
			t.Fatalf("delivered %d jobs, want %d", queue.deliveredCount(), jobCount)
		case <-time.After(10 * time.Millisecond):
		}
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run() error = %v", err)
	}
	if maximumActive != 3 {
		t.Fatalf("maximum provider concurrency = %d, want 3", maximumActive)
	}
	if queue.maximumClaimed() > 3 {
		t.Fatalf("maximum claim = %d, want at most 3 idle slots", queue.maximumClaimed())
	}
}

func TestRetryDelayIsBounded(t *testing.T) {
	if got := retryDelay(100, 24*time.Hour, 1); got != maximumRetryDelay {
		t.Fatalf("retryDelay() = %s, want %s", got, maximumRetryDelay)
	}
	if got := retryDelay(1, 0, -1); got != 800*time.Millisecond {
		t.Fatalf("minimum jitter delay = %s, want 800ms", got)
	}
}

func testRunnerAndJob(t *testing.T, queue Queue, sender provider.Sender) (*Runner, store.ClaimedJob) {
	t.Helper()
	cipher := testCipher(t)
	job := testJobsWithCipher(t, cipher, 1)[0]
	runner, err := New(Config{
		WorkerCount:     1,
		ClaimSize:       1,
		LeaseDuration:   time.Minute,
		ProviderTimeout: time.Second,
		ShutdownTimeout: 5 * time.Second,
		DedupeRetention: time.Hour,
	}, queue, cipher, sender)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	return runner, job
}

func testCipher(t *testing.T) *cryptoidentity.TokenCipher {
	t.Helper()
	cipher, err := cryptoidentity.NewTokenCipher(bytes.Repeat([]byte{0x42}, cryptoidentity.TokenEncryptionKeyLength))
	if err != nil {
		t.Fatalf("NewTokenCipher() error = %v", err)
	}
	return cipher
}

func testJobs(t *testing.T, count int) []store.ClaimedJob {
	t.Helper()
	return testJobsWithCipher(t, testCipher(t), count)
}

func testJobsWithCipher(t *testing.T, cipher *cryptoidentity.TokenCipher, count int) []store.ClaimedJob {
	t.Helper()
	jobs := make([]store.ClaimedJob, count)
	for index := range count {
		digest := sha512.Sum512([]byte(fmt.Sprintf("device-%d", index)))
		deviceIdentifier := base64.StdEncoding.EncodeToString(digest[:])
		encryptedToken, err := cipher.Encrypt(fmt.Sprintf("token-%d", index), deviceIdentifier)
		if err != nil {
			t.Fatalf("Encrypt() error = %v", err)
		}
		jobs[index] = store.ClaimedJob{
			ID:                     int64(index + 1),
			LeaseID:                fmt.Sprintf("%032x", index+1),
			DeviceIdentifier:       deviceIdentifier,
			RegistrationGeneration: 1,
			Subject:                base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x42}, 256)),
			Signature:              base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x24}, 256)),
			Priority:               "high",
			Type:                   "alert",
			Attempt:                1,
			EncryptedToken:         encryptedToken,
		}
	}
	return jobs
}

type providerSenderFunc func(context.Context, provider.Delivery) provider.Result

func (f providerSenderFunc) Send(ctx context.Context, delivery provider.Delivery) provider.Result {
	return f(ctx, delivery)
}

type recordingQueue struct {
	mutation    string
	errorClass  string
	nextAttempt time.Time
	maxAttempts int
}

func (q *recordingQueue) Claim(context.Context, int, time.Duration) ([]store.ClaimedJob, error) {
	return []store.ClaimedJob{}, nil
}

func (q *recordingQueue) MarkDelivered(context.Context, int64, string) error {
	q.mutation = "delivered"
	return nil
}

func (q *recordingQueue) Retry(
	_ context.Context,
	_ int64,
	_ string,
	errorClass string,
	nextAttempt time.Time,
	maxAttempts int,
) (store.RetryResult, error) {
	q.mutation = "retry"
	q.errorClass = errorClass
	q.nextAttempt = nextAttempt
	q.maxAttempts = maxAttempts
	return store.RetryResult{}, nil
}

func (q *recordingQueue) MarkPermanent(_ context.Context, _ int64, _, errorClass string) error {
	q.mutation = "permanent"
	q.errorClass = errorClass
	return nil
}

func (q *recordingQueue) RevokeInvalidToken(context.Context, int64, string) error {
	q.mutation = "revoked"
	return nil
}

func (q *recordingQueue) Cleanup(context.Context, time.Duration) (int64, error) {
	return 0, nil
}

type memoryQueue struct {
	mutex        sync.Mutex
	pending      []store.ClaimedJob
	delivered    map[int64]struct{}
	maximumBatch int
}

func newMemoryQueue(jobs []store.ClaimedJob) *memoryQueue {
	return &memoryQueue{
		pending:   append([]store.ClaimedJob(nil), jobs...),
		delivered: make(map[int64]struct{}, len(jobs)),
	}
}

func (q *memoryQueue) Claim(ctx context.Context, limit int, _ time.Duration) ([]store.ClaimedJob, error) {
	q.mutex.Lock()
	if len(q.pending) == 0 {
		q.mutex.Unlock()
		<-ctx.Done()
		return nil, ctx.Err()
	}
	if limit > len(q.pending) {
		limit = len(q.pending)
	}
	if limit > q.maximumBatch {
		q.maximumBatch = limit
	}
	claimed := append([]store.ClaimedJob(nil), q.pending[:limit]...)
	q.pending = q.pending[limit:]
	q.mutex.Unlock()
	return claimed, nil
}

func (q *memoryQueue) MarkDelivered(_ context.Context, jobID int64, _ string) error {
	q.mutex.Lock()
	defer q.mutex.Unlock()
	q.delivered[jobID] = struct{}{}
	return nil
}

func (q *memoryQueue) Retry(context.Context, int64, string, string, time.Time, int) (store.RetryResult, error) {
	return store.RetryResult{}, errors.New("unexpected retry")
}

func (q *memoryQueue) MarkPermanent(context.Context, int64, string, string) error {
	return errors.New("unexpected permanent failure")
}

func (q *memoryQueue) RevokeInvalidToken(context.Context, int64, string) error {
	return errors.New("unexpected invalid token")
}

func (q *memoryQueue) Cleanup(context.Context, time.Duration) (int64, error) {
	return 0, nil
}

func (q *memoryQueue) deliveredCount() int {
	q.mutex.Lock()
	defer q.mutex.Unlock()
	return len(q.delivered)
}

func (q *memoryQueue) maximumClaimed() int {
	q.mutex.Lock()
	defer q.mutex.Unlock()
	return q.maximumBatch
}
