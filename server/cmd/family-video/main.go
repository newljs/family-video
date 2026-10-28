package main

import (
	"context"
	"familyvideo/server/internal/family"
	"flag"
	"github.com/gofrs/flock"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func main() {
	worker := flag.Bool("worker", true, "run download worker with the HTTP server")
	if len(os.Args) < 2 || strings.HasPrefix(os.Args[1], "-") {
		flag.Parse()
	}
	config, err := family.LoadConfig()
	if err != nil {
		log.Fatal(err)
	}
	if len(os.Args) > 1 && !strings.HasPrefix(os.Args[1], "-") {
		if err = runCommand(config, os.Args[1:]); err != nil {
			log.Fatal(err)
		}
		return
	}
	lock := flock.New(filepath.Join(config.Data, "server.lock"))
	ok, err := lock.TryLock()
	if err != nil {
		log.Fatal(err)
	}
	if !ok {
		log.Fatal("服务或维护命令正在使用该数据目录")
	}
	defer lock.Unlock()
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
	stopDiscovery, discoveryErr := family.StartDiscovery(ctx, listener.Addr().(*net.TCPAddr))
	if discoveryErr != nil {
		log.Printf("局域网自动发现未启动（UDP %d），仍可扫码/手动连接: %v", family.DiscoveryPort, discoveryErr)
	} else {
		defer stopDiscovery()
	}
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
