package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"netpivot/internal/control"
)

func main() {
	if err := run(); err != nil {
		slog.Error("API stopped", "error", err)
		os.Exit(1)
	}
}

func run() error {
	options := control.Options{
		Endpoint:     os.Getenv("NETPIVOT_GATEWAY_ENDPOINT"),
		GatewayKey:   os.Getenv("NETPIVOT_GATEWAY_KEY"),
		AgentToken:   os.Getenv("NETPIVOT_AGENT_TOKEN"),
		InviteOrigin: os.Getenv("NETPIVOT_ORIGIN"),
		InviteSecret: []byte(os.Getenv("NETPIVOT_INVITE_SECRET")),
	}
	if err := options.Validate(); err != nil {
		return err
	}
	if os.Getenv("NETPIVOT_TRUST_PROXY") == "1" {
		control.TrustPrivateProxy()
	}
	var store control.Store
	switch {
	case os.Getenv("NETPIVOT_DATABASE_URL") != "":
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		var err error
		store, err = control.OpenPostgres(ctx, os.Getenv("NETPIVOT_DATABASE_URL"))
		if err != nil {
			return errors.New("could not initialize PostgreSQL")
		}
	case os.Getenv("NETPIVOT_DEV_MEMORY") == "1":
		store = &control.MemoryStore{}
		slog.Warn("using ephemeral development storage")
	default:
		return errors.New("configure NETPIVOT_DATABASE_URL")
	}
	listen := os.Getenv("NETPIVOT_LISTEN")
	if listen == "" {
		listen = "127.0.0.1:8080"
	}
	server := &http.Server{Addr: listen, Handler: control.NewAPI(store, options),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second,
		MaxHeaderBytes: 16 << 10}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdown)
	}()
	slog.Info("API listening", "address", listen)
	err := server.ListenAndServe()
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
