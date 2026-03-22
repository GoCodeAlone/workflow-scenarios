// Mock Slack API server for scenario 60-slack-messaging.
// Returns canned Slack API responses for message, blocks, thread reply, and topic APIs.
// Usage: MOCK_PORT=19060 ./mock-slack
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync/atomic"
)

var tsCounter atomic.Int64

func main() {
	port := os.Getenv("MOCK_PORT")
	if port == "" {
		port = "19060"
	}
	mux := http.NewServeMux()

	// Slack Web API endpoints
	// The slack-go SDK with OptionAPIURL("http://host/") calls http://host/<method>
	// (no /api/ prefix, since the default base URL already includes /api/).
	mux.HandleFunc("/chat.postMessage", handlePostMessage)
	mux.HandleFunc("/conversations.setTopic", handleSetTopic)

	addr := ":" + port
	log.Printf("mock Slack API listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// handlePostMessage handles chat.postMessage for plain messages, blocks, and thread replies.
func handlePostMessage(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()

	n := tsCounter.Add(1)
	channel := r.FormValue("channel")
	threadTS := r.FormValue("thread_ts")

	ts := fmt.Sprintf("17%010d.%06d", n, n)

	log.Printf("Slack mock: chat.postMessage channel=%s thread_ts=%s", channel, threadTS)

	resp := map[string]any{
		"ok":      true,
		"channel": channel,
		"ts":      ts,
		"message": map[string]any{
			"type": "message",
			"ts":   ts,
			"text": r.FormValue("text"),
		},
	}
	if threadTS != "" {
		resp["thread_ts"] = threadTS
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleSetTopic handles conversations.setTopic.
func handleSetTopic(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	channel := r.FormValue("channel")
	topic := r.FormValue("topic")

	log.Printf("Slack mock: conversations.setTopic channel=%s topic=%s", channel, topic)

	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true,
		"channel": map[string]any{
			"id":    channel,
			"topic": map[string]any{"value": topic},
		},
	})
}
