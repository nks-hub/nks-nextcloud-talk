package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"testing"
	"time"
)

func TestServeRunsRealHTTPAndStopsWorker(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen() error = %v", err)
	}
	worker := &blockingRunner{started: make(chan struct{}), stopped: make(chan struct{})}
	handler := http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.WriteHeader(http.StatusNoContent)
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- serve(ctx, listener, handler, worker, time.Second, testLogger())
	}()

	select {
	case <-worker.started:
	case <-time.After(time.Second):
		t.Fatal("worker did not start")
	}
	response, err := http.Get("http://" + listener.Addr().String())
	if err != nil {
		t.Fatalf("http.Get() error = %v", err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("HTTP status = %d, want 204", response.StatusCode)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("serve() error = %v", err)
	}
	select {
	case <-worker.stopped:
	default:
		t.Fatal("worker did not observe graceful cancellation")
	}
}

func TestServeStopsHTTPWhenWorkerFails(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen() error = %v", err)
	}
	workerFailure := errors.New("bounded worker failure")
	worker := runnerFunc(func(context.Context) error { return workerFailure })

	err = serve(
		context.Background(),
		listener,
		http.NotFoundHandler(),
		worker,
		time.Second,
		testLogger(),
	)
	if !errors.Is(err, workerFailure) {
		t.Fatalf("serve() error = %v, want worker failure", err)
	}
}

func TestHTTPServerHasBoundedTimeoutsAndHeaders(t *testing.T) {
	server := newHTTPServer(http.NotFoundHandler(), testLogger())
	if server.ReadHeaderTimeout != readHeaderTimeout || server.ReadTimeout != readTimeout ||
		server.WriteTimeout != writeTimeout || server.IdleTimeout != idleTimeout ||
		server.MaxHeaderBytes != maximumHeaderSize {
		t.Fatalf("HTTP server limits = %+v", server)
	}
}

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

type blockingRunner struct {
	started chan struct{}
	stopped chan struct{}
}

func (r *blockingRunner) Run(ctx context.Context) error {
	close(r.started)
	<-ctx.Done()
	close(r.stopped)
	return nil
}

type runnerFunc func(context.Context) error

func (f runnerFunc) Run(ctx context.Context) error {
	return f(ctx)
}
