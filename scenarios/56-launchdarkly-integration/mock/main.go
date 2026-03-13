// Mock LaunchDarkly API server for scenario 56-launchdarkly-integration.
// Returns canned LaunchDarkly v2 JSON responses for flags, projects, environments, and segments.
// Usage: MOCK_PORT=19056 ./mock-launchdarkly
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

func main() {
	port := os.Getenv("MOCK_PORT")
	if port == "" {
		port = "19056"
	}
	mux := http.NewServeMux()

	// Projects
	mux.HandleFunc("/api/v2/projects", handleProjects)
	// Flags — must register before projects to avoid prefix conflict
	mux.HandleFunc("/api/v2/flags/", handleFlags)
	// Projects with key (and sub-resources like environments)
	mux.HandleFunc("/api/v2/projects/", handleProjectsWithKey)
	// Segments
	mux.HandleFunc("/api/v2/segments/", handleSegments)

	addr := ":" + port
	log.Printf("mock LaunchDarkly API listening on %s", addr)
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
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	if body == nil {
		body = map[string]any{}
	}
	return body
}

// ----------------------------------------------------------------
// Flags: /api/v2/flags/{projKey} and /api/v2/flags/{projKey}/{flagKey}
// ----------------------------------------------------------------
func handleFlags(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/v2/flags/")
	parts := strings.SplitN(path, "/", 2)
	projKey := parts[0]

	if len(parts) == 1 || parts[1] == "" {
		// /api/v2/flags/{projKey}
		switch r.Method {
		case http.MethodGet:
			handleFlagList(w, projKey)
		case http.MethodPost:
			handleFlagCreate(w, r, projKey)
		default:
			http.NotFound(w, r)
		}
		return
	}

	flagKey := parts[1]
	switch r.Method {
	case http.MethodGet:
		handleFlagGet(w, projKey, flagKey)
	case http.MethodPatch:
		handleFlagUpdate(w, r, projKey, flagKey)
	case http.MethodDelete:
		w.WriteHeader(http.StatusNoContent)
	default:
		http.NotFound(w, r)
	}
}

func handleFlagList(w http.ResponseWriter, projKey string) {
	writeJSON(w, http.StatusOK, map[string]any{
		"items": []map[string]any{
			{
				"key":          "enable-new-ui",
				"name":         "Enable New UI",
				"kind":         "boolean",
				"description":  "Toggles the new user interface",
				"creationDate": time.Now().UnixMilli(),
				"variations": []map[string]any{
					{"value": true, "name": "Enabled"},
					{"value": false, "name": "Disabled"},
				},
				"_version": 1,
				"on":       true,
			},
			{
				"key":          "max-items-per-page",
				"name":         "Max Items Per Page",
				"kind":         "multivariate",
				"description":  "Controls pagination size",
				"creationDate": time.Now().UnixMilli(),
				"variations": []map[string]any{
					{"value": 10, "name": "Small"},
					{"value": 25, "name": "Medium"},
					{"value": 50, "name": "Large"},
				},
				"_version": 1,
				"on":       false,
			},
		},
		"totalCount": 2,
		"_links": map[string]any{
			"self": map[string]any{"href": "/api/v2/flags/" + projKey},
		},
	})
}

func handleFlagCreate(w http.ResponseWriter, r *http.Request, projKey string) {
	body := readBody(r)
	key, _ := body["key"].(string)
	name, _ := body["name"].(string)
	kind, _ := body["kind"].(string)
	if kind == "" {
		kind = "boolean"
	}
	if name == "" {
		name = key
	}

	writeJSON(w, http.StatusCreated, map[string]any{
		"key":          key,
		"name":         name,
		"kind":         kind,
		"description":  body["description"],
		"creationDate": time.Now().UnixMilli(),
		"variations": []map[string]any{
			{"value": true, "name": "Enabled"},
			{"value": false, "name": "Disabled"},
		},
		"_version": 1,
		"on":       false,
	})
}

func handleFlagGet(w http.ResponseWriter, projKey, flagKey string) {
	writeJSON(w, http.StatusOK, map[string]any{
		"key":          flagKey,
		"name":         flagKey,
		"kind":         "boolean",
		"description":  "Test flag for " + projKey,
		"creationDate": time.Now().UnixMilli(),
		"variations": []map[string]any{
			{"value": true, "name": "Enabled"},
			{"value": false, "name": "Disabled"},
		},
		"_version": 1,
		"on":       false,
	})
}

func handleFlagUpdate(w http.ResponseWriter, r *http.Request, projKey, flagKey string) {
	_ = readBody(r)
	writeJSON(w, http.StatusOK, map[string]any{
		"key":          flagKey,
		"name":         flagKey,
		"kind":         "boolean",
		"description":  "Updated flag for " + projKey,
		"creationDate": time.Now().UnixMilli(),
		"variations": []map[string]any{
			{"value": true, "name": "Enabled"},
			{"value": false, "name": "Disabled"},
		},
		"_version": 2,
		"on":       true,
	})
}

// ----------------------------------------------------------------
// Projects: /api/v2/projects and /api/v2/projects/{projKey}[/environments[/{envKey}]]
// ----------------------------------------------------------------
func handleProjects(w http.ResponseWriter, r *http.Request) {
	// Exact match /api/v2/projects (no trailing path)
	switch r.Method {
	case http.MethodGet:
		handleProjectList(w)
	case http.MethodPost:
		handleProjectCreate(w, r)
	default:
		http.NotFound(w, r)
	}
}

func handleProjectsWithKey(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/v2/projects/")
	parts := strings.SplitN(path, "/", 3)
	projKey := parts[0]

	if len(parts) == 1 || parts[1] == "" {
		// /api/v2/projects/{projKey}
		switch r.Method {
		case http.MethodGet:
			handleProjectGet(w, projKey)
		default:
			http.NotFound(w, r)
		}
		return
	}

	subResource := parts[1]
	switch subResource {
	case "environments":
		if len(parts) == 3 && parts[2] != "" {
			// /api/v2/projects/{projKey}/environments/{envKey}
			http.NotFound(w, r)
		} else {
			// /api/v2/projects/{projKey}/environments
			switch r.Method {
			case http.MethodGet:
				handleEnvironmentList(w, projKey)
			default:
				http.NotFound(w, r)
			}
		}
	default:
		http.NotFound(w, r)
	}
}

func handleProjectList(w http.ResponseWriter) {
	writeJSON(w, http.StatusOK, map[string]any{
		"items": []map[string]any{
			{
				"key":  "my-project",
				"name": "My Project",
				"tags": []string{"production"},
			},
			{
				"key":  "staging-project",
				"name": "Staging Project",
				"tags": []string{"staging"},
			},
		},
		"totalCount": 2,
		"_links": map[string]any{
			"self": map[string]any{"href": "/api/v2/projects"},
		},
	})
}

func handleProjectCreate(w http.ResponseWriter, r *http.Request) {
	body := readBody(r)
	key, _ := body["key"].(string)
	name, _ := body["name"].(string)
	if name == "" {
		name = key
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"key":  key,
		"name": name,
		"tags": []string{},
		"environments": map[string]any{
			"items": []map[string]any{
				{
					"key":   "production",
					"name":  "Production",
					"color": "417505",
				},
				{
					"key":   "test",
					"name":  "Test",
					"color": "f5a623",
				},
			},
		},
		"_links": map[string]any{
			"self": map[string]any{"href": "/api/v2/projects/" + key},
		},
	})
}

func handleProjectGet(w http.ResponseWriter, projKey string) {
	writeJSON(w, http.StatusOK, map[string]any{
		"key":  projKey,
		"name": projKey,
		"tags": []string{},
		"environments": map[string]any{
			"items": []map[string]any{
				{
					"key":   "production",
					"name":  "Production",
					"color": "417505",
				},
				{
					"key":   "test",
					"name":  "Test",
					"color": "f5a623",
				},
			},
		},
	})
}

// ----------------------------------------------------------------
// Environments: /api/v2/projects/{projKey}/environments
// ----------------------------------------------------------------
func handleEnvironmentList(w http.ResponseWriter, projKey string) {
	writeJSON(w, http.StatusOK, map[string]any{
		"items": []map[string]any{
			{
				"key":     "production",
				"name":    "Production",
				"color":   "417505",
				"_id":     "env-prod-id",
				"apiKey":  "sdk-prod-key-12345",
				"mobileKey": "mob-prod-key-12345",
			},
			{
				"key":     "test",
				"name":    "Test",
				"color":   "f5a623",
				"_id":     "env-test-id",
				"apiKey":  "sdk-test-key-12345",
				"mobileKey": "mob-test-key-12345",
			},
			{
				"key":     "staging",
				"name":    "Staging",
				"color":   "4a90d9",
				"_id":     "env-stg-id",
				"apiKey":  "sdk-stg-key-12345",
				"mobileKey": "mob-stg-key-12345",
			},
		},
		"totalCount": 3,
		"_links": map[string]any{
			"self": map[string]any{"href": "/api/v2/projects/" + projKey + "/environments"},
		},
	})
}

// ----------------------------------------------------------------
// Segments: /api/v2/segments/{projKey}/{envKey}[/{segKey}]
// ----------------------------------------------------------------
func handleSegments(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/v2/segments/")
	parts := strings.SplitN(path, "/", 3)
	if len(parts) < 2 {
		http.NotFound(w, r)
		return
	}

	envKey := parts[1]

	if len(parts) == 2 || parts[2] == "" {
		// /api/v2/segments/{projKey}/{envKey}
		switch r.Method {
		case http.MethodGet:
			handleSegmentList(w, envKey)
		case http.MethodPost:
			handleSegmentCreate(w, r, envKey)
		default:
			http.NotFound(w, r)
		}
		return
	}

	// /api/v2/segments/{projKey}/{envKey}/{segKey}
	http.NotFound(w, r)
}

func handleSegmentList(w http.ResponseWriter, envKey string) {
	writeJSON(w, http.StatusOK, map[string]any{
		"items": []map[string]any{
			{
				"key":          "beta-users",
				"name":         "Beta Users",
				"description":  "Users in the beta program",
				"creationDate": time.Now().UnixMilli(),
				"included":     []string{"user-1", "user-2"},
				"excluded":     []string{},
				"_version":     1,
			},
			{
				"key":          "internal-testers",
				"name":         "Internal Testers",
				"description":  "Internal QA team members",
				"creationDate": time.Now().UnixMilli(),
				"included":     []string{"tester-1"},
				"excluded":     []string{},
				"_version":     1,
			},
		},
		"totalCount": 2,
		"_links": map[string]any{
			"self": map[string]any{"href": "/api/v2/segments/default/" + envKey},
		},
	})
}

func handleSegmentCreate(w http.ResponseWriter, r *http.Request, envKey string) {
	body := readBody(r)
	key, _ := body["key"].(string)
	name, _ := body["name"].(string)
	desc, _ := body["description"].(string)

	writeJSON(w, http.StatusCreated, map[string]any{
		"key":          key,
		"name":         name,
		"description":  desc,
		"creationDate": time.Now().UnixMilli(),
		"included":     []string{},
		"excluded":     []string{},
		"_version":     1,
	})
}
