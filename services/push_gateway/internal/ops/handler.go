package ops

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync/atomic"
	"time"

	"nks-nextcloud-talk/services/push_gateway/internal/store"
	"nks-nextcloud-talk/services/push_gateway/internal/worker"
)

const readinessTimeout = 2 * time.Second

var endpointLabels = [...]string{
	"unmatched",
	"/devices",
	"/notifications",
	"/health/live",
	"/health/ready",
	"/metrics",
}

type Database interface {
	Ready(context.Context) error
	QueueStats(context.Context) (store.QueueStats, error)
}

type DeliveryRuntime interface {
	Ready() bool
	Metrics() worker.MetricsSnapshot
}

type Handler struct {
	api      http.Handler
	database Database
	worker   DeliveryRuntime
	requests [len(endpointLabels)][6]atomic.Uint64
}

func New(api http.Handler, database Database, deliveryWorker DeliveryRuntime) (*Handler, error) {
	if api == nil || database == nil || deliveryWorker == nil {
		return nil, fmt.Errorf("operations handler configuration is invalid")
	}
	return &Handler{api: api, database: database, worker: deliveryWorker}, nil
}

func (h *Handler) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	endpoint := endpointIndex(request.URL.Path)
	recorder := &statusRecorder{ResponseWriter: response, status: http.StatusOK}
	switch {
	case request.Method == http.MethodGet && request.URL.Path == "/health/live":
		h.liveness(recorder)
	case request.Method == http.MethodGet && request.URL.Path == "/health/ready":
		h.readiness(recorder, request)
	case request.Method == http.MethodGet && request.URL.Path == "/metrics":
		h.metrics(recorder, request)
	default:
		h.api.ServeHTTP(recorder, request)
	}
	statusClass := recorder.status / 100
	if statusClass < 1 || statusClass > 5 {
		statusClass = 0
	}
	h.requests[endpoint][statusClass].Add(1)
}

func (h *Handler) liveness(response http.ResponseWriter) {
	writeHealth(response, http.StatusOK, "alive")
}

func (h *Handler) readiness(response http.ResponseWriter, request *http.Request) {
	if !h.worker.Ready() {
		writeHealth(response, http.StatusServiceUnavailable, "not_ready")
		return
	}
	ctx, cancel := context.WithTimeout(request.Context(), readinessTimeout)
	defer cancel()
	if err := h.database.Ready(ctx); err != nil {
		writeHealth(response, http.StatusServiceUnavailable, "not_ready")
		return
	}
	writeHealth(response, http.StatusOK, "ready")
}

func (h *Handler) metrics(response http.ResponseWriter, request *http.Request) {
	ctx, cancel := context.WithTimeout(request.Context(), readinessTimeout)
	defer cancel()
	queue, queueError := h.database.QueueStats(ctx)
	response.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	response.Header().Set("Cache-Control", "no-store")
	response.Header().Set("X-Content-Type-Options", "nosniff")
	if queueError != nil {
		response.WriteHeader(http.StatusServiceUnavailable)
	} else {
		response.WriteHeader(http.StatusOK)
	}

	ready := 0
	if queueError == nil && h.worker.Ready() {
		ready = 1
	}
	_, _ = fmt.Fprintf(response, "# TYPE push_gateway_ready gauge\npush_gateway_ready %d\n", ready)
	_, _ = fmt.Fprintln(response, "# TYPE push_gateway_http_requests_total counter")
	for endpointIndex, endpoint := range endpointLabels {
		for statusClass := 1; statusClass <= 5; statusClass++ {
			count := h.requests[endpointIndex][statusClass].Load()
			_, _ = fmt.Fprintf(
				response,
				"push_gateway_http_requests_total{endpoint=%q,status_class=%q} %d\n",
				endpoint,
				fmt.Sprintf("%dxx", statusClass),
				count,
			)
		}
	}

	workerMetrics := h.worker.Metrics()
	_, _ = fmt.Fprintln(response, "# TYPE push_gateway_provider_outcomes_total counter")
	providerOutcomes := [...]struct {
		name  string
		value uint64
	}{
		{name: "delivered", value: workerMetrics.Delivered},
		{name: "retry_timeout", value: workerMetrics.RetryTimeout},
		{name: "retry_rate_limited", value: workerMetrics.RetryRateLimited},
		{name: "retry_server", value: workerMetrics.RetryServer},
		{name: "invalid_token", value: workerMetrics.InvalidToken},
		{name: "permanent_message", value: workerMetrics.PermanentMessage},
		{name: "permanent_provider", value: workerMetrics.PermanentProvider},
	}
	for _, outcome := range providerOutcomes {
		_, _ = fmt.Fprintf(
			response,
			"push_gateway_provider_outcomes_total{outcome=%q} %d\n",
			outcome.name,
			outcome.value,
		)
	}
	_, _ = fmt.Fprintln(response, "# TYPE push_gateway_active_deliveries gauge")
	_, _ = fmt.Fprintf(response, "push_gateway_active_deliveries %d\n", workerMetrics.Active)

	if queueError == nil {
		_, _ = fmt.Fprintln(response, "# TYPE push_gateway_queue_jobs gauge")
		queueStates := [...]struct {
			name  string
			value int64
		}{
			{name: "pending", value: queue.Pending},
			{name: "leased", value: queue.Leased},
			{name: "delivered", value: queue.Delivered},
			{name: "permanent_failure", value: queue.PermanentFailure},
			{name: "cancelled", value: queue.Cancelled},
		}
		for _, state := range queueStates {
			_, _ = fmt.Fprintf(
				response,
				"push_gateway_queue_jobs{state=%q} %d\n",
				state.name,
				state.value,
			)
		}
	}
}

func writeHealth(response http.ResponseWriter, status int, state string) {
	response.Header().Set("Content-Type", "application/json")
	response.Header().Set("Cache-Control", "no-store")
	response.Header().Set("X-Content-Type-Options", "nosniff")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(map[string]string{"status": state})
}

func endpointIndex(path string) int {
	for index, endpoint := range endpointLabels[1:] {
		if path == endpoint {
			return index + 1
		}
	}
	return 0
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
