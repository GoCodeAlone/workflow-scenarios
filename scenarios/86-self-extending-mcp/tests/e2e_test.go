package tests

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

const (
	appBaseURL   = "http://localhost:8080"
	agentBaseURL = "http://localhost:8081"
	e2eTimeout   = 10 * time.Minute
	pollInterval = 10 * time.Second
)

// TestE2EMCPToolCreation runs the full self-extending MCP scenario:
// 1. Base app responds to CRUD
// 2. Agent creates task_analytics as an MCP tool
// 3. Agent uses task_analytics and creates task_forecast
// 4. Both tools are registered and callable
// 5. Blackboard and git history show progression
func TestE2EMCPToolCreation(t *testing.T) {
	if os.Getenv("E2E") != "true" {
		t.Skip("skipping E2E test; set E2E=true to run")
	}

	t.Log("Step 1: verifying base app health")
	waitForURL(t, appBaseURL+"/healthz", e2eTimeout)

	t.Log("Step 2: verifying base app CRUD responds")
	verifyBaseCRUD(t)

	t.Log("Step 3: triggering MCP tool creation pipeline")
	triggerToolCreation(t)

	t.Log("Step 4: waiting for agent to create MCP tools")
	waitForMCPTool(t, "task_analytics", e2eTimeout)
	waitForMCPTool(t, "task_forecast", e2eTimeout)

	t.Log("Step 5: calling task_analytics via MCP")
	analytics := callMCPTool(t, "task_analytics", nil)
	verifyAnalyticsResponse(t, analytics)

	t.Log("Step 6: calling task_forecast via MCP")
	forecast := callMCPTool(t, "task_forecast", nil)
	verifyForecastResponse(t, forecast)

	t.Log("Step 7: verifying blackboard artifacts")
	verifyBlackboardArtifacts(t)

	t.Log("Step 8: verifying git history")
	verifyGitHistory(t)
}

func waitForURL(t *testing.T, url string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(url) //nolint:noctx
		if err == nil && resp.StatusCode == http.StatusOK {
			resp.Body.Close()
			return
		}
		time.Sleep(pollInterval)
	}
	t.Fatalf("timed out waiting for %s", url)
}

func verifyBaseCRUD(t *testing.T) {
	t.Helper()
	// Create a task
	body := strings.NewReader(`{"title":"E2E test task","description":"created by test","priority":"high"}`)
	resp, err := http.Post(appBaseURL+"/tasks", "application/json", body) //nolint:noctx
	if err != nil {
		t.Fatalf("POST /tasks failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("POST /tasks: expected 201, got %d", resp.StatusCode)
	}

	// List tasks
	resp, err = http.Get(appBaseURL + "/tasks") //nolint:noctx
	if err != nil {
		t.Fatalf("GET /tasks failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /tasks: expected 200, got %d", resp.StatusCode)
	}
	var tasks []map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&tasks); err != nil {
		t.Fatalf("decode /tasks response: %v", err)
	}
	if len(tasks) == 0 {
		t.Fatal("expected at least one task from seed data")
	}
}

// triggerToolCreation fires the agent's MCP tool creation pipeline via its HTTP trigger.
func triggerToolCreation(t *testing.T) {
	t.Helper()
	resp, err := http.Post(agentBaseURL+"/create-tools", "application/json", strings.NewReader("{}")) //nolint:noctx
	if err != nil {
		t.Fatalf("POST /create-tools: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 500 {
		t.Fatalf("POST /create-tools: unexpected server error %d", resp.StatusCode)
	}
}

// waitForMCPTool polls until the named MCP tool appears in the app's tool registry.
func waitForMCPTool(t *testing.T, toolName string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(appBaseURL + "/_mcp/tools") //nolint:noctx
		if err == nil && resp.StatusCode == http.StatusOK {
			var tools []map[string]any
			if json.NewDecoder(resp.Body).Decode(&tools) == nil {
				resp.Body.Close()
				for _, tool := range tools {
					if name, ok := tool["name"].(string); ok && name == toolName {
						t.Logf("MCP tool %q is registered", toolName)
						return
					}
				}
			} else {
				resp.Body.Close()
			}
		}
		time.Sleep(pollInterval)
	}
	t.Fatalf("timed out waiting for MCP tool %q to be registered", toolName)
}

// callMCPTool invokes an mcp_tool pipeline via the agent's MCP endpoint.
func callMCPTool(t *testing.T, toolName string, params map[string]any) map[string]any {
	t.Helper()
	if params == nil {
		params = map[string]any{}
	}
	payload, _ := json.Marshal(map[string]any{"tool": toolName, "params": params})
	resp, err := http.Post(agentBaseURL+"/mcp/call", "application/json", strings.NewReader(string(payload))) //nolint:noctx
	if err != nil {
		t.Fatalf("call MCP tool %q: %v", toolName, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("MCP tool %q: expected 200, got %d", toolName, resp.StatusCode)
	}
	var result map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		t.Fatalf("decode MCP tool %q response: %v", toolName, err)
	}
	return result
}

func verifyAnalyticsResponse(t *testing.T, result map[string]any) {
	t.Helper()
	for _, field := range []string{"completion_rate", "avg_time_to_completion", "bottleneck_status"} {
		if _, ok := result[field]; !ok {
			t.Errorf("task_analytics response missing field %q", field)
		}
	}
	if rate, ok := result["completion_rate"].(float64); ok {
		if rate < 0 || rate > 100 {
			t.Errorf("completion_rate out of range: %v", rate)
		}
		// Seed data: 21 done / 52 total ≈ 40.4%
		if rate < 35 || rate > 50 {
			t.Logf("warning: unexpected completion_rate %v (expected ~40%%)", rate)
		}
	} else {
		t.Errorf("completion_rate should be numeric, got %T", result["completion_rate"])
	}
	if bottleneck, ok := result["bottleneck_status"].(string); !ok || bottleneck == "" {
		t.Error("bottleneck_status should be a non-empty string")
	}
}

func verifyForecastResponse(t *testing.T, result map[string]any) {
	t.Helper()
	forecast, ok := result["forecast"].([]any)
	if !ok {
		t.Fatalf("task_forecast response should have 'forecast' array, got %T", result["forecast"])
	}
	if len(forecast) == 0 {
		t.Fatal("forecast array should not be empty")
	}
	for i, entry := range forecast {
		m, ok := entry.(map[string]any)
		if !ok {
			t.Errorf("forecast[%d] should be object", i)
			continue
		}
		if _, ok := m["date"]; !ok {
			t.Errorf("forecast[%d] missing 'date'", i)
		}
		if _, ok := m["projected_count"]; !ok {
			t.Errorf("forecast[%d] missing 'projected_count'", i)
		}
	}
}

func verifyBlackboardArtifacts(t *testing.T) {
	t.Helper()
	resp, err := http.Get(agentBaseURL + "/blackboard/artifacts") //nolint:noctx
	if err != nil {
		t.Fatalf("GET /blackboard/artifacts: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("blackboard artifacts: expected 200, got %d", resp.StatusCode)
	}
	var artifacts []map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&artifacts); err != nil {
		t.Fatalf("decode blackboard artifacts: %v", err)
	}
	foundDesign, foundIterate := false, false
	for _, a := range artifacts {
		phase, _ := a["phase"].(string)
		artType, _ := a["artifact_type"].(string)
		if phase == "design" && artType == "mcp_tool_proposal" {
			foundDesign = true
		}
		if phase == "iterate" && artType == "second_tool_proposal" {
			foundIterate = true
		}
	}
	if !foundDesign {
		t.Error("missing blackboard artifact: phase=design, type=mcp_tool_proposal")
	}
	if !foundIterate {
		t.Error("missing blackboard artifact: phase=iterate, type=second_tool_proposal")
	}
}

func verifyGitHistory(t *testing.T) {
	t.Helper()
	cmd := exec.Command("docker", "compose", "exec", "-T", "agent",
		"git", "-C", "/data/repo", "log", "--oneline")
	cmd.Dir = scenarioDir(t)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("git log failed: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) < 2 {
		t.Fatalf("expected at least 2 git commits, got %d: %v", len(lines), lines)
	}
	found := map[string]bool{"task_analytics": false, "task_forecast": false}
	for _, line := range lines {
		for k := range found {
			if strings.Contains(strings.ToLower(line), k) {
				found[k] = true
			}
		}
	}
	for tool, ok := range found {
		if !ok {
			t.Errorf("git history missing commit referencing %q", tool)
		}
	}
	fmt.Printf("git log:\n%s\n", out)
}
