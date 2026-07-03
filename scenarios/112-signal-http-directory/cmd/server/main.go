package main

import (
	"log"
	"net/http"
	"os"

	"github.com/GoCodeAlone/workflow-scenarios/scenarios/112-signal-http-directory/internal/fakes"
)

func main() {
	addr := getenv("SIGNAL_HTTP_DIRECTORY_ADDR", "127.0.0.1:18192")
	storePath := getenv("SIGNAL_HTTP_DIRECTORY_STORE", "")
	token := getenv("SIGNAL_HTTP_DIRECTORY_TOKEN", "scenario-112-directory-token")

	directory, err := fakes.NewDirectory(storePath, token)
	if err != nil {
		log.Fatalf("create fake directory: %v", err)
	}
	log.Printf("fake Signal HTTP directory listening on %s", addr)
	if err := http.ListenAndServe(addr, directory.Handler()); err != nil {
		log.Fatalf("fake Signal HTTP directory failed: %v", err)
	}
}

func getenv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
