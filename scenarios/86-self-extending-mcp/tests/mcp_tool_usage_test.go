package tests

import (
	"path/filepath"
	"strings"
	"testing"
)

// TestMCPToolUsage_BaseAppHasCRUDPipelines verifies base-app.yaml has required pipelines.
func TestMCPToolUsage_BaseAppHasCRUDPipelines(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "base-app.yaml"))
	pipelines := []string{
		"health_check:", "list_tasks:", "create_task:",
		"get_task:", "update_task:", "delete_task:",
	}
	for _, p := range pipelines {
		if !strings.Contains(content, p) {
			t.Errorf("base-app.yaml missing pipeline %q", p)
		}
	}
}

// TestMCPToolUsage_BaseAppHasTriggers verifies each pipeline has a trigger block.
func TestMCPToolUsage_BaseAppHasTriggers(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "base-app.yaml"))
	routes := []string{
		"path: /healthz",
		"path: /tasks",
		"path: /tasks/{id}",
	}
	for _, r := range routes {
		if !strings.Contains(content, r) {
			t.Errorf("base-app.yaml missing trigger route %q", r)
		}
	}
}

// TestMCPToolUsage_BaseAppModules verifies correct module types in base-app.yaml.
func TestMCPToolUsage_BaseAppModules(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "base-app.yaml"))
	for _, check := range []string{
		"type: storage.sqlite",
		"type: http.server",
		"type: http.router",
		"dbPath: /data/tasks.db",
	} {
		if !strings.Contains(content, check) {
			t.Errorf("base-app.yaml missing: %q", check)
		}
	}
}

// TestMCPToolUsage_BaseAppListFormat verifies modules use list format, not map.
func TestMCPToolUsage_BaseAppListFormat(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "base-app.yaml"))
	if !strings.Contains(content, "- name: db") {
		t.Error("base-app.yaml modules must use list format (- name: db), not map format")
	}
	if !strings.Contains(content, "- name: server") {
		t.Error("base-app.yaml modules must use list format (- name: server), not map format")
	}
}

// TestMCPToolUsage_SeedDataStatusCounts verifies seed SQL has expected record counts.
func TestMCPToolUsage_SeedDataStatusCounts(t *testing.T) {
	data := readFile(t, filepath.Join(scenarioDir(t), "config", "seed-data.sql"))
	tests := []struct {
		status string
		want   int
	}{
		{"'done'", 21},
		{"'in_progress'", 10},
		{"'blocked'", 8},
		{"'review'", 8},
		{"'pending'", 5},
	}
	for _, tc := range tests {
		count := strings.Count(data, tc.status)
		if count < tc.want {
			t.Errorf("seed-data.sql: expected at least %d %s records, found %d", tc.want, tc.status, count)
		}
	}
}

// TestMCPToolUsage_SeedDataHasCompletedAt verifies done tasks have completed_at.
func TestMCPToolUsage_SeedDataHasCompletedAt(t *testing.T) {
	data := readFile(t, filepath.Join(scenarioDir(t), "config", "seed-data.sql"))
	if !strings.Contains(data, "completed_at") {
		t.Error("seed-data.sql must include completed_at for done tasks")
	}
}

// TestMCPToolUsage_SeedDataHasCreateTable verifies seed SQL creates the tasks table.
func TestMCPToolUsage_SeedDataHasCreateTable(t *testing.T) {
	data := readFile(t, filepath.Join(scenarioDir(t), "config", "seed-data.sql"))
	if !strings.Contains(data, "CREATE TABLE IF NOT EXISTS tasks") {
		t.Error("seed-data.sql must include CREATE TABLE IF NOT EXISTS tasks")
	}
}

// TestMCPToolUsage_DockerComposeHasGemma4 verifies docker-compose.yaml references gemma4.
func TestMCPToolUsage_DockerComposeHasGemma4(t *testing.T) {
	data := readFile(t, filepath.Join(scenarioDir(t), "docker-compose.yaml"))
	if !strings.Contains(data, "gemma4") {
		t.Error("docker-compose.yaml must reference gemma4 (e.g. OLLAMA_MODEL=gemma4)")
	}
}

// TestMCPToolUsage_DockerComposeUsesPrebuiltImage verifies pre-built image is used.
func TestMCPToolUsage_DockerComposeUsesPrebuiltImage(t *testing.T) {
	data := readFile(t, filepath.Join(scenarioDir(t), "docker-compose.yaml"))
	if !strings.Contains(data, "ghcr.io/gocodealone/workflow:latest") {
		t.Error("docker-compose.yaml must use ghcr.io/gocodealone/workflow:latest image")
	}
}

// TestMCPToolUsage_DockerComposeHasHealthcheck verifies app service has a healthcheck.
func TestMCPToolUsage_DockerComposeHasHealthcheck(t *testing.T) {
	data := readFile(t, filepath.Join(scenarioDir(t), "docker-compose.yaml"))
	if !strings.Contains(data, "/healthz") {
		t.Error("docker-compose.yaml app service must have a healthcheck pointing to /healthz")
	}
}

// TestMCPToolUsage_DockerComposeServices verifies required services in docker-compose.yaml.
func TestMCPToolUsage_DockerComposeServices(t *testing.T) {
	data := readFile(t, filepath.Join(scenarioDir(t), "docker-compose.yaml"))
	for _, svc := range []string{"ollama:", "app:", "agent:"} {
		if !strings.Contains(data, svc) {
			t.Errorf("docker-compose.yaml missing service %q", svc)
		}
	}
}

// TestMCPToolUsage_ScenarioYAMLExists verifies scenario.yaml is present.
func TestMCPToolUsage_ScenarioYAMLExists(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "scenario.yaml")
	data := readFile(t, cfg)
	if !strings.Contains(data, `id: "86-self-extending-mcp"`) {
		t.Error("scenario.yaml must contain id: \"86-self-extending-mcp\"")
	}
}
