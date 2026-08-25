package httpapi

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"regexp"
	"strings"
	"time"

	"nks-nextcloud-talk/services/push_gateway/internal/cryptoidentity"
	"nks-nextcloud-talk/services/push_gateway/internal/identityproof"
	"nks-nextcloud-talk/services/push_gateway/internal/store"
	"nks-nextcloud-talk/services/push_gateway/internal/strictjson"
)

const (
	deviceBodyMaximum                = int64(32 * 1024)
	notificationBodyMaximum          = int64(16 * 1024 * 1024)
	notificationMaximum              = 1000
	notificationMaximumSize          = 8192
	defaultMaximumConcurrentRequests = 256
	maximumConcurrentRequestsLimit   = 4096
)

var requestIDPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)

type Repository interface {
	Register(context.Context, store.RegistrationMutation) (store.Registration, error)
	Unregister(context.Context, string, []byte) error
	Registrations(context.Context, []string) (map[string]store.Registration, error)
	Enqueue(context.Context, []store.Notification) ([]store.EnqueueOutcome, error)
}

type IdentityVerifier interface {
	Verify(context.Context, string, cryptoidentity.PublicIdentity) error
}

type Config struct {
	Repository                Repository
	IdentityVerifier          IdentityVerifier
	TokenCipher               *cryptoidentity.TokenCipher
	Logger                    *slog.Logger
	RateLimitPerMinute        int
	RateLimitBurst            int
	MaximumConcurrentRequests int
	Now                       func() time.Time
}

type API struct {
	repository       Repository
	identityVerifier IdentityVerifier
	tokenCipher      *cryptoidentity.TokenCipher
	logger           *slog.Logger
	limiter          *rateLimiter
	concurrency      chan struct{}
	mux              *http.ServeMux
}

func New(config Config) (*API, error) {
	maximumConcurrentRequests := config.MaximumConcurrentRequests
	if maximumConcurrentRequests == 0 {
		maximumConcurrentRequests = defaultMaximumConcurrentRequests
	}
	if config.Repository == nil || config.IdentityVerifier == nil || config.TokenCipher == nil ||
		config.RateLimitPerMinute < 1 || config.RateLimitBurst < 1 ||
		config.RateLimitBurst > config.RateLimitPerMinute || maximumConcurrentRequests < 1 ||
		maximumConcurrentRequests > maximumConcurrentRequestsLimit {
		return nil, errors.New("HTTP API configuration is invalid")
	}
	logger := config.Logger
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	api := &API{
		repository:       config.Repository,
		identityVerifier: config.IdentityVerifier,
		tokenCipher:      config.TokenCipher,
		logger:           logger,
		limiter: newRateLimiter(
			config.RateLimitPerMinute,
			config.RateLimitBurst,
			config.Now,
		),
		concurrency: make(chan struct{}, maximumConcurrentRequests),
		mux:         http.NewServeMux(),
	}
	api.mux.HandleFunc("POST /devices", api.registerDevice)
	api.mux.HandleFunc("DELETE /devices", api.unregisterDevice)
	api.mux.HandleFunc("POST /notifications", api.deliverNotifications)
	return api, nil
}

func (a *API) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	requestID, err := newRequestID()
	if err != nil {
		http.Error(writer, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	writer.Header().Set("X-Request-Id", requestID)
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	writer.Header().Set("Cache-Control", "no-store")
	started := time.Now()
	recorder := &statusRecorder{ResponseWriter: writer, status: http.StatusOK}
	request = request.WithContext(context.WithValue(request.Context(), requestIDKey{}, requestID))
	select {
	case a.concurrency <- struct{}{}:
		defer func() { <-a.concurrency }()
		a.mux.ServeHTTP(recorder, request)
	default:
		writer.Header().Set("Retry-After", "1")
		writeProblem(
			recorder,
			request,
			http.StatusServiceUnavailable,
			"GATEWAY_BUSY",
			"Gateway busy",
			"The gateway has reached its concurrent request limit.",
		)
	}
	a.logger.InfoContext(
		request.Context(),
		"request completed",
		"request_id", requestID,
		"method", request.Method,
		"endpoint", endpointTemplate(request.URL.Path),
		"status_class", recorder.status/100,
		"duration_ms", time.Since(started).Milliseconds(),
	)
}

func (a *API) registerDevice(writer http.ResponseWriter, request *http.Request) {
	if !a.allow(writer, request) {
		return
	}
	values, readErr := readRequiredForm(writer, request, deviceBodyMaximum)
	if readErr != nil {
		a.writeFormError(writer, request, readErr)
		return
	}
	fields, err := exactFields(values, []string{
		"pushToken",
		"deviceIdentifier",
		"deviceIdentifierSignature",
		"userPublicKey",
	}, []string{"cloudId"})
	if err != nil || request.URL.RawQuery != "" || (values.Has("cloudId") && fields["cloudId"] == "") {
		writeProblem(writer, request, http.StatusBadRequest, "INVALID_DEVICE_IDENTITY", "Invalid device identity", "Registration fields or the cryptographic signature are invalid.")
		return
	}
	identity, err := cryptoidentity.ParsePublicIdentity(fields["userPublicKey"])
	if err != nil || cryptoidentity.VerifyDeviceIdentity(
		fields["deviceIdentifier"],
		fields["deviceIdentifierSignature"],
		identity,
	) != nil {
		writeProblem(writer, request, http.StatusBadRequest, "INVALID_DEVICE_IDENTITY", "Invalid device identity", "Registration fields or the cryptographic signature are invalid.")
		return
	}
	if cloudID := fields["cloudId"]; cloudID != "" {
		if _, err := identityproof.ParseCloudID(cloudID); err != nil {
			writeProblem(writer, request, http.StatusBadRequest, "INVALID_CLOUD_ID", "Invalid cloud identity", "The recovery identity is invalid.")
			return
		}
	}
	tokenHash, err := cryptoidentity.TokenHash(fields["pushToken"])
	if err != nil {
		writeProblem(writer, request, http.StatusBadRequest, "INVALID_DEVICE_IDENTITY", "Invalid device identity", "Registration fields or the cryptographic signature are invalid.")
		return
	}
	encryptedToken, err := a.tokenCipher.Encrypt(fields["pushToken"], fields["deviceIdentifier"])
	if err != nil {
		writeProblem(writer, request, http.StatusInternalServerError, "INTERNAL_ERROR", "Internal gateway error", "The operation could not be completed.")
		return
	}
	mutation := store.RegistrationMutation{
		DeviceIdentifier:     fields["deviceIdentifier"],
		DeviceSignature:      fields["deviceIdentifierSignature"],
		PublicKeyPEM:         identity.CanonicalPEM,
		PublicKeyDER:         identity.DER,
		PublicKeyFingerprint: identity.Fingerprint[:],
		TokenHash:            tokenHash,
		EncryptedToken:       encryptedToken,
	}
	_, err = a.repository.Register(request.Context(), mutation)
	if errors.Is(err, store.ErrTokenConflict) && fields["cloudId"] != "" {
		if verifyErr := a.identityVerifier.Verify(request.Context(), fields["cloudId"], identity); verifyErr != nil {
			writeProblem(writer, request, http.StatusForbidden, "IDENTITY_PROOF_FAILED", "Identity proof failed", "The public identity proof could not verify this registration.")
			return
		}
		mutation.RecoveryVerified = true
		_, err = a.repository.Register(request.Context(), mutation)
	}
	switch {
	case err == nil:
		writer.WriteHeader(http.StatusOK)
	case errors.Is(err, store.ErrTokenConflict):
		writeProblem(writer, request, http.StatusConflict, "TOKEN_IDENTITY_CONFLICT", "Push token identity conflict", "Retry with cloudId so the gateway can verify the public identity proof.")
	case errors.Is(err, store.ErrIdentityForbidden):
		writeProblem(writer, request, http.StatusForbidden, "IDENTITY_FORBIDDEN", "Registration identity forbidden", "The verified identity may not replace this registration.")
	case errors.Is(err, store.ErrInvalidMutation):
		writeProblem(writer, request, http.StatusBadRequest, "INVALID_DEVICE_IDENTITY", "Invalid device identity", "Registration fields or the cryptographic signature are invalid.")
	default:
		writeProblem(writer, request, http.StatusInternalServerError, "INTERNAL_ERROR", "Internal gateway error", "The operation could not be completed.")
	}
}

func (a *API) unregisterDevice(writer http.ResponseWriter, request *http.Request) {
	if !a.allow(writer, request) {
		return
	}
	queryValues, err := parseEncodedValues(request.URL.RawQuery)
	if err != nil {
		writeProblem(writer, request, http.StatusBadRequest, "INVALID_DEVICE_IDENTITY", "Invalid device identity", "The unregistration identity tuple is invalid.")
		return
	}
	bodyValues, bodyPresent, readErr := readOptionalForm(writer, request, deviceBodyMaximum)
	if readErr != nil {
		a.writeFormError(writer, request, readErr)
		return
	}
	queryFields, queryPresent, queryErr := optionalTuple(queryValues)
	bodyFields, parsedBodyPresent, bodyErr := optionalTuple(bodyValues)
	bodyPresent = bodyPresent || parsedBodyPresent
	if queryErr != nil || bodyErr != nil || (!queryPresent && !bodyPresent) ||
		(queryPresent && bodyPresent && !equalIdentityTuples(queryFields, bodyFields)) {
		writeProblem(writer, request, http.StatusBadRequest, "INVALID_DEVICE_IDENTITY", "Invalid device identity", "The unregistration identity tuple is invalid.")
		return
	}
	fields := queryFields
	if !queryPresent {
		fields = bodyFields
	}
	identity, err := cryptoidentity.ParsePublicIdentity(fields["userPublicKey"])
	if err != nil || cryptoidentity.VerifyDeviceIdentity(
		fields["deviceIdentifier"],
		fields["deviceIdentifierSignature"],
		identity,
	) != nil {
		writeProblem(writer, request, http.StatusBadRequest, "INVALID_DEVICE_IDENTITY", "Invalid device identity", "The unregistration identity tuple is invalid.")
		return
	}
	err = a.repository.Unregister(request.Context(), fields["deviceIdentifier"], identity.Fingerprint[:])
	switch {
	case err == nil:
		writer.WriteHeader(http.StatusOK)
	case errors.Is(err, store.ErrIdentityForbidden):
		writeProblem(writer, request, http.StatusForbidden, "IDENTITY_FORBIDDEN", "Registration identity forbidden", "The verified identity may not remove this registration.")
	case errors.Is(err, store.ErrInvalidMutation):
		writeProblem(writer, request, http.StatusBadRequest, "INVALID_DEVICE_IDENTITY", "Invalid device identity", "The unregistration identity tuple is invalid.")
	default:
		writeProblem(writer, request, http.StatusInternalServerError, "INTERNAL_ERROR", "Internal gateway error", "The operation could not be completed.")
	}
}

func (a *API) deliverNotifications(writer http.ResponseWriter, request *http.Request) {
	if !a.allow(writer, request) {
		return
	}
	values, readErr := readRequiredForm(writer, request, notificationBodyMaximum)
	if readErr != nil {
		a.writeFormError(writer, request, readErr)
		return
	}
	rawNotifications, err := indexedNotifications(values)
	if err != nil || request.URL.RawQuery != "" {
		writeProblem(writer, request, http.StatusBadRequest, "INVALID_NOTIFICATION_BATCH", "Invalid notification batch", "The indexed notification form is invalid.")
		return
	}

	type parsedNotification struct {
		raw      string
		envelope notificationEnvelope
		valid    bool
	}
	parsed := make([]parsedNotification, len(rawNotifications))
	deviceSet := make(map[string]struct{})
	failed := 0
	for index, raw := range rawNotifications {
		envelope, parseErr := decodeNotificationEnvelope(raw)
		if parseErr != nil {
			failed++
			continue
		}
		parsed[index] = parsedNotification{raw: raw, envelope: envelope, valid: true}
		deviceSet[envelope.DeviceIdentifier] = struct{}{}
	}
	deviceIdentifiers := make([]string, 0, len(deviceSet))
	for deviceIdentifier := range deviceSet {
		deviceIdentifiers = append(deviceIdentifiers, deviceIdentifier)
	}
	registrations, err := a.repository.Registrations(request.Context(), deviceIdentifiers)
	if err != nil {
		writeProblem(writer, request, http.StatusInternalServerError, "INTERNAL_ERROR", "Internal gateway error", "The operation could not be completed.")
		return
	}

	unknown := make([]string, 0)
	unknownSet := make(map[string]struct{})
	queueItems := make([]store.Notification, 0, len(parsed))
	for _, item := range parsed {
		if !item.valid {
			continue
		}
		registration, known := registrations[item.envelope.DeviceIdentifier]
		if !known {
			if _, alreadyUnknown := unknownSet[item.envelope.DeviceIdentifier]; !alreadyUnknown {
				unknownSet[item.envelope.DeviceIdentifier] = struct{}{}
				unknown = append(unknown, item.envelope.DeviceIdentifier)
			}
			continue
		}
		identity, identityErr := cryptoidentity.ParsePublicIdentity(registration.PublicKeyPEM)
		if identityErr != nil ||
			!hmac.Equal([]byte(item.envelope.PushTokenHash), []byte(registration.TokenHash)) ||
			cryptoidentity.VerifyNotification(item.envelope.Subject, item.envelope.Signature, identity) != nil {
			failed++
			continue
		}
		digest := sha256.Sum256([]byte(item.raw))
		queueItems = append(queueItems, store.Notification{
			DeviceIdentifier:       item.envelope.DeviceIdentifier,
			RegistrationGeneration: registration.Generation,
			EnvelopeDigest:         digest,
			Subject:                item.envelope.Subject,
			Signature:              item.envelope.Signature,
			Priority:               item.envelope.Priority,
			Type:                   item.envelope.Type,
		})
	}
	if len(queueItems) > 0 {
		outcomes, enqueueErr := a.repository.Enqueue(request.Context(), queueItems)
		if errors.Is(enqueueErr, store.ErrQueueFull) {
			writer.Header().Set("Retry-After", "30")
			writeProblem(writer, request, http.StatusTooManyRequests, "QUEUE_FULL", "Delivery queue full", "The durable delivery queue is at capacity.")
			return
		}
		if enqueueErr != nil {
			writeProblem(writer, request, http.StatusInternalServerError, "INTERNAL_ERROR", "Internal gateway error", "The operation could not be completed.")
			return
		}
		for _, outcome := range outcomes {
			if !outcome.Accepted {
				failed++
			}
		}
	}
	writeJSON(writer, http.StatusOK, notificationsResponse{Unknown: unknown, Failed: failed})
}

func (a *API) allow(writer http.ResponseWriter, request *http.Request) bool {
	allowed, retryAfter := a.limiter.Allow(remoteKey(request.RemoteAddr))
	if allowed {
		return true
	}
	writer.Header().Set("Retry-After", retryAfter)
	writeProblem(writer, request, http.StatusTooManyRequests, "RATE_LIMITED", "Request rate exceeded", "Retry after the indicated delay.")
	return false
}

func (a *API) writeFormError(writer http.ResponseWriter, request *http.Request, err error) {
	if errors.Is(err, errBodyTooLarge) {
		writeProblem(writer, request, http.StatusRequestEntityTooLarge, "PAYLOAD_TOO_LARGE", "Payload too large", "The request exceeds the configured size limit.")
		return
	}
	writeProblem(writer, request, http.StatusBadRequest, "INVALID_FORM", "Invalid form request", "The URL-encoded request body is invalid.")
}

type notificationEnvelope struct {
	DeviceIdentifier string `json:"deviceIdentifier"`
	PushTokenHash    string `json:"pushTokenHash"`
	Subject          string `json:"subject"`
	Signature        string `json:"signature"`
	Priority         string `json:"priority"`
	Type             string `json:"type"`
}

func decodeNotificationEnvelope(raw string) (notificationEnvelope, error) {
	if len(raw) < 2 || len(raw) > notificationMaximumSize || strictjson.Validate([]byte(raw), 2) != nil {
		return notificationEnvelope{}, errors.New("notification envelope is invalid")
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.DisallowUnknownFields()
	var envelope notificationEnvelope
	if err := decoder.Decode(&envelope); err != nil {
		return notificationEnvelope{}, errors.New("notification envelope is invalid")
	}
	if _, err := cryptoidentity.DecodeDeviceIdentifier(envelope.DeviceIdentifier); err != nil ||
		cryptoidentity.ValidateTokenHash(envelope.PushTokenHash) != nil ||
		!canonicalBase64OfSize(envelope.Subject, cryptoidentity.EncryptedSubjectEncodedLength, 256) ||
		!canonicalBase64OfSize(envelope.Signature, cryptoidentity.SignatureEncodedLength, 256) ||
		(envelope.Priority != "high" && envelope.Priority != "normal") ||
		(envelope.Type != "alert" && envelope.Type != "voip" && envelope.Type != "background") {
		return notificationEnvelope{}, errors.New("notification envelope is invalid")
	}
	return envelope, nil
}

type notificationsResponse struct {
	Unknown []string `json:"unknown"`
	Failed  int      `json:"failed"`
}

type problemDetails struct {
	Type      string `json:"type"`
	Title     string `json:"title"`
	Status    int    `json:"status"`
	Code      string `json:"code"`
	Detail    string `json:"detail,omitempty"`
	RequestID string `json:"requestId"`
}

func writeProblem(writer http.ResponseWriter, request *http.Request, status int, code, title, detail string) {
	writer.Header().Set("Content-Type", "application/problem+json")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(problemDetails{
		Type:      "urn:nkshub:nextcloud-talk:problem:" + strings.ToLower(strings.ReplaceAll(code, "_", "-")),
		Title:     title,
		Status:    status,
		Code:      code,
		Detail:    detail,
		RequestID: requestIDFromContext(request.Context()),
	})
}

func writeJSON(writer http.ResponseWriter, status int, value any) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(value)
}

func canonicalBase64OfSize(value string, encodedLength, decodedLength int) bool {
	if len(value) != encodedLength {
		return false
	}
	decoded, err := base64.StdEncoding.Strict().DecodeString(value)
	return err == nil && len(decoded) == decodedLength && base64.StdEncoding.EncodeToString(decoded) == value
}

type requestIDKey struct{}

func newRequestID() (string, error) {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return "", errors.New("request identifier could not be generated")
	}
	return hex.EncodeToString(value), nil
}

func requestIDFromContext(ctx context.Context) string {
	value, _ := ctx.Value(requestIDKey{}).(string)
	if requestIDPattern.MatchString(value) {
		return value
	}
	return "request-id-unavailable"
}

func endpointTemplate(path string) string {
	switch path {
	case "/devices":
		return "/devices"
	case "/notifications":
		return "/notifications"
	default:
		return "unmatched"
	}
}

func remoteKey(remoteAddress string) string {
	host, _, err := net.SplitHostPort(remoteAddress)
	if err != nil || host == "" {
		return "unknown"
	}
	return strings.ToLower(host)
}

type statusRecorder struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (r *statusRecorder) WriteHeader(status int) {
	if r.wroteHeader {
		return
	}
	r.wroteHeader = true
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (r *statusRecorder) Write(body []byte) (int, error) {
	if !r.wroteHeader {
		r.WriteHeader(http.StatusOK)
	}
	return r.ResponseWriter.Write(body)
}
