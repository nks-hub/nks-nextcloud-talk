package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"golang.org/x/net/netutil"

	"nks-nextcloud-talk/services/push_gateway/internal/config"
	"nks-nextcloud-talk/services/push_gateway/internal/cryptoidentity"
	"nks-nextcloud-talk/services/push_gateway/internal/httpapi"
	"nks-nextcloud-talk/services/push_gateway/internal/identityproof"
	"nks-nextcloud-talk/services/push_gateway/internal/ops"
	"nks-nextcloud-talk/services/push_gateway/internal/provider"
	"nks-nextcloud-talk/services/push_gateway/internal/store"
	"nks-nextcloud-talk/services/push_gateway/internal/worker"
)

const (
	readHeaderTimeout  = 5 * time.Second
	readTimeout        = 30 * time.Second
	writeTimeout       = 30 * time.Second
	idleTimeout        = 60 * time.Second
	maximumHeaderSize  = 32 * 1024
	maximumConnections = 1024
)

type deliveryRunner interface {
	Run(context.Context) error
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.LookupEnv, logger); err != nil {
		logger.Error("push gateway stopped", "error", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, lookup config.Lookup, logger *slog.Logger) error {
	settings, err := config.Load(lookup)
	if err != nil {
		return err
	}
	tokenCipher, err := cryptoidentity.NewTokenCipher(settings.TokenEncryptionKey)
	clear(settings.TokenEncryptionKey)
	if err != nil {
		return err
	}
	database, err := store.Open(ctx, settings.DatabaseURL, settings.QueueMaximumDepth)
	if err != nil {
		return err
	}
	defer database.Close()
	identityVerifier, err := identityproof.NewVerifier(identityproof.VerifierConfig{})
	if err != nil {
		return err
	}
	firebaseProvider, err := provider.NewFirebase(ctx, settings.FirebaseProjectID)
	if err != nil {
		return err
	}
	deliveryWorker, err := worker.New(worker.Config{
		WorkerCount:     settings.WorkerCount,
		ClaimSize:       settings.ClaimSize,
		LeaseDuration:   settings.LeaseDuration,
		ProviderTimeout: settings.ProviderTimeout,
		ShutdownTimeout: settings.ShutdownTimeout,
		DedupeRetention: settings.DedupeRetention,
	}, database, tokenCipher, firebaseProvider)
	if err != nil {
		return err
	}
	api, err := httpapi.New(httpapi.Config{
		Repository:         database,
		IdentityVerifier:   identityVerifier,
		TokenCipher:        tokenCipher,
		Logger:             logger,
		RateLimitPerMinute: settings.RateLimitPerMinute,
		RateLimitBurst:     settings.RateLimitBurst,
	})
	if err != nil {
		return err
	}
	handler, err := ops.New(api, database, deliveryWorker)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", settings.ListenAddress)
	if err != nil {
		return errors.New("HTTP listener could not start")
	}
	logger.Info("push gateway started", "listen_address", listener.Addr().String())
	return serve(ctx, listener, handler, deliveryWorker, settings.ShutdownTimeout, logger)
}

func serve(
	ctx context.Context,
	listener net.Listener,
	handler http.Handler,
	deliveryWorker deliveryRunner,
	shutdownTimeout time.Duration,
	logger *slog.Logger,
) error {
	if ctx == nil || listener == nil || handler == nil || deliveryWorker == nil ||
		shutdownTimeout <= 0 || logger == nil {
		return errors.New("runtime configuration is invalid")
	}
	runtimeContext, cancel := context.WithCancel(ctx)
	defer cancel()
	server := newHTTPServer(handler, logger)
	listener = netutil.LimitListener(listener, maximumConnections)
	serverDone := make(chan error, 1)
	workerDone := make(chan error, 1)
	go func() { serverDone <- server.Serve(listener) }()
	go func() { workerDone <- deliveryWorker.Run(runtimeContext) }()

	var runtimeError error
	serverFinished := false
	workerFinished := false
	select {
	case <-ctx.Done():
	case err := <-serverDone:
		serverFinished = true
		if !errors.Is(err, http.ErrServerClosed) {
			runtimeError = fmt.Errorf("HTTP server stopped: %w", err)
		} else if ctx.Err() == nil {
			runtimeError = errors.New("HTTP server stopped unexpectedly")
		}
	case err := <-workerDone:
		workerFinished = true
		if err != nil {
			runtimeError = fmt.Errorf("delivery worker stopped: %w", err)
		} else if ctx.Err() == nil {
			runtimeError = errors.New("delivery worker stopped unexpectedly")
		}
	}
	cancel()

	shutdownContext, shutdownCancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer shutdownCancel()
	shutdownError := server.Shutdown(shutdownContext)
	if shutdownError != nil {
		_ = server.Close()
	}
	if !serverFinished {
		select {
		case err := <-serverDone:
			if !errors.Is(err, http.ErrServerClosed) && runtimeError == nil {
				runtimeError = fmt.Errorf("HTTP server stopped: %w", err)
			}
		case <-shutdownContext.Done():
			if runtimeError == nil {
				runtimeError = errors.New("HTTP server shutdown timed out")
			}
		}
	}
	if !workerFinished {
		select {
		case err := <-workerDone:
			if err != nil && runtimeError == nil {
				runtimeError = fmt.Errorf("delivery worker stopped: %w", err)
			}
		case <-shutdownContext.Done():
			if runtimeError == nil {
				runtimeError = errors.New("delivery worker shutdown timed out")
			}
		}
	}
	if shutdownError != nil && runtimeError == nil {
		return errors.New("HTTP server shutdown failed")
	}
	return runtimeError
}

func newHTTPServer(handler http.Handler, logger *slog.Logger) *http.Server {
	return &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: readHeaderTimeout,
		ReadTimeout:       readTimeout,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       idleTimeout,
		MaxHeaderBytes:    maximumHeaderSize,
		ErrorLog:          slog.NewLogLogger(logger.Handler(), slog.LevelError),
	}
}
