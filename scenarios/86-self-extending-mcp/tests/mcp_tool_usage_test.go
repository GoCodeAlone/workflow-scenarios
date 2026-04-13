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

// TestMCPToolUsage_BaseAppModules verifies db and server modules in base-app.yaml.
func TestMCPToolUsage_BaseAppModules(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "base-app.yaml"))
	for _, check := range []string{"type: database.sqlite", "type: http.server"} {
		if !strings.Contains(content, check) {
			t.Errorf("base-app.yaml missing module: %q", check)
		}
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

// TestMCPToolUsage_AgentHasSelfImproveTools verifies mcp:self_improve:* permission.
func TestMCPToolUsage_AgentHasSelfImproveTools(t *testing.T) {
	data := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	if !strings.Contains(data, `"mcp:self_improve:*"`) {
		t.Error("agent-config.yaml must include mcp:self_improve:* in allowed_tools")
	}
}

// TestMCPToolUsage_DockerComposeHasGemma4 verifies docker-compose.yaml uses gemma4.
func TestMCPToolUsage_DockerComposeHasGemma4(t *testing.T) {
	data := readFile(t, filepath.Join(scenarioDir(t), "docker-compose.yaml"))
	if !strings.Contains(data, "gemma4") {
		t.Error("docker-compose.yaml must reference gemma4 model")
	}
	if !strings.Contains(data, "ollama") {
		t.Error("docker-compose.yaml must include ollama service")
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
