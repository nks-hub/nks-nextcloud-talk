package provider

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
	"google.golang.org/api/option"
)

func TestFirebaseSendsOnlyOpaqueDataAndAndroidPriority(t *testing.T) {
	client := &recordingMessagingClient{}
	provider := newFirebase(client)
	delivery := validTestDelivery()

	result := provider.Send(context.Background(), delivery)

	if result.Outcome != OutcomeDelivered {
		t.Fatalf("outcome = %q, want %q", result.Outcome, OutcomeDelivered)
	}
	if client.message == nil {
		t.Fatal("Firebase client was not called")
	}
	wantData := map[string]string{
		"subject":   delivery.Subject,
		"signature": delivery.Signature,
	}
	if !reflect.DeepEqual(client.message.Data, wantData) {
		t.Fatalf("data = %#v, want %#v", client.message.Data, wantData)
	}
	if client.message.Token != delivery.Token {
		t.Fatalf("token = %q, want the supplied provider token", client.message.Token)
	}
	if client.message.Android == nil || client.message.Android.Priority != "high" {
		t.Fatalf("Android priority = %#v, want high", client.message.Android)
	}
	if client.message.Notification != nil || client.message.APNS != nil ||
		client.message.Webpush != nil || client.message.FCMOptions != nil ||
		client.message.Android.Data != nil || client.message.Android.Notification != nil {
		t.Fatal("message contains an unsupported downstream payload")
	}
}

func TestFirebaseRejectsInvalidDeliveryBeforeProviderCall(t *testing.T) {
	client := &recordingMessagingClient{}
	provider := newFirebase(client)
	delivery := validTestDelivery()
	delivery.Priority = "urgent"

	result := provider.Send(context.Background(), delivery)

	if result.Outcome != OutcomePermanentMessage {
		t.Fatalf("outcome = %q, want %q", result.Outcome, OutcomePermanentMessage)
	}
	if client.message != nil {
		t.Fatal("invalid delivery reached Firebase")
	}
}

func TestFirebaseClassifiesRealAdminSDKResponses(t *testing.T) {
	tests := []struct {
		name             string
		status           int
		platformCode     string
		messagingCode    string
		retryAfter       string
		wantOutcome      Outcome
		wantRetryAfter   time.Duration
		wantRequestCount int
	}{
		{
			name:             "success",
			status:           http.StatusOK,
			wantOutcome:      OutcomeDelivered,
			wantRequestCount: 1,
		},
		{
			name:             "unregistered",
			status:           http.StatusNotFound,
			platformCode:     "NOT_FOUND",
			messagingCode:    "UNREGISTERED",
			wantOutcome:      OutcomeInvalidToken,
			wantRequestCount: 1,
		},
		{
			name:             "FCM invalid argument is an invalid token",
			status:           http.StatusBadRequest,
			platformCode:     "INVALID_ARGUMENT",
			messagingCode:    "INVALID_ARGUMENT",
			wantOutcome:      OutcomeInvalidToken,
			wantRequestCount: 1,
		},
		{
			name:             "generic invalid argument is a message failure",
			status:           http.StatusBadRequest,
			platformCode:     "INVALID_ARGUMENT",
			wantOutcome:      OutcomePermanentMessage,
			wantRequestCount: 1,
		},
		{
			name:             "quota uses bounded retry after",
			status:           http.StatusTooManyRequests,
			platformCode:     "RESOURCE_EXHAUSTED",
			messagingCode:    "QUOTA_EXCEEDED",
			retryAfter:       "3600",
			wantOutcome:      OutcomeRetryRateLimited,
			wantRetryAfter:   maximumRetryAfter,
			wantRequestCount: 1,
		},
		{
			name:             "internal server error is retryable",
			status:           http.StatusInternalServerError,
			platformCode:     "INTERNAL",
			messagingCode:    "INTERNAL",
			wantOutcome:      OutcomeRetryServer,
			wantRequestCount: 1,
		},
		{
			name:             "unstructured bad gateway is retryable",
			status:           http.StatusBadGateway,
			wantOutcome:      OutcomeRetryServer,
			wantRequestCount: 1,
		},
		{
			name:             "provider request timeout is retryable",
			status:           http.StatusRequestTimeout,
			wantOutcome:      OutcomeRetryTimeout,
			wantRequestCount: 1,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			requestCount := 0
			server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
				requestCount++
				if request.Method != http.MethodPost || request.URL.Path != "/projects/test-project/messages:send" {
					t.Fatalf("unexpected Firebase request %s %s", request.Method, request.URL.Path)
				}
				response.Header().Set("Content-Type", "application/json")
				if test.retryAfter != "" {
					response.Header().Set("Retry-After", test.retryAfter)
				}
				response.WriteHeader(test.status)
				if test.status == http.StatusOK {
					_, _ = response.Write([]byte(`{"name":"projects/test-project/messages/1"}`))
					return
				}
				body := map[string]any{
					"error": map[string]any{
						"code":    test.status,
						"message": "redacted test failure",
						"status":  test.platformCode,
					},
				}
				if test.messagingCode != "" {
					body["error"].(map[string]any)["details"] = []map[string]string{{
						"@type":     "type.googleapis.com/google.firebase.fcm.v1.FcmError",
						"errorCode": test.messagingCode,
					}}
				}
				_ = json.NewEncoder(response).Encode(body)
			}))
			defer server.Close()

			client := adminSDKClient(t, server)
			result := newFirebase(client).Send(context.Background(), validTestDelivery())

			if result.Outcome != test.wantOutcome {
				t.Fatalf("outcome = %q, want %q", result.Outcome, test.wantOutcome)
			}
			if result.RetryAfter != test.wantRetryAfter {
				t.Fatalf("RetryAfter = %s, want %s", result.RetryAfter, test.wantRetryAfter)
			}
			if requestCount != test.wantRequestCount {
				t.Fatalf("request count = %d, want %d", requestCount, test.wantRequestCount)
			}
		})
	}
}

func TestFirebaseClassifiesContextTimeout(t *testing.T) {
	provider := newFirebase(messagingSenderFunc(func(ctx context.Context, _ *messaging.Message) (string, error) {
		<-ctx.Done()
		return "", ctx.Err()
	}))
	ctx, cancel := context.WithTimeout(context.Background(), time.Millisecond)
	defer cancel()

	result := provider.Send(ctx, validTestDelivery())

	if result.Outcome != OutcomeRetryTimeout {
		t.Fatalf("outcome = %q, want %q", result.Outcome, OutcomeRetryTimeout)
	}
}

func TestBoundedRetryAfterParsesHTTPDate(t *testing.T) {
	now := time.Date(2026, time.August, 23, 12, 0, 0, 0, time.UTC)
	response := &http.Response{Header: http.Header{
		"Retry-After": []string{now.Add(45 * time.Second).Format(http.TimeFormat)},
	}}

	if got := boundedRetryAfter(response, now); got != 45*time.Second {
		t.Fatalf("boundedRetryAfter() = %s, want 45s", got)
	}
}

func adminSDKClient(t *testing.T, server *httptest.Server) *messaging.Client {
	t.Helper()
	ctx := context.Background()
	app, err := firebase.NewApp(
		ctx,
		&firebase.Config{ProjectID: "test-project"},
		option.WithHTTPClient(server.Client()),
		option.WithEndpoint(server.URL),
	)
	if err != nil {
		t.Fatalf("firebase.NewApp() error = %v", err)
	}
	client, err := app.Messaging(ctx)
	if err != nil {
		t.Fatalf("App.Messaging() error = %v", err)
	}
	return client
}

func validTestDelivery() Delivery {
	return Delivery{
		Token:     "provider-token",
		Subject:   base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x42}, 256)),
		Signature: base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x24}, 256)),
		Priority:  "high",
	}
}

type recordingMessagingClient struct {
	message *messaging.Message
}

func (c *recordingMessagingClient) Send(_ context.Context, message *messaging.Message) (string, error) {
	c.message = message
	return "projects/test-project/messages/1", nil
}

type messagingSenderFunc func(context.Context, *messaging.Message) (string, error)

func (f messagingSenderFunc) Send(ctx context.Context, message *messaging.Message) (string, error) {
	return f(ctx, message)
}
