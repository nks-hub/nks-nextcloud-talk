package httpapi

import (
	"math"
	"strconv"
	"sync"
	"time"
)

const (
	maximumRateLimitKeys = 10000
	rateLimitIdleExpiry  = 10 * time.Minute
)

type rateLimitBucket struct {
	tokens   float64
	updated  time.Time
	lastSeen time.Time
}

type rateLimiter struct {
	mutex           sync.Mutex
	buckets         map[string]rateLimitBucket
	overflow        rateLimitBucket
	tokensPerSecond float64
	burst           float64
	now             func() time.Time
	calls           uint64
}

func newRateLimiter(perMinute, burst int, now func() time.Time) *rateLimiter {
	if now == nil {
		now = time.Now
	}
	current := now()
	return &rateLimiter{
		buckets:         make(map[string]rateLimitBucket),
		overflow:        rateLimitBucket{tokens: float64(burst), updated: current, lastSeen: current},
		tokensPerSecond: float64(perMinute) / 60,
		burst:           float64(burst),
		now:             now,
	}
}

func (l *rateLimiter) Allow(key string) (bool, string) {
	l.mutex.Lock()
	defer l.mutex.Unlock()
	current := l.now()
	l.calls++
	if l.calls%256 == 0 {
		l.prune(current)
	}

	bucket, exists := l.buckets[key]
	if !exists && len(l.buckets) >= maximumRateLimitKeys {
		allowed, retry := l.consume(l.overflow, current)
		l.overflow = retry.bucket
		return allowed, retry.after
	}
	if !exists {
		bucket = rateLimitBucket{tokens: l.burst, updated: current, lastSeen: current}
	}
	allowed, retry := l.consume(bucket, current)
	l.buckets[key] = retry.bucket
	return allowed, retry.after
}

type rateLimitResult struct {
	bucket rateLimitBucket
	after  string
}

func (l *rateLimiter) consume(bucket rateLimitBucket, current time.Time) (bool, rateLimitResult) {
	elapsed := current.Sub(bucket.updated).Seconds()
	if elapsed > 0 {
		bucket.tokens = math.Min(l.burst, bucket.tokens+elapsed*l.tokensPerSecond)
	}
	bucket.updated = current
	bucket.lastSeen = current
	if bucket.tokens >= 1 {
		bucket.tokens--
		return true, rateLimitResult{bucket: bucket, after: "0"}
	}
	seconds := int(math.Ceil((1 - bucket.tokens) / l.tokensPerSecond))
	if seconds < 1 {
		seconds = 1
	}
	if seconds > 86400 {
		seconds = 86400
	}
	return false, rateLimitResult{bucket: bucket, after: strconv.Itoa(seconds)}
}

func (l *rateLimiter) prune(current time.Time) {
	threshold := current.Add(-rateLimitIdleExpiry)
	for key, bucket := range l.buckets {
		if bucket.lastSeen.Before(threshold) {
			delete(l.buckets, key)
		}
	}
}
