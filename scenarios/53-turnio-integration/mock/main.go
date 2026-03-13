// mock-turnio: standalone mock HTTP server simulating the turn.io WhatsApp API.
// Listens on MOCK_PORT (default 19053) and handles turn.io REST endpoints.
// Returns canned responses with rate limit headers on every response.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

func rateLimit(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Ratelimit-Limit", "100")
	w.Header().Set("X-Ratelimit-Remaining", "95")
	w.Header().Set("X-Ratelimit-Reset", fmt.Sprintf("%d", time.Now().Add(60*time.Second).Unix()))
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	rateLimit(w)
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("encode error: %v", err)
	}
}

func handleMessages(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"messages": []interface{}{
				map[string]interface{}{
					"id": "wamid.HBgLMTIzNDU2Nzg5MBUCABIYFDNBQzVBNjY4RkFBMkI1QkFBQkFBAA==",
				},
			},
		})
	case http.MethodGet:
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"messages": []interface{}{
				map[string]interface{}{
					"id":        "wamid.HBgLMTIzNDU2Nzg5MBUCABIYFDNBQzVBNjY4RkFBMkI1QkFBQkFBAA==",
					"type":      "text",
					"timestamp": fmt.Sprintf("%d", time.Now().Unix()),
					"from":      "1234567890",
				},
			},
		})
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func handleContacts(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"contacts": []interface{}{
			map[string]interface{}{
				"input":  "+1234567890",
				"status": "valid",
				"wa_id":  "1234567890",
			},
		},
	})
}

func handleTemplates(w http.ResponseWriter, r *http.Request, templateID string) {
	switch r.Method {
	case http.MethodGet:
		if templateID != "" {
			writeJSON(w, http.StatusOK, map[string]interface{}{
				"id":       templateID,
				"name":     "hello_world",
				"status":   "APPROVED",
				"language": "en",
				"category": "UTILITY",
			})
			return
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"waba_templates": []interface{}{
				map[string]interface{}{
					"id":       "tmpl_001",
					"name":     "hello_world",
					"status":   "APPROVED",
					"language": "en",
					"category": "UTILITY",
				},
				map[string]interface{}{
					"id":       "tmpl_002",
					"name":     "order_confirmation",
					"status":   "APPROVED",
					"language": "en",
					"category": "TRANSACTIONAL",
				},
			},
		})
	case http.MethodPost:
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"id":       "tmpl_new_001",
			"name":     "new_template",
			"status":   "PENDING",
			"language": "en",
			"category": "UTILITY",
		})
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func handleFlows(w http.ResponseWriter, r *http.Request, flowID string) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"flows": []interface{}{
				map[string]interface{}{
					"id":     "flow_abc123",
					"name":   "onboarding-flow",
					"status": "published",
				},
				map[string]interface{}{
					"id":     "flow_def456",
					"name":   "support-flow",
					"status": "draft",
				},
			},
		})
	case http.MethodPost:
		if flowID != "" {
			// send flow
			writeJSON(w, http.StatusOK, map[string]interface{}{
				"messages": []interface{}{
					map[string]interface{}{
						"id": "wamid.HBgLMTIzNDU2Nzg5MBUCABIYFDNBQzVBNjY4RkFBMkI1QkFBQkFBAA==",
					},
				},
			})
			return
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"id":     "flow_new_001",
			"name":   "my-new-flow",
			"status": "draft",
		})
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func route(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	log.Printf("%s %s", r.Method, path)

	switch {
	case path == "/v1/messages":
		handleMessages(w, r)

	case path == "/v1/contacts":
		handleContacts(w, r)

	case path == "/v1/configs/templates":
		handleTemplates(w, r, "")

	case strings.HasPrefix(path, "/v1/configs/templates/"):
		tmplID := strings.TrimPrefix(path, "/v1/configs/templates/")
		handleTemplates(w, r, tmplID)

	case path == "/v1/flows":
		handleFlows(w, r, "")

	case strings.HasPrefix(path, "/v1/flows/") && strings.HasSuffix(path, "/send"):
		flowID := strings.TrimPrefix(path, "/v1/flows/")
		flowID = strings.TrimSuffix(flowID, "/send")
		handleFlows(w, r, flowID)

	case path == "/healthz":
		rateLimit(w)
		_, _ = w.Write([]byte(`{"status":"ok"}`))

	default:
		http.NotFound(w, r)
	}
}

func main() {
	port := os.Getenv("MOCK_PORT")
	if port == "" {
		port = "19053"
	}
	addr := ":" + port
	http.HandleFunc("/", route)
	log.Printf("mock turn.io API listening on %s", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
