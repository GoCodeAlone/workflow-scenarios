// Mock Discord API server for scenario 59-discord-messaging.
// Returns canned Discord API responses for message, embed, reaction, and thread APIs.
// Usage: MOCK_PORT=19059 ./mock-discord
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
)

var msgCounter atomic.Int64

func main() {
	port := os.Getenv("MOCK_PORT")
	if port == "" {
		port = "19059"
	}
	mux := http.NewServeMux()

	// Discord API channel endpoints (handles both v9 and v10)
	// POST /api/v9/channels/{channel_id}/messages           — send message / embed
	// POST /api/v9/channels/{channel_id}/threads            — create thread
	// PUT  /api/v9/channels/{channel_id}/messages/{msg_id}/reactions/{emoji}/@me — add reaction
	channelHandler := func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		log.Printf("Discord mock: %s %s", r.Method, path)

		switch {
		case strings.HasSuffix(path, "/messages") && r.Method == http.MethodPost:
			handleSendMessage(w, r)
		case strings.HasSuffix(path, "/threads") && r.Method == http.MethodPost:
			handleCreateThread(w, r)
		case strings.Contains(path, "/reactions/") && r.Method == http.MethodPut:
			handleAddReaction(w, r)
		default:
			writeJSON(w, http.StatusNotFound, map[string]any{"code": 10003, "message": "Unknown Channel"})
		}
	}
	mux.HandleFunc("/api/v9/channels/", channelHandler)
	mux.HandleFunc("/api/v10/channels/", channelHandler)

	addr := ":" + port
	log.Printf("mock Discord API listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func handleSendMessage(w http.ResponseWriter, r *http.Request) {
	id := msgCounter.Add(1)

	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)

	channelID := extractChannelID(r.URL.Path)
	msgID := fmt.Sprintf("mock-msg-%d", id)

	resp := map[string]any{
		"id":         msgID,
		"channel_id": channelID,
		"type":       0,
	}
	if content, ok := body["content"]; ok {
		resp["content"] = content
	}
	if embeds, ok := body["embeds"]; ok {
		resp["embeds"] = embeds
	}
	writeJSON(w, http.StatusOK, resp)
}

func handleCreateThread(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)

	name := ""
	if n, ok := body["name"].(string); ok {
		name = n
	}

	writeJSON(w, http.StatusCreated, map[string]any{
		"id":         "mock-thread-1001",
		"type":       11,
		"name":       name,
		"channel_id": extractChannelID(r.URL.Path),
	})
}

func handleAddReaction(w http.ResponseWriter, _ *http.Request) {
	// Discord returns 204 No Content on success
	w.WriteHeader(http.StatusNoContent)
}

// extractChannelID pulls the channel ID segment from a path like /api/v9/channels/123456/...
func extractChannelID(path string) string {
	// Strip the version prefix (v9, v10, etc.)
	for _, prefix := range []string{"/api/v9/channels/", "/api/v10/channels/"} {
		if strings.HasPrefix(path, prefix) {
			parts := strings.Split(strings.TrimPrefix(path, prefix), "/")
			if len(parts) > 0 {
				return parts[0]
			}
		}
	}
	return "unknown"
}
