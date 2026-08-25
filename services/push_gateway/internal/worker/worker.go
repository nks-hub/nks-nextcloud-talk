package worker

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"sync"
	"sync/atomic"
	"time"

	"nks-nextcloud-talk/services/push_gateway/internal/cryptoidentity"
	"nks-nextcloud-talk/services/push_gateway/internal/provider"
	"nks-nextcloud-talk/services/push_gateway/internal/store"
)

const (
	pollInterval        = 250 * time.Millisecond
	cleanupInterval     = time.Hour
	minimumRetryDelay   = time.Second
	maximumRetryDelay   = 5 * time.Minute
	maximumAttempts     = 8
	minimumJitterFactor = 0.8
	jitterFactorRange   = 0.4
)

type Queue interface {
	Claim(context.Context, int, time.Duration) ([]store.ClaimedJob, error)
	MarkDelivered(context.Context, int64, string) error
	Retry(context.Context, int64, string, string, time.Time, int) (store.RetryResult, error)
	MarkPermanent(context.Context, int64, string, string) error
	RevokeInvalidToken(context.Context, int64, string) error
	Cleanup(context.Context, time.Duration) (int64, error)
}

type Config struct {
	WorkerCount     int
	ClaimSize       int
	LeaseDuration   time.Duration
	ProviderTimeout time.Duration
	ShutdownTimeout time.Duration
	DedupeRetention time.Duration
}

type Runner struct {
	config    Config
	queue     Queue
	cipher    *cryptoidentity.TokenCipher
	provider  provider.Sender
	now       func() time.Time
	random    func() float64
	afterAck  func()
	afterSave func()
	ready     atomic.Bool
	active    atomic.Int64
	outcomes  outcomeCounters
}

type MetricsSnapshot struct {
	Delivered         uint64
	RetryTimeout      uint64
	RetryRateLimited  uint64
	RetryServer       uint64
	InvalidToken      uint64
	PermanentMessage  uint64
	PermanentProvider uint64
	Active            int64
}

type outcomeCounters struct {
	delivered         atomic.Uint64
	retryTimeout      atomic.Uint64
	retryRateLimited  atomic.Uint64
	retryServer       atomic.Uint64
	invalidToken      atomic.Uint64
	permanentMessage  atomic.Uint64
	permanentProvider atomic.Uint64
}

func New(
	config Config,
	queue Queue,
	cipher *cryptoidentity.TokenCipher,
	providerSender provider.Sender,
) (*Runner, error) {
	if config.WorkerCount < 1 || config.WorkerCount > 64 ||
		config.ClaimSize < 1 || config.ClaimSize > 500 ||
		config.LeaseDuration <= 0 || config.ProviderTimeout <= 0 ||
		config.ShutdownTimeout <= config.ProviderTimeout ||
		config.ShutdownTimeout >= config.LeaseDuration ||
		config.DedupeRetention <= 0 || queue == nil || cipher == nil || providerSender == nil {
		return nil, errors.New("worker configuration is invalid")
	}
	return &Runner{
		config:   config,
		queue:    queue,
		cipher:   cipher,
		provider: providerSender,
		now:      time.Now,
		random:   rand.Float64,
	}, nil
}

func (r *Runner) Run(ctx context.Context) error {
	if ctx == nil {
		return errors.New("worker context is required")
	}
	if _, err := r.queue.Cleanup(ctx, r.config.DedupeRetention); err != nil {
		if ctx.Err() != nil {
			return nil
		}
		return fmt.Errorf("initial delivery cleanup failed: %w", err)
	}
	r.ready.Store(true)
	defer r.ready.Store(false)

	runContext, cancel := context.WithCancel(ctx)
	defer cancel()
	jobs := make(chan store.ClaimedJob)
	slots := make(chan struct{}, r.config.WorkerCount)
	for range r.config.WorkerCount {
		slots <- struct{}{}
	}
	errorsByRoutine := make(chan error, r.config.WorkerCount+1)
	processContext := context.WithoutCancel(ctx)

	var workers sync.WaitGroup
	for range r.config.WorkerCount {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for job := range jobs {
				jobContext, cancelJob := context.WithTimeout(processContext, r.config.ShutdownTimeout)
				err := r.process(jobContext, job)
				cancelJob()
				slots <- struct{}{}
				if err != nil {
					sendError(errorsByRoutine, err)
					cancel()
					return
				}
			}
		}()
	}

	var cleanup sync.WaitGroup
	cleanup.Add(1)
	go func() {
		defer cleanup.Done()
		if err := r.cleanupLoop(runContext); err != nil {
			sendError(errorsByRoutine, err)
			cancel()
		}
	}()

	dispatchError := r.dispatch(runContext, jobs, slots)
	close(jobs)
	workers.Wait()
	cancel()
	cleanup.Wait()
	close(errorsByRoutine)

	for routineError := range errorsByRoutine {
		if routineError != nil {
			return routineError
		}
	}
	if dispatchError != nil && ctx.Err() == nil {
		return dispatchError
	}
	return nil
}

func (r *Runner) dispatch(
	ctx context.Context,
	jobs chan<- store.ClaimedJob,
	slots chan struct{},
) error {
	for {
		capacity, ok := acquireSlots(ctx, slots, r.config.ClaimSize)
		if !ok {
			return nil
		}
		claimed, err := r.queue.Claim(ctx, capacity, r.config.LeaseDuration)
		if err != nil {
			releaseSlots(slots, capacity)
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("delivery claim failed: %w", err)
		}
		if len(claimed) > capacity {
			releaseSlots(slots, capacity)
			return errors.New("delivery claim exceeded requested capacity")
		}
		releaseSlots(slots, capacity-len(claimed))
		if len(claimed) == 0 {
			if !wait(ctx, pollInterval) {
				return nil
			}
			continue
		}

		for index, job := range claimed {
			select {
			case jobs <- job:
			case <-ctx.Done():
				releaseSlots(slots, len(claimed)-index)
				return nil
			}
		}
	}
}

func (r *Runner) process(ctx context.Context, job store.ClaimedJob) error {
	token, err := r.cipher.Decrypt(job.EncryptedToken, job.DeviceIdentifier)
	if err != nil {
		return r.queue.MarkPermanent(ctx, job.ID, job.LeaseID, "token_decryption")
	}
	sendContext, cancel := context.WithTimeout(ctx, r.config.ProviderTimeout)
	r.active.Add(1)
	result := r.provider.Send(sendContext, provider.Delivery{
		Token:     token,
		Subject:   job.Subject,
		Signature: job.Signature,
		Priority:  job.Priority,
	})
	r.active.Add(-1)
	cancel()
	token = ""
	r.observe(result.Outcome)

	switch {
	case result.Outcome == provider.OutcomeDelivered:
		if r.afterAck != nil {
			r.afterAck()
		}
		if err := r.queue.MarkDelivered(ctx, job.ID, job.LeaseID); err != nil {
			return err
		}
		if r.afterSave != nil {
			r.afterSave()
		}
		return nil
	case result.Outcome == provider.OutcomeInvalidToken:
		return r.queue.RevokeInvalidToken(ctx, job.ID, job.LeaseID)
	case result.Retryable():
		delay := retryDelay(job.Attempt, result.RetryAfter, r.random())
		_, err := r.queue.Retry(
			ctx,
			job.ID,
			job.LeaseID,
			string(result.Outcome),
			r.now().Add(delay),
			maximumAttempts,
		)
		return err
	case result.Outcome == provider.OutcomePermanentMessage ||
		result.Outcome == provider.OutcomePermanentProvider:
		return r.queue.MarkPermanent(ctx, job.ID, job.LeaseID, string(result.Outcome))
	default:
		return errors.New("provider returned an unknown delivery outcome")
	}
}

func (r *Runner) Ready() bool {
	return r != nil && r.ready.Load()
}

func (r *Runner) Metrics() MetricsSnapshot {
	if r == nil {
		return MetricsSnapshot{}
	}
	return MetricsSnapshot{
		Delivered:         r.outcomes.delivered.Load(),
		RetryTimeout:      r.outcomes.retryTimeout.Load(),
		RetryRateLimited:  r.outcomes.retryRateLimited.Load(),
		RetryServer:       r.outcomes.retryServer.Load(),
		InvalidToken:      r.outcomes.invalidToken.Load(),
		PermanentMessage:  r.outcomes.permanentMessage.Load(),
		PermanentProvider: r.outcomes.permanentProvider.Load(),
		Active:            r.active.Load(),
	}
}

func (r *Runner) observe(outcome provider.Outcome) {
	switch outcome {
	case provider.OutcomeDelivered:
		r.outcomes.delivered.Add(1)
	case provider.OutcomeRetryTimeout:
		r.outcomes.retryTimeout.Add(1)
	case provider.OutcomeRetryRateLimited:
		r.outcomes.retryRateLimited.Add(1)
	case provider.OutcomeRetryServer:
		r.outcomes.retryServer.Add(1)
	case provider.OutcomeInvalidToken:
		r.outcomes.invalidToken.Add(1)
	case provider.OutcomePermanentMessage:
		r.outcomes.permanentMessage.Add(1)
	case provider.OutcomePermanentProvider:
		r.outcomes.permanentProvider.Add(1)
	}
}

func (r *Runner) cleanupLoop(ctx context.Context) error {
	ticker := time.NewTicker(cleanupInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			if _, err := r.queue.Cleanup(ctx, r.config.DedupeRetention); err != nil {
				if ctx.Err() != nil {
					return nil
				}
				return fmt.Errorf("delivery cleanup failed: %w", err)
			}
		}
	}
}

func retryDelay(attempt int, retryAfter time.Duration, random float64) time.Duration {
	delay := minimumRetryDelay
	for current := 1; current < attempt && delay < maximumRetryDelay; current++ {
		if delay > maximumRetryDelay/2 {
			delay = maximumRetryDelay
			break
		}
		delay *= 2
	}
	if random < 0 {
		random = 0
	} else if random > 1 {
		random = 1
	}
	delay = time.Duration(float64(delay) * (minimumJitterFactor + random*jitterFactorRange))
	if delay > maximumRetryDelay {
		delay = maximumRetryDelay
	}
	if retryAfter > delay {
		delay = retryAfter
	}
	if delay > maximumRetryDelay {
		return maximumRetryDelay
	}
	return delay
}

func acquireSlots(ctx context.Context, slots <-chan struct{}, maximum int) (int, bool) {
	select {
	case <-ctx.Done():
		return 0, false
	case <-slots:
	}
	count := 1
	for count < maximum {
		select {
		case <-slots:
			count++
		default:
			return count, true
		}
	}
	return count, true
}

func releaseSlots(slots chan<- struct{}, count int) {
	for range count {
		slots <- struct{}{}
	}
}

func wait(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func sendError(destination chan<- error, err error) {
	select {
	case destination <- err:
	default:
	}
}
