// Mock Microsoft Graph API server for scenario 61-teams-messaging.
// Returns canned Graph API responses for Teams message, card, reply, and channel APIs.
// Usage: MOCK_PORT=19061 ./mock-teams
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
var chanCounter atomic.Int64

func main() {
	port := os.Getenv("MOCK_PORT")
	if port == "" {
		port = "19061"
	}
	mux := http.NewServeMux()

	// Microsoft Graph API v1.0 Teams endpoints
	// POST /v1.0/teams/{team_id}/channels/{channel_id}/messages               — send message / card
	// POST /v1.0/teams/{team_id}/channels/{channel_id}/messages/{msg_id}/replies — reply
	// POST /v1.0/teams/{team_id}/channels                                     — create channel
	mux.HandleFunc("/v1.0/teams/", func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		log.Printf("Teams mock: %s %s", r.Method, path)

		switch {
		case strings.Contains(path, "/messages/") && strings.HasSuffix(path, "/replies") && r.Method == http.MethodPost:
			handleReplyMessage(w, r)
		case strings.HasSuffix(path, "/messages") && r.Method == http.MethodPost:
			handleSendMessage(w, r)
		case strings.HasSuffix(path, "/channels") && r.Method == http.MethodPost:
			handleCreateChannel(w, r)
		default:
			writeJSON(w, http.StatusNotFound, map[string]any{
				"error": map[string]any{
					"code":    "itemNotFound",
					"message": "Resource not found",
				},
			})
		}
	})

	addr := ":" + port
	log.Printf("mock Microsoft Graph API (Teams) listening on %s", addr)
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
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)

	id := msgCounter.Add(1)
	msgID := fmt.Sprintf("mock-msg-%d", id)

	// Detect adaptive card vs plain message
	msgType := "message"
	if attachments, ok := body["attachments"]; ok && attachments != nil {
		msgType = "message"
		_ = msgType
	}

	resp := map[string]any{
		"id":        msgID,
		"createdDateTime": "2026-03-14T00:00:00Z",
		"etag":      fmt.Sprintf("%d", id),
		"messageType": "message",
		"webUrl":    fmt.Sprintf("https://teams.microsoft.com/mock/message/%s", msgID),
	}
	if content, ok := body["body"]; ok {
		resp["body"] = content
	}
	if attachments, ok := body["attachments"]; ok {
		resp["attachments"] = attachments
	}
	writeJSON(w, http.StatusCreated, resp)
}

func handleReplyMessage(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)

	id := msgCounter.Add(1)
	replyID := fmt.Sprintf("mock-reply-%d", id)

	// Extract message_id from path: /v1.0/teams/{tid}/channels/{cid}/messages/{mid}/replies
	parts := strings.Split(r.URL.Path, "/")
	msgID := ""
	for i, p := range parts {
		if p == "messages" && i+1 < len(parts) {
			msgID = parts[i+1]
			break
		}
	}

	writeJSON(w, http.StatusCreated, map[string]any{
		"id":              replyID,
		"replyToId":       msgID,
		"createdDateTime": "2026-03-14T00:00:00Z",
		"messageType":     "message",
	})
}

func handleCreateChannel(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)

	id := chanCounter.Add(1)
	chanID := fmt.Sprintf("mock-channel-%d", id)

	name := ""
	if n, ok := body["displayName"].(string); ok {
		name = n
	}
	desc := ""
	if d, ok := body["description"].(string); ok {
		desc = d
	}

	writeJSON(w, http.StatusCreated, map[string]any{
		"id":          chanID,
		"displayName": name,
		"description": desc,
		"membershipType": "standard",
		"webUrl":      fmt.Sprintf("https://teams.microsoft.com/mock/channel/%s", chanID),
	})
}
