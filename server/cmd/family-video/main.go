package main

import (
	"context"
	"familyvideo/server/internal/family"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	worker := flag.Bool("worker", true, "run download worker with the HTTP server")
	flag.Parse()
	config, err := family.LoadConfig()
	if err != nil {
		log.Fatal(err)
	}
	// Claim the port before migrations so accidentally launching a second
	// service cannot change the database used by the running instance.
	listener, err := net.Listen("tcp", net.JoinHostPort(config.Host, config.Port))
	if err != nil {
		log.Fatal(err)
	}
	app, err := family.New(config)
	if err != nil {
		listener.Close()
		log.Fatal(err)
	}
	defer app.DB.Close()
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	var wait func()
	if *worker {
		wait, err = app.StartWorker(ctx)
		if err != nil {
			listener.Close()
			log.Fatal(err)
		}
	}
	server := &http.Server{Handler: app.Handler(), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 1 << 20}
	go func() {
		<-ctx.Done()
		shutdown, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		server.Shutdown(shutdown)
	}()
	log.Printf("Family Video Go server http://%s:%s (worker=%v)", config.Host, config.Port, *worker)
	if err = server.Serve(listener); err != nil && err != http.ErrServerClosed {
		log.Print(err)
	}
	cancel()
	if wait != nil {
		wait()
	}
}
