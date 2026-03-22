// Mock multi-platform API server for scenario 62-cross-platform-messaging.
// Serves mock Discord, Slack, and Teams APIs simultaneously on separate ports.
//
// Discord API  → :19062  (DISCORD_PORT)
// Slack API    → :19063  (SLACK_PORT)
// Teams Graph  → :19064  (TEAMS_PORT)
//
// Usage: ./mock-cross-platform
// All ports are configurable via environment variables.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
)

// ---- Shared counters ----

var discordMsgCounter atomic.Int64
var slackTSCounter atomic.Int64
var teamsMsgCounter atomic.Int64
var teamsChanCounter atomic.Int64

// requestLog tracks received requests for test assertion
type requestLog struct {
	mu       sync.Mutex
	discord  []string
	slack    []string
	teams    []string
}

var reqLog requestLog

func main() {
	discordPort := envOr("DISCORD_PORT", "19062")
	slackPort := envOr("SLACK_PORT", "19063")
	teamsPort := envOr("TEAMS_PORT", "19064")

	var wg sync.WaitGroup

	// --- Discord mock ---
	wg.Add(1)
	go func() {
		defer wg.Done()
		mux := http.NewServeMux()
		// discordgo SDK uses API v9; handle both v9 and v10 for compatibility
		discordChannelHandler := func(w http.ResponseWriter, r *http.Request) {
			path := r.URL.Path
			log.Printf("[Discord] %s %s", r.Method, path)
			reqLog.mu.Lock()
			reqLog.discord = append(reqLog.discord, fmt.Sprintf("%s %s", r.Method, path))
			reqLog.mu.Unlock()

			switch {
			case strings.HasSuffix(path, "/messages") && r.Method == http.MethodPost:
				discordSendMessage(w, r)
			case strings.HasSuffix(path, "/threads") && r.Method == http.MethodPost:
				discordCreateThread(w, r)
			case strings.Contains(path, "/reactions/") && r.Method == http.MethodPut:
				w.WriteHeader(http.StatusNoContent)
			default:
				writeJSON(w, http.StatusNotFound, map[string]any{"code": 10003, "message": "Unknown Channel"})
			}
		}
		mux.HandleFunc("/api/v9/channels/", discordChannelHandler)
		mux.HandleFunc("/api/v10/channels/", discordChannelHandler)
		// Request log endpoint for test assertions
		mux.HandleFunc("/test/requests", func(w http.ResponseWriter, r *http.Request) {
			reqLog.mu.Lock()
			defer reqLog.mu.Unlock()
			writeJSON(w, http.StatusOK, map[string]any{"requests": reqLog.discord, "count": len(reqLog.discord)})
		})
		log.Printf("mock Discord API listening on :%s", discordPort)
		if err := http.ListenAndServe(":"+discordPort, mux); err != nil {
			log.Fatalf("Discord mock: %v", err)
		}
	}()

	// --- Slack mock ---
	wg.Add(1)
	go func() {
		defer wg.Done()
		mux := http.NewServeMux()
		// slack-go SDK with OptionAPIURL("http://host/") calls http://host/<method> (no /api/ prefix)
		mux.HandleFunc("/chat.postMessage", func(w http.ResponseWriter, r *http.Request) {
			_ = r.ParseForm()
			n := slackTSCounter.Add(1)
			channel := r.FormValue("channel")
			threadTS := r.FormValue("thread_ts")
			ts := fmt.Sprintf("17%010d.%06d", n, n)
			log.Printf("[Slack] chat.postMessage channel=%s", channel)
			reqLog.mu.Lock()
			reqLog.slack = append(reqLog.slack, fmt.Sprintf("POST /chat.postMessage channel=%s", channel))
			reqLog.mu.Unlock()
			resp := map[string]any{
				"ok":      true,
				"channel": channel,
				"ts":      ts,
				"message": map[string]any{"type": "message", "ts": ts, "text": r.FormValue("text")},
			}
			if threadTS != "" {
				resp["thread_ts"] = threadTS
			}
			writeJSON(w, http.StatusOK, resp)
		})
		mux.HandleFunc("/conversations.setTopic", func(w http.ResponseWriter, r *http.Request) {
			_ = r.ParseForm()
			channel := r.FormValue("channel")
			topic := r.FormValue("topic")
			log.Printf("[Slack] conversations.setTopic channel=%s", channel)
			writeJSON(w, http.StatusOK, map[string]any{
				"ok":      true,
				"channel": map[string]any{"id": channel, "topic": map[string]any{"value": topic}},
			})
		})
		// Request log endpoint
		mux.HandleFunc("/test/requests", func(w http.ResponseWriter, r *http.Request) {
			reqLog.mu.Lock()
			defer reqLog.mu.Unlock()
			writeJSON(w, http.StatusOK, map[string]any{"requests": reqLog.slack, "count": len(reqLog.slack)})
		})
		log.Printf("mock Slack API listening on :%s", slackPort)
		if err := http.ListenAndServe(":"+slackPort, mux); err != nil {
			log.Fatalf("Slack mock: %v", err)
		}
	}()

	// --- Teams mock ---
	wg.Add(1)
	go func() {
		defer wg.Done()
		mux := http.NewServeMux()
		// Graph SDK uses {+baseurl}/teams/... so paths are /teams/... (no /v1.0/ prefix)
		mux.HandleFunc("/teams/", func(w http.ResponseWriter, r *http.Request) {
			path := r.URL.Path
			log.Printf("[Teams] %s %s", r.Method, path)
			reqLog.mu.Lock()
			reqLog.teams = append(reqLog.teams, fmt.Sprintf("%s %s", r.Method, path))
			reqLog.mu.Unlock()

			switch {
			case strings.Contains(path, "/messages/") && strings.HasSuffix(path, "/replies") && r.Method == http.MethodPost:
				teamsReplyMessage(w, r)
			case strings.HasSuffix(path, "/messages") && r.Method == http.MethodPost:
				teamsSendMessage(w, r)
			case strings.HasSuffix(path, "/channels") && r.Method == http.MethodPost:
				teamsCreateChannel(w, r)
			default:
				writeJSON(w, http.StatusNotFound, map[string]any{
					"error": map[string]any{"code": "itemNotFound", "message": "Resource not found"},
				})
			}
		})
		// Request log endpoint
		mux.HandleFunc("/test/requests", func(w http.ResponseWriter, r *http.Request) {
			reqLog.mu.Lock()
			defer reqLog.mu.Unlock()
			writeJSON(w, http.StatusOK, map[string]any{"requests": reqLog.teams, "count": len(reqLog.teams)})
		})
		log.Printf("mock Teams Graph API listening on :%s", teamsPort)
		if err := http.ListenAndServe(":"+teamsPort, mux); err != nil {
			log.Fatalf("Teams mock: %v", err)
		}
	}()

	wg.Wait()
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// ---- Discord handlers ----

func discordSendMessage(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	id := discordMsgCounter.Add(1)
	msgID := fmt.Sprintf("mock-discord-msg-%d", id)
	channelID := extractSegment(r.URL.Path, "channels")
	resp := map[string]any{
		"id":         msgID,
		"channel_id": channelID,
		"type":       0,
	}
	if content, ok := body["content"]; ok {
		resp["content"] = content
	}
	writeJSON(w, http.StatusOK, resp)
}

func discordCreateThread(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	name, _ := body["name"].(string)
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":         "mock-discord-thread-1001",
		"type":       11,
		"name":       name,
		"channel_id": extractSegment(r.URL.Path, "channels"),
	})
}

// ---- Teams handlers ----

func teamsSendMessage(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	id := teamsMsgCounter.Add(1)
	msgID := fmt.Sprintf("mock-teams-msg-%d", id)
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":              msgID,
		"createdDateTime": "2026-03-14T00:00:00Z",
		"messageType":     "message",
		"webUrl":          fmt.Sprintf("https://teams.microsoft.com/mock/message/%s", msgID),
	})
}

func teamsReplyMessage(w http.ResponseWriter, r *http.Request) {
	id := teamsMsgCounter.Add(1)
	replyID := fmt.Sprintf("mock-teams-reply-%d", id)
	msgID := extractSegment(r.URL.Path, "messages")
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":              replyID,
		"replyToId":       msgID,
		"createdDateTime": "2026-03-14T00:00:00Z",
		"messageType":     "message",
	})
}

func teamsCreateChannel(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	id := teamsChanCounter.Add(1)
	chanID := fmt.Sprintf("mock-teams-channel-%d", id)
	name, _ := body["displayName"].(string)
	desc, _ := body["description"].(string)
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":             chanID,
		"displayName":    name,
		"description":    desc,
		"membershipType": "standard",
		"webUrl":         fmt.Sprintf("https://teams.microsoft.com/mock/channel/%s", chanID),
	})
}

// extractSegment gets the value after a path segment keyword, e.g. after "channels" or "messages"
func extractSegment(path, after string) string {
	parts := strings.Split(path, "/")
	for i, p := range parts {
		if p == after && i+1 < len(parts) {
			return parts[i+1]
		}
	}
	return "unknown"
}
