package provider

import (
	"context"
	"encoding/base64"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/errorutils"
	"firebase.google.com/go/v4/messaging"

	"nks-nextcloud-talk/services/push_gateway/internal/cryptoidentity"
)

const maximumRetryAfter = 2 * time.Minute

type messagingSender interface {
	Send(context.Context, *messaging.Message) (string, error)
}

type Firebase struct {
	client messagingSender
	now    func() time.Time
}

func NewFirebase(ctx context.Context, projectID string) (*Firebase, error) {
	if strings.TrimSpace(projectID) == "" || strings.TrimSpace(projectID) != projectID {
		return nil, errors.New("Firebase project ID is invalid")
	}
	app, err := firebase.NewApp(ctx, &firebase.Config{ProjectID: projectID})
	if err != nil {
		return nil, errors.New("Firebase application could not initialize")
	}
	client, err := app.Messaging(ctx)
	if err != nil {
		return nil, errors.New("Firebase messaging client could not initialize")
	}
	return newFirebase(client), nil
}

func newFirebase(client messagingSender) *Firebase {
	return &Firebase{client: client, now: time.Now}
}

func (f *Firebase) Send(ctx context.Context, delivery Delivery) Result {
	if f == nil || f.client == nil || !validDelivery(delivery) {
		return Result{Outcome: OutcomePermanentMessage}
	}
	message := &messaging.Message{
		Token: delivery.Token,
		Data: map[string]string{
			"subject":   delivery.Subject,
			"signature": delivery.Signature,
		},
		Android: &messaging.AndroidConfig{Priority: delivery.Priority},
	}
	_, err := f.client.Send(ctx, message)
	if err == nil {
		return Result{Outcome: OutcomeDelivered}
	}
	return f.classify(ctx, err)
}

func (f *Firebase) classify(ctx context.Context, err error) Result {
	response := errorutils.HTTPResponse(err)
	retryAfter := boundedRetryAfter(response, f.now())
	if ctx.Err() != nil || errors.Is(err, context.DeadlineExceeded) ||
		errorutils.IsDeadlineExceeded(err) || responseStatus(response) == http.StatusRequestTimeout {
		return Result{Outcome: OutcomeRetryTimeout, RetryAfter: retryAfter}
	}
	if messaging.IsUnregistered(err) || messaging.IsInvalidArgument(err) {
		return Result{Outcome: OutcomeInvalidToken}
	}
	if messaging.IsQuotaExceeded(err) || errorutils.IsResourceExhausted(err) ||
		responseStatus(response) == http.StatusTooManyRequests {
		return Result{Outcome: OutcomeRetryRateLimited, RetryAfter: retryAfter}
	}
	if messaging.IsUnavailable(err) || messaging.IsInternal(err) ||
		errorutils.IsUnavailable(err) || errorutils.IsInternal(err) || errorutils.IsUnknown(err) ||
		responseStatus(response) >= http.StatusInternalServerError {
		return Result{Outcome: OutcomeRetryServer, RetryAfter: retryAfter}
	}
	if errorutils.IsInvalidArgument(err) {
		return Result{Outcome: OutcomePermanentMessage}
	}
	return Result{Outcome: OutcomePermanentProvider}
}

func responseStatus(response *http.Response) int {
	if response == nil {
		return 0
	}
	return response.StatusCode
}

func validDelivery(delivery Delivery) bool {
	_, tokenError := cryptoidentity.TokenHash(delivery.Token)
	return tokenError == nil &&
		validOpaqueField(delivery.Subject, cryptoidentity.EncryptedSubjectEncodedLength) &&
		validOpaqueField(delivery.Signature, cryptoidentity.SignatureEncodedLength) &&
		(delivery.Priority == "high" || delivery.Priority == "normal")
}

func validOpaqueField(value string, encodedLength int) bool {
	if len(value) != encodedLength {
		return false
	}
	decoded, err := base64.StdEncoding.Strict().DecodeString(value)
	return err == nil && len(decoded) == 256 && base64.StdEncoding.EncodeToString(decoded) == value
}

func boundedRetryAfter(response *http.Response, now time.Time) time.Duration {
	if response == nil {
		return 0
	}
	raw := strings.TrimSpace(response.Header.Get("Retry-After"))
	if raw == "" {
		return 0
	}
	var delay time.Duration
	if seconds, err := strconv.ParseInt(raw, 10, 64); err == nil {
		if seconds <= 0 {
			return 0
		}
		delay = time.Duration(seconds) * time.Second
	} else if timestamp, err := http.ParseTime(raw); err == nil {
		delay = timestamp.Sub(now)
	}
	if delay <= 0 {
		return 0
	}
	if delay > maximumRetryAfter {
		return maximumRetryAfter
	}
	return delay
}
