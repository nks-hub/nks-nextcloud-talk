package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"nks-nextcloud-talk/services/push_gateway/internal/cryptoidentity"
	"nks-nextcloud-talk/services/push_gateway/internal/store"
)

func TestContractFixturesThroughRealHTTPWire(t *testing.T) {
	repository := newRecordingRepository()
	api := newTestAPI(t, repository, &recordingVerifier{})

	registrationValues := fixtureForm(t, "devices-register-success.request.json")
	registrationResponse := performRequest(api, formRequest(http.MethodPost, "/devices", registrationValues))
	assertStatus(t, registrationResponse, http.StatusOK)
	if registrationResponse.Body.Len() != 0 {
		t.Fatalf("registration response body = %q, want empty", registrationResponse.Body.String())
	}
	assertRequestID(t, registrationResponse)

	successResponse := performRequest(
		api,
		formRequest(http.MethodPost, "/notifications", notificationFixtureForm(t, "notifications-success.request.json")),
	)
	assertStatus(t, successResponse, http.StatusOK)
	assertJSONFixture(t, successResponse, "notifications-success.response.json")

	partialResponse := performRequest(
		api,
		formRequest(http.MethodPost, "/notifications", notificationFixtureForm(t, "notifications-partial.request.json")),
	)
	assertStatus(t, partialResponse, http.StatusOK)
	assertJSONFixture(t, partialResponse, "notifications-partial.response.json")

	unregistrationValues := fixtureForm(t, "devices-unregister.request.json")
	unregistration := httptest.NewRequest(http.MethodDelete, "/devices?"+unregistrationValues.Encode(), nil)
	unregistration.RemoteAddr = "192.0.2.10:40000"
	unregistrationResponse := performRequest(api, unregistration)
	assertStatus(t, unregistrationResponse, http.StatusOK)
	if unregistrationResponse.Body.Len() != 0 {
		t.Fatalf("unregistration response body = %q, want empty", unregistrationResponse.Body.String())
	}
}

func TestDeviceRegistrationRejectsMalformedWireWithoutSecretDisclosure(t *testing.T) {
	repository := newRecordingRepository()
	api := newTestAPI(t, repository, &recordingVerifier{})

	invalid := fixtureForm(t, "devices-register-invalid.request.json")
	response := performRequest(api, formRequest(http.MethodPost, "/devices", invalid))
	assertProblem(t, response, http.StatusBadRequest, "INVALID_DEVICE_IDENTITY")

	duplicate := fixtureForm(t, "devices-register-success.request.json")
	secret := duplicate.Get("pushToken")
	duplicate.Add("pushToken", secret)
	response = performRequest(api, formRequest(http.MethodPost, "/devices", duplicate))
	assertProblem(t, response, http.StatusBadRequest, "INVALID_DEVICE_IDENTITY")
	if strings.Contains(response.Body.String(), secret) {
		t.Fatal("problem response disclosed the provider token")
	}

	unknown := fixtureForm(t, "devices-register-success.request.json")
	unknown.Set("unexpected", "value")
	response = performRequest(api, formRequest(http.MethodPost, "/devices", unknown))
	assertProblem(t, response, http.StatusBadRequest, "INVALID_DEVICE_IDENTITY")

	wrongMediaType := httptest.NewRequest(http.MethodPost, "/devices", strings.NewReader(unknown.Encode()))
	wrongMediaType.Header.Set("Content-Type", "application/json")
	wrongMediaType.RemoteAddr = "192.0.2.11:40000"
	response = performRequest(api, wrongMediaType)
	assertProblem(t, response, http.StatusBadRequest, "INVALID_FORM")

	oversized := httptest.NewRequest(
		http.MethodPost,
		"/devices",
		strings.NewReader("pushToken="+strings.Repeat("a", int(deviceBodyMaximum))),
	)
	oversized.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	oversized.RemoteAddr = "192.0.2.12:40000"
	response = performRequest(api, oversized)
	assertProblem(t, response, http.StatusRequestEntityTooLarge, "PAYLOAD_TOO_LARGE")
}

func TestRegistrationConflictRecoveryRequiresVerifiedCloudIdentity(t *testing.T) {
	repository := newRecordingRepository()
	repository.conflictsRemaining = 1
	verifier := &recordingVerifier{}
	api := newTestAPI(t, repository, verifier)
	response := performRequest(
		api,
		formRequest(http.MethodPost, "/devices", fixtureForm(t, "devices-register-recovery.request.json")),
	)
	assertStatus(t, response, http.StatusOK)
	if verifier.calls != 1 || len(repository.registerCalls) != 2 || !repository.registerCalls[1].RecoveryVerified {
		t.Fatalf(
			"recovery calls verifier=%d register=%d recovered=%v",
			verifier.calls,
			len(repository.registerCalls),
			len(repository.registerCalls) == 2 && repository.registerCalls[1].RecoveryVerified,
		)
	}

	repository = newRecordingRepository()
	repository.conflictsRemaining = 1
	verifier = &recordingVerifier{err: errors.New("proof unavailable")}
	api = newTestAPI(t, repository, verifier)
	response = performRequest(
		api,
		formRequest(http.MethodPost, "/devices", fixtureForm(t, "devices-register-recovery.request.json")),
	)
	assertProblem(t, response, http.StatusForbidden, "IDENTITY_PROOF_FAILED")
	if len(repository.registerCalls) != 1 {
		t.Fatalf("failed proof performed %d registration writes, want 1 conflict check", len(repository.registerCalls))
	}

	repository = newRecordingRepository()
	repository.conflictsRemaining = 1
	api = newTestAPI(t, repository, &recordingVerifier{})
	response = performRequest(
		api,
		formRequest(http.MethodPost, "/devices", fixtureForm(t, "devices-register-success.request.json")),
	)
	assertProblem(t, response, http.StatusConflict, "TOKEN_IDENTITY_CONFLICT")
}

func TestDeviceUnregistrationRequiresEquivalentQueryAndBody(t *testing.T) {
	repository := newRecordingRepository()
	api := newTestAPI(t, repository, &recordingVerifier{})
	registration := fixtureForm(t, "devices-register-success.request.json")
	assertStatus(t, performRequest(api, formRequest(http.MethodPost, "/devices", registration)), http.StatusOK)

	query := fixtureForm(t, "devices-unregister.request.json")
	body := cloneValues(query)
	body.Set("deviceIdentifierSignature", strings.Repeat("A", 342)+"==")
	request := httptest.NewRequest(
		http.MethodDelete,
		"/devices?"+query.Encode(),
		strings.NewReader(body.Encode()),
	)
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.RemoteAddr = "192.0.2.13:40000"
	response := performRequest(api, request)
	assertProblem(t, response, http.StatusBadRequest, "INVALID_DEVICE_IDENTITY")

	request = httptest.NewRequest(
		http.MethodDelete,
		"/devices?"+query.Encode(),
		strings.NewReader(query.Encode()),
	)
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
	request.RemoteAddr = "192.0.2.13:40001"
	response = performRequest(api, request)
	assertStatus(t, response, http.StatusOK)
}

func TestNotificationBatchRejectsSparseFormAndClassifiesMalformedEnvelope(t *testing.T) {
	repository := newRecordingRepository()
	api := newTestAPI(t, repository, &recordingVerifier{})

	sparse := url.Values{"notifications[1]": []string{`{"deviceIdentifier":"invalid"}`}}
	response := performRequest(api, formRequest(http.MethodPost, "/notifications", sparse))
	assertProblem(t, response, http.StatusBadRequest, "INVALID_NOTIFICATION_BATCH")

	duplicateJSONKey := url.Values{
		"notifications[0]": []string{`{"deviceIdentifier":"first","deviceIdentifier":"second"}`},
	}
	response = performRequest(api, formRequest(http.MethodPost, "/notifications", duplicateJSONKey))
	assertStatus(t, response, http.StatusOK)
	var result notificationsResponse
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatalf("decode malformed-envelope response: %v", err)
	}
	if result.Failed != 1 || len(result.Unknown) != 0 {
		t.Fatalf("malformed-envelope response = %+v", result)
	}
}

func TestNotificationQueueBackpressureIsTruthful(t *testing.T) {
	repository := newRecordingRepository()
	api := newTestAPI(t, repository, &recordingVerifier{})
	assertStatus(
		t,
		performRequest(api, formRequest(http.MethodPost, "/devices", fixtureForm(t, "devices-register-success.request.json"))),
		http.StatusOK,
	)
	repository.queueFull = true
	response := performRequest(
		api,
		formRequest(http.MethodPost, "/notifications", notificationFixtureForm(t, "notifications-success.request.json")),
	)
	assertProblem(t, response, http.StatusTooManyRequests, "QUEUE_FULL")
	if response.Header().Get("Retry-After") != "30" {
		t.Fatalf("Retry-After = %q, want 30", response.Header().Get("Retry-After"))
	}
}

func TestRateLimiterRefillsDeterministically(t *testing.T) {
	current := time.Date(2026, 8, 23, 12, 0, 0, 0, time.UTC)
	limiter := newRateLimiter(60, 1, func() time.Time { return current })
	if allowed, _ := limiter.Allow("192.0.2.1"); !allowed {
		t.Fatal("first request was rate limited")
	}
	if allowed, retryAfter := limiter.Allow("192.0.2.1"); allowed || retryAfter != "1" {
		t.Fatalf("second request allowed=%v retry=%q", allowed, retryAfter)
	}
	current = current.Add(time.Second)
	if allowed, _ := limiter.Allow("192.0.2.1"); !allowed {
		t.Fatal("refilled request was rate limited")
	}
}

func TestHTTPIngressRejectsWorkBeyondConcurrencyLimit(t *testing.T) {
	repository := &blockingRepository{
		recordingRepository: newRecordingRepository(),
		entered:             make(chan struct{}, 2),
		release:             make(chan struct{}),
	}
	api := newTestAPIWithConcurrency(t, repository, &recordingVerifier{}, 2)
	responses := make(chan *httptest.ResponseRecorder, 2)
	registration := fixtureForm(t, "devices-register-success.request.json")
	for range 2 {
		go func() {
			responses <- performRequest(
				api,
				formRequest(http.MethodPost, "/devices", registration),
			)
		}()
	}
	for range 2 {
		select {
		case <-repository.entered:
		case <-time.After(2 * time.Second):
			t.Fatal("concurrent request did not reach the bounded repository call")
		}
	}

	overloaded := performRequest(
		api,
		formRequest(http.MethodPost, "/devices", registration),
	)
	assertProblem(t, overloaded, http.StatusServiceUnavailable, "GATEWAY_BUSY")
	if overloaded.Header().Get("Retry-After") != "1" {
		t.Fatalf("Retry-After = %q, want 1", overloaded.Header().Get("Retry-After"))
	}
	close(repository.release)
	for range 2 {
		assertStatus(t, <-responses, http.StatusOK)
	}
}

type recordingRepository struct {
	mutex              sync.Mutex
	registrations      map[string]store.Registration
	registerCalls      []store.RegistrationMutation
	queued             []store.Notification
	conflictsRemaining int
	queueFull          bool
}

func newRecordingRepository() *recordingRepository {
	return &recordingRepository{registrations: make(map[string]store.Registration)}
}

func (r *recordingRepository) Register(
	_ context.Context,
	mutation store.RegistrationMutation,
) (store.Registration, error) {
	r.mutex.Lock()
	defer r.mutex.Unlock()
	r.registerCalls = append(r.registerCalls, mutation)
	if r.conflictsRemaining > 0 {
		r.conflictsRemaining--
		return store.Registration{}, store.ErrTokenConflict
	}
	generation := int64(1)
	if existing, found := r.registrations[mutation.DeviceIdentifier]; found {
		generation = existing.Generation
	}
	registration := store.Registration{
		DeviceIdentifier:     mutation.DeviceIdentifier,
		DeviceSignature:      mutation.DeviceSignature,
		PublicKeyPEM:         mutation.PublicKeyPEM,
		PublicKeyDER:         append([]byte(nil), mutation.PublicKeyDER...),
		PublicKeyFingerprint: append([]byte(nil), mutation.PublicKeyFingerprint...),
		TokenHash:            mutation.TokenHash,
		EncryptedToken:       mutation.EncryptedToken,
		Generation:           generation,
	}
	r.registrations[mutation.DeviceIdentifier] = registration
	return registration, nil
}

func (r *recordingRepository) Unregister(_ context.Context, deviceIdentifier string, _ []byte) error {
	r.mutex.Lock()
	defer r.mutex.Unlock()
	delete(r.registrations, deviceIdentifier)
	return nil
}

func (r *recordingRepository) Registrations(
	_ context.Context,
	deviceIdentifiers []string,
) (map[string]store.Registration, error) {
	r.mutex.Lock()
	defer r.mutex.Unlock()
	result := make(map[string]store.Registration)
	for _, deviceIdentifier := range deviceIdentifiers {
		if registration, found := r.registrations[deviceIdentifier]; found {
			result[deviceIdentifier] = registration
		}
	}
	return result, nil
}

func (r *recordingRepository) Enqueue(
	_ context.Context,
	notifications []store.Notification,
) ([]store.EnqueueOutcome, error) {
	r.mutex.Lock()
	defer r.mutex.Unlock()
	if r.queueFull {
		return nil, store.ErrQueueFull
	}
	r.queued = append(r.queued, notifications...)
	outcomes := make([]store.EnqueueOutcome, len(notifications))
	for index := range outcomes {
		outcomes[index].Accepted = true
	}
	return outcomes, nil
}

type recordingVerifier struct {
	mutex sync.Mutex
	calls int
	err   error
}

func (v *recordingVerifier) Verify(
	_ context.Context,
	_ string,
	_ cryptoidentity.PublicIdentity,
) error {
	v.mutex.Lock()
	defer v.mutex.Unlock()
	v.calls++
	return v.err
}

func newTestAPI(t *testing.T, repository Repository, verifier IdentityVerifier) *API {
	return newTestAPIWithConcurrency(t, repository, verifier, 0)
}

func newTestAPIWithConcurrency(
	t *testing.T,
	repository Repository,
	verifier IdentityVerifier,
	maximumConcurrentRequests int,
) *API {
	t.Helper()
	cipher, err := cryptoidentity.NewTokenCipher(bytes.Repeat([]byte{0x42}, cryptoidentity.TokenEncryptionKeyLength))
	if err != nil {
		t.Fatalf("NewTokenCipher() error = %v", err)
	}
	api, err := New(Config{
		Repository:                repository,
		IdentityVerifier:          verifier,
		TokenCipher:               cipher,
		RateLimitPerMinute:        100000,
		RateLimitBurst:            100000,
		MaximumConcurrentRequests: maximumConcurrentRequests,
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	return api
}

type blockingRepository struct {
	*recordingRepository
	entered chan struct{}
	release chan struct{}
}

func (r *blockingRepository) Register(
	ctx context.Context,
	mutation store.RegistrationMutation,
) (store.Registration, error) {
	r.entered <- struct{}{}
	select {
	case <-ctx.Done():
		return store.Registration{}, ctx.Err()
	case <-r.release:
		return r.recordingRepository.Register(ctx, mutation)
	}
}

func formRequest(method, path string, values url.Values) *http.Request {
	request := httptest.NewRequest(method, path, strings.NewReader(values.Encode()))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.RemoteAddr = "192.0.2.10:40000"
	return request
}

func performRequest(handler http.Handler, request *http.Request) *httptest.ResponseRecorder {
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	return recorder
}

func fixtureForm(t *testing.T, name string) url.Values {
	t.Helper()
	fixture := fixtureObject(t, name)
	values := make(url.Values)
	for name, rawValue := range fixture {
		value, ok := rawValue.(string)
		if !ok {
			t.Fatalf("fixture field %s is %T, want string", name, rawValue)
		}
		values.Set(name, value)
	}
	return values
}

func notificationFixtureForm(t *testing.T, name string) url.Values {
	t.Helper()
	fixture := fixtureObject(t, name)
	rawNotifications, ok := fixture["notifications"].([]any)
	if !ok {
		t.Fatalf("fixture notifications is %T, want array", fixture["notifications"])
	}
	values := make(url.Values, len(rawNotifications))
	for index, rawNotification := range rawNotifications {
		notification, ok := rawNotification.(string)
		if !ok {
			t.Fatalf("fixture notification %d is %T, want string", index, rawNotification)
		}
		values.Set("notifications["+strconv.Itoa(index)+"]", notification)
	}
	return values
}

func fixtureObject(t *testing.T, name string) map[string]any {
	t.Helper()
	path := filepath.Join("..", "..", "..", "..", "contracts", "push-gateway", "fixtures", name)
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	var value map[string]any
	if err := json.Unmarshal(body, &value); err != nil {
		t.Fatalf("decode fixture %s: %v", name, err)
	}
	return value
}

func assertStatus(t *testing.T, response *httptest.ResponseRecorder, expected int) {
	t.Helper()
	if response.Code != expected {
		t.Fatalf("response status = %d, want %d; body=%s", response.Code, expected, response.Body.String())
	}
}

func assertRequestID(t *testing.T, response *httptest.ResponseRecorder) {
	t.Helper()
	value := response.Header().Get("X-Request-Id")
	if !requestIDPattern.MatchString(value) {
		t.Fatalf("X-Request-Id = %q", value)
	}
}

func assertProblem(t *testing.T, response *httptest.ResponseRecorder, status int, code string) {
	t.Helper()
	assertStatus(t, response, status)
	if mediaType := response.Header().Get("Content-Type"); mediaType != "application/problem+json" {
		t.Fatalf("problem Content-Type = %q", mediaType)
	}
	var problem problemDetails
	if err := json.Unmarshal(response.Body.Bytes(), &problem); err != nil {
		t.Fatalf("decode problem response: %v", err)
	}
	if problem.Status != status || problem.Code != code || !requestIDPattern.MatchString(problem.RequestID) {
		t.Fatalf("problem response = %+v", problem)
	}
}

func assertJSONFixture(t *testing.T, response *httptest.ResponseRecorder, fixtureName string) {
	t.Helper()
	actual := make(map[string]any)
	if err := json.Unmarshal(response.Body.Bytes(), &actual); err != nil {
		t.Fatalf("decode HTTP response: %v", err)
	}
	expected := fixtureObject(t, fixtureName)
	if !reflect.DeepEqual(actual, expected) {
		t.Fatalf("response = %#v, want %#v", actual, expected)
	}
}

func cloneValues(values url.Values) url.Values {
	clone := make(url.Values, len(values))
	for name, fieldValues := range values {
		clone[name] = append([]string(nil), fieldValues...)
	}
	return clone
}
