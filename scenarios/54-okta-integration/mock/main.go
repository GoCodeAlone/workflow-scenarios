// Mock Okta API server for scenario 54-okta-integration.
// Returns canned Okta REST API v1 JSON responses for users, groups, and apps.
// Usage: MOCK_PORT=19054 ./mock-okta
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

func main() {
	port := os.Getenv("MOCK_PORT")
	if port == "" {
		port = "19054"
	}
	mux := http.NewServeMux()

	// Users
	mux.HandleFunc("/api/v1/users", handleUsers)
	mux.HandleFunc("/api/v1/users/", handleUserByID)

	// Groups
	mux.HandleFunc("/api/v1/groups", handleGroups)
	mux.HandleFunc("/api/v1/groups/", handleGroupByID)

	// Apps
	mux.HandleFunc("/api/v1/apps", handleApps)
	mux.HandleFunc("/api/v1/apps/", handleAppByID)

	addr := ":" + port
	log.Printf("mock Okta API listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func readBody(r *http.Request) map[string]any {
	body := map[string]any{}
	if r.Body != nil {
		data, _ := io.ReadAll(r.Body)
		if len(data) > 0 {
			_ = json.Unmarshal(data, &body)
		}
	}
	return body
}

func nowISO() string {
	return time.Now().UTC().Format(time.RFC3339)
}

// handleUsers handles /api/v1/users (no trailing slash)
func handleUsers(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		handleListUsers(w, r)
	case http.MethodPost:
		handleCreateUser(w, r)
	default:
		http.NotFound(w, r)
	}
}

// handleUserByID handles /api/v1/users/{id} and sub-paths
func handleUserByID(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/users/")
	parts := strings.SplitN(path, "/", 3)
	userID := parts[0]

	if len(parts) == 1 {
		switch r.Method {
		case http.MethodGet:
			handleGetUser(w, r, userID)
		case http.MethodPost:
			handleUpdateUser(w, r, userID)
		case http.MethodDelete:
			handleDeleteUser(w, r, userID)
		default:
			http.NotFound(w, r)
		}
		return
	}

	// Sub-resource: /api/v1/users/{id}/lifecycle/{action}
	subResource := parts[1]
	if subResource == "lifecycle" && len(parts) == 3 {
		action := parts[2]
		switch action {
		case "activate":
			writeJSON(w, http.StatusOK, map[string]any{"activationUrl": "https://mock.okta.com/activate/token123"})
		case "deactivate":
			writeJSON(w, http.StatusOK, map[string]any{})
		case "suspend":
			writeJSON(w, http.StatusOK, map[string]any{})
		case "unsuspend":
			writeJSON(w, http.StatusOK, map[string]any{})
		case "unlock":
			writeJSON(w, http.StatusOK, map[string]any{})
		case "reset_factors":
			writeJSON(w, http.StatusOK, map[string]any{})
		case "reset_password":
			writeJSON(w, http.StatusOK, map[string]any{"resetPasswordUrl": "https://mock.okta.com/reset/token123"})
		case "reactivate":
			writeJSON(w, http.StatusOK, map[string]any{"activationUrl": "https://mock.okta.com/activate/token456"})
		default:
			http.NotFound(w, r)
		}
		return
	}

	// Sub-resource: /api/v1/users/{id}/credentials/change_password
	if subResource == "credentials" && len(parts) == 3 {
		writeJSON(w, http.StatusOK, map[string]any{
			"provider": map[string]any{"type": "OKTA", "name": "OKTA"},
		})
		return
	}

	http.NotFound(w, r)
}

func handleCreateUser(w http.ResponseWriter, r *http.Request) {
	body := readBody(r)
	profile, _ := body["profile"].(map[string]any)
	if profile == nil {
		profile = map[string]any{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id":      "00u1abcdef1234567890",
		"status":  "STAGED",
		"created": nowISO(),
		"profile": profile,
		"_links": map[string]any{
			"self": map[string]any{"href": "https://mock.okta.com/api/v1/users/00u1abcdef1234567890"},
		},
	})
}

func handleGetUser(w http.ResponseWriter, r *http.Request, userID string) {
	writeJSON(w, http.StatusOK, map[string]any{
		"id":      userID,
		"status":  "ACTIVE",
		"created": nowISO(),
		"profile": map[string]any{
			"firstName": "Jane",
			"lastName":  "Doe",
			"email":     "jane.doe@example.com",
			"login":     "jane.doe@example.com",
		},
		"_links": map[string]any{
			"self": map[string]any{"href": fmt.Sprintf("https://mock.okta.com/api/v1/users/%s", userID)},
		},
	})
}

func handleListUsers(w http.ResponseWriter, r *http.Request) {
	users := []map[string]any{
		{
			"id":     "00u1abcdef1234567890",
			"status": "ACTIVE",
			"profile": map[string]any{
				"firstName": "Jane",
				"lastName":  "Doe",
				"email":     "jane.doe@example.com",
				"login":     "jane.doe@example.com",
			},
		},
		{
			"id":     "00u2abcdef1234567890",
			"status": "ACTIVE",
			"profile": map[string]any{
				"firstName": "John",
				"lastName":  "Smith",
				"email":     "john.smith@example.com",
				"login":     "john.smith@example.com",
			},
		},
	}
	writeJSON(w, http.StatusOK, users)
}

func handleUpdateUser(w http.ResponseWriter, r *http.Request, userID string) {
	body := readBody(r)
	profile, _ := body["profile"].(map[string]any)
	if profile == nil {
		profile = map[string]any{
			"firstName": "Updated",
			"lastName":  "User",
			"email":     "updated@example.com",
			"login":     "updated@example.com",
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id":      userID,
		"status":  "ACTIVE",
		"created": nowISO(),
		"profile": profile,
	})
}

func handleDeleteUser(w http.ResponseWriter, r *http.Request, userID string) {
	w.WriteHeader(http.StatusNoContent)
}

// handleGroups handles /api/v1/groups (no trailing slash)
func handleGroups(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		handleListGroups(w, r)
	case http.MethodPost:
		handleCreateGroup(w, r)
	default:
		http.NotFound(w, r)
	}
}

// handleGroupByID handles /api/v1/groups/{id} and sub-paths
func handleGroupByID(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/groups/")
	parts := strings.SplitN(path, "/", 4)
	groupID := parts[0]

	if len(parts) == 1 {
		switch r.Method {
		case http.MethodGet:
			handleGetGroup(w, r, groupID)
		case http.MethodDelete:
			w.WriteHeader(http.StatusNoContent)
		default:
			http.NotFound(w, r)
		}
		return
	}

	// /api/v1/groups/{id}/users or /api/v1/groups/{id}/users/{userId}
	if parts[1] == "users" {
		if len(parts) == 2 {
			// GET /api/v1/groups/{id}/users
			handleListGroupUsers(w, r, groupID)
			return
		}
		if len(parts) >= 3 {
			userID := parts[2]
			switch r.Method {
			case http.MethodPut, http.MethodPost:
				// PUT or POST /api/v1/groups/{id}/users/{userId}
				_ = userID
				w.WriteHeader(http.StatusNoContent)
			case http.MethodDelete:
				_ = userID
				w.WriteHeader(http.StatusNoContent)
			default:
				http.NotFound(w, r)
			}
			return
		}
	}

	http.NotFound(w, r)
}

func handleCreateGroup(w http.ResponseWriter, r *http.Request) {
	body := readBody(r)
	profile, _ := body["profile"].(map[string]any)
	if profile == nil {
		profile = map[string]any{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id":      "00g1abcdef1234567890",
		"created": nowISO(),
		"profile": profile,
		"type":    "OKTA_GROUP",
		"_links": map[string]any{
			"self": map[string]any{"href": "https://mock.okta.com/api/v1/groups/00g1abcdef1234567890"},
		},
	})
}

func handleGetGroup(w http.ResponseWriter, r *http.Request, groupID string) {
	writeJSON(w, http.StatusOK, map[string]any{
		"id":      groupID,
		"created": nowISO(),
		"profile": map[string]any{
			"name":        "Test Group",
			"description": "A test group",
		},
		"type": "OKTA_GROUP",
	})
}

func handleListGroups(w http.ResponseWriter, r *http.Request) {
	groups := []map[string]any{
		{
			"id":   "00g1abcdef1234567890",
			"type": "OKTA_GROUP",
			"profile": map[string]any{
				"name":        "Engineering",
				"description": "Engineering team",
			},
		},
		{
			"id":   "00g2abcdef1234567890",
			"type": "OKTA_GROUP",
			"profile": map[string]any{
				"name":        "Marketing",
				"description": "Marketing team",
			},
		},
	}
	writeJSON(w, http.StatusOK, groups)
}

func handleListGroupUsers(w http.ResponseWriter, r *http.Request, groupID string) {
	users := []map[string]any{
		{
			"id":     "00u1abcdef1234567890",
			"status": "ACTIVE",
			"profile": map[string]any{
				"firstName": "Jane",
				"lastName":  "Doe",
				"email":     "jane.doe@example.com",
				"login":     "jane.doe@example.com",
			},
		},
	}
	writeJSON(w, http.StatusOK, users)
}

// handleApps handles /api/v1/apps (no trailing slash)
func handleApps(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		handleListApps(w, r)
	case http.MethodPost:
		handleCreateApp(w, r)
	default:
		http.NotFound(w, r)
	}
}

// handleAppByID handles /api/v1/apps/{id} and sub-paths
func handleAppByID(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/apps/")
	parts := strings.SplitN(path, "/", 3)
	appID := parts[0]

	if len(parts) == 1 {
		switch r.Method {
		case http.MethodGet:
			handleGetApp(w, r, appID)
		default:
			http.NotFound(w, r)
		}
		return
	}
	http.NotFound(w, r)
}

func handleCreateApp(w http.ResponseWriter, r *http.Request) {
	body := readBody(r)
	label, _ := body["label"].(string)
	if label == "" {
		label = "Test App"
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id":         "0oa1abcdef1234567890",
		"name":       body["name"],
		"label":      label,
		"status":     "ACTIVE",
		"signOnMode": body["signOnMode"],
		"created":    nowISO(),
	})
}

func handleGetApp(w http.ResponseWriter, r *http.Request, appID string) {
	writeJSON(w, http.StatusOK, map[string]any{
		"id":         appID,
		"name":       "oidc_client",
		"label":      "Test OIDC App",
		"status":     "ACTIVE",
		"signOnMode": "OPENID_CONNECT",
		"created":    nowISO(),
	})
}

func handleListApps(w http.ResponseWriter, r *http.Request) {
	apps := []map[string]any{
		{
			"id":         "0oa1abcdef1234567890",
			"name":       "oidc_client",
			"label":      "Corporate SSO",
			"status":     "ACTIVE",
			"signOnMode": "OPENID_CONNECT",
		},
		{
			"id":         "0oa2abcdef1234567890",
			"name":       "saml_app",
			"label":      "Internal Wiki",
			"status":     "ACTIVE",
			"signOnMode": "SAML_2_0",
		},
	}
	writeJSON(w, http.StatusOK, apps)
}
