package provider

import (
	"context"
	"time"
)

type Outcome string

const (
	OutcomeDelivered         Outcome = "delivered"
	OutcomeRetryTimeout      Outcome = "retry_timeout"
	OutcomeRetryRateLimited  Outcome = "retry_rate_limited"
	OutcomeRetryServer       Outcome = "retry_server"
	OutcomeInvalidToken      Outcome = "invalid_token"
	OutcomePermanentMessage  Outcome = "permanent_message"
	OutcomePermanentProvider Outcome = "permanent_provider"
)

type Delivery struct {
	Token     string
	Subject   string
	Signature string
	Priority  string
}

type Result struct {
	Outcome    Outcome
	RetryAfter time.Duration
}

func (r Result) Retryable() bool {
	return r.Outcome == OutcomeRetryTimeout ||
		r.Outcome == OutcomeRetryRateLimited ||
		r.Outcome == OutcomeRetryServer
}

type Sender interface {
	Send(context.Context, Delivery) Result
}
