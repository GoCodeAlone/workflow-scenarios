// Mock Datadog API server for scenario 55-datadog-integration.
// Returns canned Datadog JSON responses for metrics, events, monitors,
// dashboards, hosts, and logs APIs.
// Usage: MOCK_PORT=19055 ./mock-datadog
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

func main() {
	port := os.Getenv("MOCK_PORT")
	if port == "" {
		port = "19055"
	}
	mux := http.NewServeMux()

	// Metrics v2
	mux.HandleFunc("/api/v2/series", handleMetricSubmit)

	// Events v1
	mux.HandleFunc("/api/v1/events", handleEvents)
	mux.HandleFunc("/api/v1/events/", handleEventByID)

	// Monitors v1
	mux.HandleFunc("/api/v1/monitor", handleMonitors)
	mux.HandleFunc("/api/v1/monitor/", handleMonitorByID)
	mux.HandleFunc("/api/v1/monitor/search", handleMonitorSearch)
	mux.HandleFunc("/api/v1/monitor/validate", handleMonitorValidate)

	// Dashboards v1
	mux.HandleFunc("/api/v1/dashboard", handleDashboards)
	mux.HandleFunc("/api/v1/dashboard/", handleDashboardByID)

	// Hosts v1
	mux.HandleFunc("/api/v1/hosts", handleHosts)
	mux.HandleFunc("/api/v1/hosts/", handleHostByName)

	// Logs v2 submit
	mux.HandleFunc("/api/v2/logs", handleLogSubmit)

	// Logs v1 list (search)
	mux.HandleFunc("/api/v1/logs-queries/list", handleLogSearch)

	// Logs v2 analytics aggregate
	mux.HandleFunc("/api/v2/logs/analytics/aggregate", handleLogAggregate)

	// Catch-all for debugging
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("unmatched: %s %s", r.Method, r.URL.Path)
		writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
	})

	addr := ":" + port
	log.Printf("mock Datadog API listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// ---- Metrics ----

func handleMetricSubmit(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]any{
		"errors": []any{},
	})
}

// ---- Events ----

func handleEvents(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		handleEventCreate(w, r)
	case http.MethodGet:
		handleEventList(w, r)
	default:
		http.NotFound(w, r)
	}
}

func handleEventCreate(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	title, _ := body["title"].(string)
	writeJSON(w, http.StatusAccepted, map[string]any{
		"status": "ok",
		"event": map[string]any{
			"id":          int64(1234567890),
			"title":       title,
			"date_happened": time.Now().Unix(),
			"url":         fmt.Sprintf("https://app.datadoghq.com/event/event?id=%d", 1234567890),
		},
	})
}

func handleEventByID(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.NotFound(w, r)
		return
	}
	idStr := strings.TrimPrefix(r.URL.Path, "/api/v1/events/")
	eventID, _ := strconv.ParseInt(idStr, 10, 64)
	if eventID == 0 {
		eventID = 1234567890
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"event": map[string]any{
			"id":            eventID,
			"title":         "Test Event",
			"text":          "Event description text",
			"host":          "web-01",
			"date_happened": time.Now().Unix(),
			"url":           fmt.Sprintf("https://app.datadoghq.com/event/event?id=%d", eventID),
		},
	})
}

func handleEventList(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"events": []map[string]any{
			{
				"id":            int64(1234567890),
				"title":         "Deploy v1.2",
				"text":          "Deployed to production",
				"host":          "web-01",
				"date_happened": time.Now().Unix(),
			},
			{
				"id":            int64(1234567891),
				"title":         "Scale up",
				"text":          "Added 3 instances",
				"host":          "web-02",
				"date_happened": time.Now().Unix(),
			},
		},
	})
}

// ---- Monitors ----

func handleMonitors(w http.ResponseWriter, r *http.Request) {
	// /api/v1/monitor without trailing slash
	switch r.Method {
	case http.MethodPost:
		handleMonitorCreate(w, r)
	case http.MethodGet:
		handleMonitorList(w, r)
	default:
		http.NotFound(w, r)
	}
}

func handleMonitorCreate(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	name, _ := body["name"].(string)
	query, _ := body["query"].(string)
	writeJSON(w, http.StatusOK, map[string]any{
		"id":      int64(55001),
		"name":    name,
		"type":    "metric alert",
		"query":   query,
		"message": body["message"],
		"created": time.Now().UTC().Format(time.RFC3339),
	})
}

func handleMonitorByID(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/monitor/")
	// Handle sub-routes like search and validate
	if path == "search" {
		handleMonitorSearch(w, r)
		return
	}
	if path == "validate" {
		handleMonitorValidate(w, r)
		return
	}
	idStr := strings.Split(path, "/")[0]
	monitorID, _ := strconv.ParseInt(idStr, 10, 64)
	if monitorID == 0 {
		monitorID = 55001
	}

	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, map[string]any{
			"id":      monitorID,
			"name":    "CPU Alert",
			"type":    "metric alert",
			"query":   "avg(last_5m):avg:cpu.usage{*} > 90",
			"message": "CPU is high",
		})
	case http.MethodPut:
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		name := "Updated Monitor"
		if n, ok := body["name"].(string); ok && n != "" {
			name = n
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"id":   monitorID,
			"name": name,
		})
	case http.MethodDelete:
		writeJSON(w, http.StatusOK, map[string]any{
			"deleted_monitor_id": monitorID,
		})
	default:
		http.NotFound(w, r)
	}
}

func handleMonitorList(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, []map[string]any{
		{
			"id":    int64(55001),
			"name":  "CPU Alert",
			"type":  "metric alert",
			"query": "avg(last_5m):avg:cpu.usage{*} > 90",
		},
		{
			"id":    int64(55002),
			"name":  "Memory Alert",
			"type":  "metric alert",
			"query": "avg(last_5m):avg:mem.usage{*} > 85",
		},
	})
}

func handleMonitorSearch(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"monitors": []map[string]any{
			{
				"id":   int64(55001),
				"name": "CPU Alert",
			},
		},
		"metadata": map[string]any{
			"total_count": 1,
		},
	})
}

func handleMonitorValidate(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{})
}

// ---- Dashboards ----

func handleDashboards(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		handleDashboardCreate(w, r)
	case http.MethodGet:
		handleDashboardList(w, r)
	default:
		http.NotFound(w, r)
	}
}

func handleDashboardCreate(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	title, _ := body["title"].(string)
	writeJSON(w, http.StatusOK, map[string]any{
		"id":          "dash-abc-123",
		"title":       title,
		"layout_type": "ordered",
		"url":         "/dashboard/dash-abc-123/test-dashboard",
		"widgets":     []any{},
		"created_at":  time.Now().UTC().Format(time.RFC3339),
	})
}

func handleDashboardByID(w http.ResponseWriter, r *http.Request) {
	dashID := strings.TrimPrefix(r.URL.Path, "/api/v1/dashboard/")
	if dashID == "" {
		dashID = "dash-abc-123"
	}

	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, map[string]any{
			"id":          dashID,
			"title":       "Test Dashboard",
			"description": "A test dashboard",
			"layout_type": "ordered",
			"url":         fmt.Sprintf("/dashboard/%s/test-dashboard", dashID),
			"widgets":     []any{},
		})
	case http.MethodPut:
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		title := "Updated Dashboard"
		if t, ok := body["title"].(string); ok && t != "" {
			title = t
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"id":    dashID,
			"title": title,
		})
	case http.MethodDelete:
		writeJSON(w, http.StatusOK, map[string]any{
			"deleted_dashboard_id": dashID,
		})
	default:
		http.NotFound(w, r)
	}
}

func handleDashboardList(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"dashboards": []map[string]any{
			{
				"id":    "dash-abc-123",
				"title": "System Overview",
				"url":   "/dashboard/dash-abc-123/system-overview",
			},
			{
				"id":    "dash-def-456",
				"title": "Application Metrics",
				"url":   "/dashboard/dash-def-456/application-metrics",
			},
		},
	})
}

// ---- Hosts ----

func handleHosts(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.NotFound(w, r)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"host_list": []map[string]any{
			{
				"name":    "web-01",
				"id":      int64(100001),
				"up":      true,
				"apps":    []string{"nginx", "nodejs"},
				"host_name": "web-01",
			},
			{
				"name":    "web-02",
				"id":      int64(100002),
				"up":      true,
				"apps":    []string{"nginx"},
				"host_name": "web-02",
			},
			{
				"name":    "db-01",
				"id":      int64(100003),
				"up":      true,
				"apps":    []string{"postgresql"},
				"host_name": "db-01",
			},
		},
		"total_matching": 3,
		"total_returned": 3,
	})
}

func handleHostByName(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/hosts/")
	if path == "" {
		http.NotFound(w, r)
		return
	}
	// Mute/unmute
	if strings.HasSuffix(path, "/mute") {
		hostName := strings.TrimSuffix(path, "/mute")
		writeJSON(w, http.StatusOK, map[string]any{
			"hostname": hostName,
			"action":   "Muted",
		})
		return
	}
	if strings.HasSuffix(path, "/unmute") {
		hostName := strings.TrimSuffix(path, "/unmute")
		writeJSON(w, http.StatusOK, map[string]any{
			"hostname": hostName,
			"action":   "Unmuted",
		})
		return
	}
	// Host totals
	if path == "totals" {
		writeJSON(w, http.StatusOK, map[string]any{
			"total_active": int64(3),
			"total_up":     int64(3),
		})
		return
	}
	http.NotFound(w, r)
}

// ---- Logs ----

func handleLogSubmit(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{})
}

func handleLogSearch(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"logs": []map[string]any{
			{
				"id": "log-001",
				"content": map[string]any{
					"message": "Application started successfully",
				},
			},
			{
				"id": "log-002",
				"content": map[string]any{
					"message": "Request processed in 42ms",
				},
			},
		},
	})
}

func handleLogAggregate(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"data": map[string]any{
			"buckets": []map[string]any{
				{
					"by": map[string]any{
						"service": "myapp",
					},
				},
			},
		},
	})
}
