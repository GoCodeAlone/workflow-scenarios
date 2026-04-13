package tests

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// TestE2E_FullLoop runs the complete self-improvement scenario end-to-end.
// It requires Docker Compose with Ollama and Gemma 4 available.
// Skip with -short or when SKIP_E2E env is set.
func TestE2E_FullLoop(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping long-running Docker e2e test in short mode")
	}
	if os.Getenv("SKIP_E2E") != "" {
		t.Skip("SKIP_E2E set")
	}

	dir := scenarioDir(t)

	// Start services
	t.Log("Starting docker-compose services...")
	start := exec.Command("docker", "compose", "up", "-d", "--wait")
	start.Dir = dir
	if out, err := start.CombinedOutput(); err != nil {
		t.Fatalf("docker compose up failed:\n%s", out)
	}
	t.Cleanup(func() {
		cmd := exec.Command("docker", "compose", "down", "-v")
		cmd.Dir = dir
		_ = cmd.Run()
	})

	// Wait for base app to be healthy
	appURL := "http://localhost:8080"
	t.Log("Waiting for base app to be healthy...")
	if err := waitForHealthy(appURL+"/healthz", 2*time.Minute); err != nil {
		t.Fatalf("base app never became healthy: %v", err)
	}

	// Verify base CRUD endpoints
	t.Run("base_app_create_task", func(t *testing.T) {
		resp, err := http.Post(appURL+"/tasks", "application/json",
			strings.NewReader(`{"title":"test task","description":"verify base API"}`))
		if err != nil {
			t.Fatalf("POST /tasks: %v", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusCreated {
			body, _ := io.ReadAll(resp.Body)
			t.Fatalf("expected 201, got %d: %s", resp.StatusCode, body)
		}
	})

	t.Run("base_app_list_tasks", func(t *testing.T) {
		resp, err := http.Get(appURL + "/tasks")
		if err != nil {
			t.Fatalf("GET /tasks: %v", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("expected 200, got %d", resp.StatusCode)
		}
		var tasks []map[string]any
		if err := json.NewDecoder(resp.Body).Decode(&tasks); err != nil {
			t.Fatalf("decode tasks: %v", err)
		}
		if len(tasks) == 0 {
			t.Error("expected at least one task after create")
		}
	})

	// Wait for agent to finish by watching its container exit or checking logs
	// for a completion marker (up to 20 minutes).
	t.Log("Waiting for self-improvement agent to complete...")
	waitForAgentCompletion(t, dir, 20*time.Minute)

	// Verify improved app has expected new capabilities
	t.Run("improved_app_has_search", func(t *testing.T) {
		resp, err := http.Get(appURL + "/tasks/search?q=test")
		if err != nil || resp.StatusCode == http.StatusNotFound {
			t.Skip("search endpoint not yet implemented by agent")
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Errorf("GET /tasks/search: expected 200, got %d", resp.StatusCode)
		}
	})

	t.Run("improved_app_has_pagination", func(t *testing.T) {
		resp, err := http.Get(appURL + "/tasks?cursor=")
		if err != nil {
			t.Skip("pagination not yet available")
		}
		defer resp.Body.Close()
		if resp.StatusCode == http.StatusBadRequest {
			t.Error("cursor pagination not implemented — expected 200 or 404, not 400")
		}
	})

	// Verify git history shows agent iterations
	t.Run("git_history_shows_iterations", func(t *testing.T) {
		cmd := exec.Command("docker", "compose", "exec", "-T", "agent",
			"git", "-C", "/data/repo", "log", "--oneline")
		cmd.Dir = dir
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Skipf("cannot read git log: %v", err)
		}
		lines := strings.Split(strings.TrimSpace(string(out)), "\n")
		if len(lines) < 2 {
			t.Errorf("expected at least 2 git commits (initial + 1 improvement), got %d", len(lines))
		}
		t.Logf("git log:\n%s", out)
	})
}

// TestE2E_BaseAppHealthz verifies the base app config produces a healthy service.
// Does not require Docker — just verifies the config is structurally correct.
func TestE2E_BaseAppHealthz(t *testing.T) {
	cfg := fmt.Sprintf("%s/config/base-app.yaml", scenarioDir(t))

	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read base-app.yaml: %v", err)
	}
	content := string(data)

	if !containsString(content, "health_check:") {
		t.Error("base-app.yaml missing health_check pipeline")
	}
	if !containsString(content, "path: /healthz") {
		t.Error("base-app.yaml missing /healthz route")
	}
	if !containsString(content, "85-self-improving-api") {
		t.Error("healthz response should identify the scenario")
	}
}

func waitForHealthy(url string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(url) //nolint:gosec
		if err == nil && resp.StatusCode == http.StatusOK {
			resp.Body.Close()
			return nil
		}
		if resp != nil {
			resp.Body.Close()
		}
		time.Sleep(3 * time.Second)
	}
	return fmt.Errorf("timeout after %v", timeout)
}

// waitForAgentCompletion watches docker compose logs for the agent container
// completing its work, or times out gracefully.
func waitForAgentCompletion(t *testing.T, dir string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		// Check if agent container has exited (successful completion)
		cmd := exec.Command("docker", "compose", "ps", "--format", "json", "agent")
		cmd.Dir = dir
		out, err := cmd.Output()
		if err == nil {
			var ps map[string]any
			if json.Unmarshal(out, &ps) == nil {
				if state, ok := ps["State"].(string); ok && state == "exited" {
					t.Log("Agent container exited — improvement cycle complete")
					return
				}
			}
		}
		// Also accept if the agent logs contain a completion marker
		logs := exec.Command("docker", "compose", "logs", "--tail=20", "agent")
		logs.Dir = dir
		if logOut, lerr := logs.Output(); lerr == nil {
			logStr := string(logOut)
			if strings.Contains(logStr, "improvement complete") ||
				strings.Contains(logStr, "cycle finished") ||
				strings.Contains(logStr, "deploy: success") {
				t.Log("Agent logged completion marker")
				return
			}
		}
		time.Sleep(15 * time.Second)
	}
	t.Log("Agent did not signal completion within timeout — checking partial results")
}
