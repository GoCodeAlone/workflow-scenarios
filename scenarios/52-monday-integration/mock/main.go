// mock-monday: standalone mock HTTP server simulating the monday.com GraphQL API.
// Listens on MOCK_PORT (default 19052) and handles POST /v2.
// Matches on keywords in the query string to return canned responses.
package main

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
)

type graphQLRequest struct {
	Query     string                 `json:"query"`
	Variables map[string]interface{} `json:"variables"`
}

func handler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, "failed to read request body")
		return
	}
	defer r.Body.Close()

	var req graphQLRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeError(w, "invalid JSON: "+err.Error())
		return
	}

	q := strings.ToLower(req.Query)
	w.Header().Set("Content-Type", "application/json")

	var resp interface{}
	switch {
	case strings.Contains(q, "create_board") || (strings.Contains(q, "create_board") && strings.Contains(q, "mutation")):
		resp = map[string]interface{}{
			"data": map[string]interface{}{
				"create_board": map[string]interface{}{
					"id":    "1234567890",
					"name":  varString(req.Variables, "board_name", "New Board"),
					"state": "active",
				},
			},
		}
	case strings.Contains(q, "create_item") || (strings.Contains(q, "create_item") && strings.Contains(q, "mutation")):
		resp = map[string]interface{}{
			"data": map[string]interface{}{
				"create_item": map[string]interface{}{
					"id":   "9876543210",
					"name": varString(req.Variables, "item_name", "New Item"),
				},
			},
		}
	case strings.Contains(q, "create_group") || (strings.Contains(q, "create_group") && strings.Contains(q, "mutation")):
		resp = map[string]interface{}{
			"data": map[string]interface{}{
				"create_group": map[string]interface{}{
					"id":    "group_abc123",
					"title": varString(req.Variables, "group_name", "New Group"),
				},
			},
		}
	case strings.Contains(q, "create_workspace") || (strings.Contains(q, "create_workspace") && strings.Contains(q, "mutation")):
		resp = map[string]interface{}{
			"data": map[string]interface{}{
				"create_workspace": map[string]interface{}{
					"id":   "777888999",
					"name": varString(req.Variables, "workspace_name", "New Workspace"),
				},
			},
		}
	case strings.Contains(q, "items_page_by_column_values") || strings.Contains(q, "items_page"):
		resp = map[string]interface{}{
			"data": map[string]interface{}{
				"items_page_by_column_values": map[string]interface{}{
					"cursor": nil,
					"items": []interface{}{
						map[string]interface{}{
							"id":   "9876543210",
							"name": "Sample Item 1",
						},
						map[string]interface{}{
							"id":   "9876543211",
							"name": "Sample Item 2",
						},
					},
				},
			},
		}
	case strings.Contains(q, "boards") && strings.Contains(q, "groups"):
		resp = map[string]interface{}{
			"data": map[string]interface{}{
				"boards": []interface{}{
					map[string]interface{}{
						"id":   "1234567890",
						"name": "Main Board",
						"groups": []interface{}{
							map[string]interface{}{
								"id":    "group_abc123",
								"title": "Group Alpha",
							},
							map[string]interface{}{
								"id":    "group_def456",
								"title": "Group Beta",
							},
						},
					},
				},
			},
		}
	case strings.Contains(q, "boards"):
		resp = map[string]interface{}{
			"data": map[string]interface{}{
				"boards": []interface{}{
					map[string]interface{}{
						"id":         "1234567890",
						"name":       "Main Board",
						"board_kind": "public",
						"state":      "active",
					},
					map[string]interface{}{
						"id":         "1234567891",
						"name":       "Secondary Board",
						"board_kind": "private",
						"state":      "active",
					},
				},
			},
		}
	case strings.Contains(q, "users"):
		resp = map[string]interface{}{
			"data": map[string]interface{}{
				"users": []interface{}{
					map[string]interface{}{
						"id":    "111222333",
						"name":  "Alice Smith",
						"email": "alice@example.com",
					},
					map[string]interface{}{
						"id":    "444555666",
						"name":  "Bob Jones",
						"email": "bob@example.com",
					},
				},
			},
		}
	default:
		// Generic query: echo back a data wrapper
		resp = map[string]interface{}{
			"data": map[string]interface{}{
				"result": "ok",
				"query":  req.Query,
			},
		}
	}

	if err := json.NewEncoder(w).Encode(resp); err != nil {
		log.Printf("encode error: %v", err)
	}
}

func writeError(w http.ResponseWriter, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusBadRequest)
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"errors": []interface{}{
			map[string]interface{}{"message": msg},
		},
	})
}

func varString(vars map[string]interface{}, key, fallback string) string {
	if vars == nil {
		return fallback
	}
	if v, ok := vars[key]; ok {
		if s, ok := v.(string); ok && s != "" {
			return s
		}
	}
	return fallback
}

func main() {
	port := os.Getenv("MOCK_PORT")
	if port == "" {
		port = "19052"
	}
	addr := ":" + port
	http.HandleFunc("/v2", handler)
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	log.Printf("mock monday.com API listening on %s", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
