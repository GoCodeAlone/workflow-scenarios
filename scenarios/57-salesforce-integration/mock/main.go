// Mock Salesforce REST API server for scenario 57-salesforce-integration.
// Returns canned Salesforce JSON responses for SObject CRUD, SOQL query,
// describe global, and describe object endpoints.
// Usage: MOCK_PORT=19057 ./mock-salesforce
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
		port = "19057"
	}
	mux := http.NewServeMux()

	// All Salesforce REST API calls go through /services/data/v63.0/...
	mux.HandleFunc("/services/data/v63.0/", handleAPI)

	// Identity / userinfo endpoint
	mux.HandleFunc("/services/oauth2/userinfo", handleUserInfo)

	addr := ":" + port
	log.Printf("mock Salesforce API listening on %s", addr)
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

// handleAPI dispatches requests under /services/data/v63.0/
func handleAPI(w http.ResponseWriter, r *http.Request) {
	// Strip the versioned prefix
	path := strings.TrimPrefix(r.URL.Path, "/services/data/v63.0")

	switch {
	// SOQL query
	case path == "/query" && r.Method == http.MethodGet:
		handleQuery(w, r)

	// Describe global — GET /sobjects
	case path == "/sobjects" && r.Method == http.MethodGet:
		handleDescribeGlobal(w, r)

	// Describe object — GET /sobjects/{type}/describe
	case strings.HasSuffix(path, "/describe") && strings.HasPrefix(path, "/sobjects/") && r.Method == http.MethodGet:
		parts := strings.Split(strings.TrimPrefix(path, "/sobjects/"), "/")
		if len(parts) == 2 && parts[1] == "describe" {
			handleDescribeObject(w, r, parts[0])
			return
		}
		http.NotFound(w, r)

	// Org limits — GET /limits
	case path == "/limits" && r.Method == http.MethodGet:
		handleLimits(w, r)

	// Reports — GET /analytics/reports
	case path == "/analytics/reports" && r.Method == http.MethodGet:
		handleReportList(w, r)

	// SObject CRUD — /sobjects/{type} and /sobjects/{type}/{id}
	case strings.HasPrefix(path, "/sobjects/"):
		handleSObject(w, r, path)

	default:
		log.Printf("unmatched: %s %s", r.Method, r.URL.Path)
		http.NotFound(w, r)
	}
}

// handleSObject handles SObject CRUD operations.
func handleSObject(w http.ResponseWriter, r *http.Request, path string) {
	// path = /sobjects/{type} or /sobjects/{type}/{id}
	trimmed := strings.TrimPrefix(path, "/sobjects/")
	parts := strings.SplitN(trimmed, "/", 2)
	sObjectType := parts[0]

	switch {
	// POST /sobjects/{type} — create record
	case len(parts) == 1 && r.Method == http.MethodPost:
		handleCreateRecord(w, r, sObjectType)

	// GET /sobjects/{type}/{id} — get record
	case len(parts) == 2 && r.Method == http.MethodGet:
		handleGetRecord(w, r, sObjectType, parts[1])

	// PATCH /sobjects/{type}/{id} — update record
	case len(parts) == 2 && r.Method == http.MethodPatch:
		handleUpdateRecord(w, r, sObjectType, parts[1])

	// DELETE /sobjects/{type}/{id} — delete record
	case len(parts) == 2 && r.Method == http.MethodDelete:
		handleDeleteRecord(w, r, sObjectType, parts[1])

	default:
		log.Printf("unmatched sobject: %s %s", r.Method, r.URL.Path)
		http.NotFound(w, r)
	}
}

func handleCreateRecord(w http.ResponseWriter, r *http.Request, sObjectType string) {
	_ = readBody(r)
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":      "001Dn00000ABC123DEF",
		"success": true,
		"errors":  []any{},
	})
}

func handleGetRecord(w http.ResponseWriter, r *http.Request, sObjectType, recordID string) {
	writeJSON(w, http.StatusOK, map[string]any{
		"attributes": map[string]any{
			"type": sObjectType,
			"url":  "/services/data/v63.0/sobjects/" + sObjectType + "/" + recordID,
		},
		"Id":        recordID,
		"Name":      "Acme Corporation",
		"Industry":  "Technology",
		"Website":   "https://acme.example.com",
		"Phone":     "555-0100",
		"CreatedDate": time.Now().UTC().Format(time.RFC3339),
	})
}

func handleUpdateRecord(w http.ResponseWriter, _ *http.Request, sObjectType, recordID string) {
	// Salesforce returns 204 No Content on successful update.
	// The plugin client translates 204 to {"success": true}.
	w.WriteHeader(http.StatusNoContent)
}

func handleDeleteRecord(w http.ResponseWriter, _ *http.Request, sObjectType, recordID string) {
	// Salesforce returns 204 No Content on successful delete.
	w.WriteHeader(http.StatusNoContent)
}

func handleQuery(w http.ResponseWriter, r *http.Request) {
	soql := r.URL.Query().Get("q")
	records := []map[string]any{
		{
			"attributes": map[string]any{"type": "Account", "url": "/services/data/v63.0/sobjects/Account/001Dn00000ABC123DEF"},
			"Id":         "001Dn00000ABC123DEF",
			"Name":       "Acme Corporation",
			"Industry":   "Technology",
		},
		{
			"attributes": map[string]any{"type": "Account", "url": "/services/data/v63.0/sobjects/Account/001Dn00000GHI456JKL"},
			"Id":         "001Dn00000GHI456JKL",
			"Name":       "Global Industries",
			"Industry":   "Manufacturing",
		},
	}
	_ = soql
	writeJSON(w, http.StatusOK, map[string]any{
		"totalSize": 2,
		"done":      true,
		"records":   records,
	})
}

func handleDescribeGlobal(w http.ResponseWriter, r *http.Request) {
	sobjects := []map[string]any{
		{
			"name":       "Account",
			"label":      "Account",
			"keyPrefix":  "001",
			"queryable":  true,
			"createable": true,
			"updateable": true,
			"deletable":  true,
		},
		{
			"name":       "Contact",
			"label":      "Contact",
			"keyPrefix":  "003",
			"queryable":  true,
			"createable": true,
			"updateable": true,
			"deletable":  true,
		},
		{
			"name":       "Opportunity",
			"label":      "Opportunity",
			"keyPrefix":  "006",
			"queryable":  true,
			"createable": true,
			"updateable": true,
			"deletable":  true,
		},
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"encoding":     "UTF-8",
		"maxBatchSize": 200,
		"sobjects":     sobjects,
	})
}

func handleDescribeObject(w http.ResponseWriter, r *http.Request, sObjectType string) {
	fields := []map[string]any{
		{"name": "Id", "type": "id", "label": "Record ID", "length": 18, "nillable": false},
		{"name": "Name", "type": "string", "label": "Name", "length": 255, "nillable": false},
		{"name": "Industry", "type": "picklist", "label": "Industry", "length": 255, "nillable": true},
		{"name": "Website", "type": "url", "label": "Website", "length": 255, "nillable": true},
		{"name": "Phone", "type": "phone", "label": "Phone", "length": 40, "nillable": true},
		{"name": "CreatedDate", "type": "datetime", "label": "Created Date", "length": 0, "nillable": false},
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"name":       sObjectType,
		"label":      sObjectType,
		"queryable":  true,
		"createable": true,
		"updateable": true,
		"deletable":  true,
		"fields":     fields,
	})
}

func handleLimits(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"DailyApiRequests": map[string]any{
			"Max":       100000,
			"Remaining": 99500,
		},
		"DailyBulkApiRequests": map[string]any{
			"Max":       10000,
			"Remaining": 9990,
		},
		"DataStorageMB": map[string]any{
			"Max":       5120,
			"Remaining": 4800,
		},
	})
}

func handleReportList(w http.ResponseWriter, r *http.Request) {
	// Reports endpoint returns an array
	reports := []map[string]any{
		{
			"id":              "00O000000000001",
			"name":            "Pipeline Report",
			"reportFormat":    "TABULAR",
			"describeUrl":     "/services/data/v63.0/analytics/reports/00O000000000001/describe",
			"instancesUrl":    "/services/data/v63.0/analytics/reports/00O000000000001/instances",
		},
		{
			"id":              "00O000000000002",
			"name":            "Q4 Revenue",
			"reportFormat":    "SUMMARY",
			"describeUrl":     "/services/data/v63.0/analytics/reports/00O000000000002/describe",
			"instancesUrl":    "/services/data/v63.0/analytics/reports/00O000000000002/instances",
		},
	}
	// Salesforce report list returns an array at top level
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(reports)
}

func handleUserInfo(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"sub":                "00530000009ABCDE",
		"user_id":            "00530000009ABCDE",
		"organization_id":    "00D300000000001",
		"preferred_username": "admin@acme.example.com",
		"nickname":           "admin",
		"name":               "Admin User",
		"email":              "admin@acme.example.com",
		"email_verified":     true,
		"active":             true,
	})
}
