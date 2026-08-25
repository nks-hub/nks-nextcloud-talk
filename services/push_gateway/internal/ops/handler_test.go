package ops

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"nks-nextcloud-talk/services/push_gateway/internal/store"
	"nks-nextcloud-talk/services/push_gateway/internal/worker"
)

func TestHealthEndpointsSeparateLivenessAndReadiness(t *testing.T) {
	database := &fakeDatabase{}
	deliveryWorker := &fakeWorker{}
	handler := newTestHandler(t, database, deliveryWorker)

	live := httptest.NewRecorder()
	handler.ServeHTTP(live, httptest.NewRequest(http.MethodGet, "/health/live", nil))
	if live.Code != http.StatusOK || !strings.Contains(live.Body.String(), `"alive"`) {
		t.Fatalf("liveness status=%d body=%q", live.Code, live.Body.String())
	}

	notReady := httptest.NewRecorder()
	handler.ServeHTTP(notReady, httptest.NewRequest(http.MethodGet, "/health/ready", nil))
	if notReady.Code != http.StatusServiceUnavailable {
		t.Fatalf("readiness status = %d, want 503", notReady.Code)
	}

	deliveryWorker.ready = true
	ready := httptest.NewRecorder()
	handler.ServeHTTP(ready, httptest.NewRequest(http.MethodGet, "/health/ready", nil))
	if ready.Code != http.StatusOK || !strings.Contains(ready.Body.String(), `"ready"`) {
		t.Fatalf("readiness status=%d body=%q", ready.Code, ready.Body.String())
	}

	database.readyError = errors.New("secret database detail")
	databaseFailure := httptest.NewRecorder()
	handler.ServeHTTP(databaseFailure, httptest.NewRequest(http.MethodGet, "/health/ready", nil))
	if databaseFailure.Code != http.StatusServiceUnavailable ||
		strings.Contains(databaseFailure.Body.String(), "secret") {
		t.Fatalf("database readiness status=%d body=%q", databaseFailure.Code, databaseFailure.Body.String())
	}
}

func TestMetricsUseOnlyBoundedLabelsAndQueueStates(t *testing.T) {
	database := &fakeDatabase{stats: store.QueueStats{Pending: 2, Delivered: 3}}
	deliveryWorker := &fakeWorker{
		ready: true,
		metrics: worker.MetricsSnapshot{
			Delivered:    4,
			RetryTimeout: 1,
			Active:       2,
		},
	}
	api := http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.WriteHeader(http.StatusTeapot)
	})
	handler, err := New(api, database, deliveryWorker)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	apiResponse := httptest.NewRecorder()
	handler.ServeHTTP(apiResponse, httptest.NewRequest(http.MethodPost, "/devices", nil))
	metrics := httptest.NewRecorder()
	handler.ServeHTTP(metrics, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := metrics.Body.String()

	for _, expected := range []string{
		`push_gateway_ready 1`,
		`push_gateway_http_requests_total{endpoint="/devices",status_class="4xx"} 1`,
		`push_gateway_provider_outcomes_total{outcome="delivered"} 4`,
		`push_gateway_provider_outcomes_total{outcome="retry_timeout"} 1`,
		`push_gateway_active_deliveries 2`,
		`push_gateway_queue_jobs{state="pending"} 2`,
		`push_gateway_queue_jobs{state="delivered"} 3`,
	} {
		if !strings.Contains(body, expected) {
			t.Fatalf("metrics do not contain %q\n%s", expected, body)
		}
	}
	if strings.Contains(body, "deviceIdentifier") || strings.Contains(body, "provider-token") ||
		strings.Contains(body, "cloudId") {
		t.Fatal("metrics contain an unbounded or secret label")
	}
}

func TestMetricsFailClosedWithoutDatabaseDetails(t *testing.T) {
	database := &fakeDatabase{statsError: errors.New("postgres host and credential detail")}
	handler := newTestHandler(t, database, &fakeWorker{ready: true})
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/metrics", nil))

	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("metrics status = %d, want 503", response.Code)
	}
	if strings.Contains(response.Body.String(), "postgres") || strings.Contains(response.Body.String(), "credential") {
		t.Fatalf("metrics disclosed database failure: %q", response.Body.String())
	}
}

func newTestHandler(t *testing.T, database Database, deliveryWorker DeliveryRuntime) *Handler {
	t.Helper()
	handler, err := New(http.NotFoundHandler(), database, deliveryWorker)
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	return handler
}

type fakeDatabase struct {
	readyError error
	stats      store.QueueStats
	statsError error
}

func (d *fakeDatabase) Ready(context.Context) error {
	return d.readyError
}

func (d *fakeDatabase) QueueStats(context.Context) (store.QueueStats, error) {
	return d.stats, d.statsError
}

type fakeWorker struct {
	ready   bool
	metrics worker.MetricsSnapshot
}

func (w *fakeWorker) Ready() bool {
	return w.ready
}

func (w *fakeWorker) Metrics() worker.MetricsSnapshot {
	return w.metrics
}
