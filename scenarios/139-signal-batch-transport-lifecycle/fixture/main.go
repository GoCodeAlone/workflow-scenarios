package main

import (
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"

	natsserver "github.com/nats-io/nats-server/v2/server"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:19130", "NATS client listen address")
	healthAddr := flag.String("health-addr", "127.0.0.1:19131", "HTTP health listen address")
	store := flag.String("store", "", "JetStream store directory")
	flag.Parse()
	if *store == "" {
		log.Fatal("--store is required")
	}
	host, portString, err := net.SplitHostPort(*addr)
	if err != nil {
		log.Fatalf("parse --addr: %v", err)
	}
	port, err := strconv.Atoi(portString)
	if err != nil {
		log.Fatalf("parse port: %v", err)
	}
	if err := os.MkdirAll(*store, 0o700); err != nil {
		log.Fatalf("create store: %v", err)
	}

	opts := &natsserver.Options{
		Host:      host,
		Port:      port,
		JetStream: true,
		StoreDir:  *store,
		NoLog:     true,
		NoSigs:    true,
	}
	server, err := natsserver.NewServer(opts)
	if err != nil {
		log.Fatalf("create nats server: %v", err)
	}
	go server.Start()
	if !server.ReadyForConnections(10 * time.Second) {
		log.Fatal("nats server did not become ready")
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	log.Printf("embedded nats/jetstream listening on %s; health on %s", *addr, *healthAddr)
	if err := http.ListenAndServe(*healthAddr, mux); err != nil {
		log.Fatal(err)
	}
}
