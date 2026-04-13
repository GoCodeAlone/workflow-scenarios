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
	appURL       = "http://localhost:8080"
	agentURL     = "http://localhost:8081"
	e2eTimeout   = 15 * time.Minute
	pollInterval = 15 * time.Second
)

// TestE2EAutonomousAgentIterations runs the full autonomous agile agent scenario:
// 1. Base app responds to CRUD
// 2. Agent completes at least 3 improvement iterations
// 3. Git history shows meaningful progression
// 4. Blackboard has artifacts from all phases
// 5. Final app has more capabilities than the base
func TestE2EAutonomousAgentIterations(t *testing.T) {
	if os.Getenv("E2E") != "true" {
		t.Skip("skipping E2E test; set E2E=true to run")
	}

	t.Log("Step 1: wait for base app health")
	waitForHealth(t, appURL+"/healthz", e2eTimeout)

	t.Log("Step 2: verify base CRUD works")
	verifyBaseCRUD(t)

	t.Log("Step 3: wait for agent to complete iterations")
	waitForAgentCompletion(t, e2eTimeout)

	t.Log("Step 4: verify git history shows at least 3 commits")
	verifyGitHistory(t, 3)

	t.Log("Step 5: verify blackboard has all phase artifacts")
	verifyBlackboard(t)

	t.Log("Step 6: verify final app has more capabilities")
	verifyFinalApp(t)

	t.Log("PASS: autonomous agile agent completed all iterations")
}

func waitForHealth(t *testing.T, url string, timeout time.Duration) {
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
	body := strings.NewReader(`{"title":"e2e baseline task","description":"verify base CRUD"}`)
	resp, err := http.Post(appURL+"/tasks", "application/json", body) //nolint:noctx
	if err != nil {
		t.Fatalf("POST /tasks: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("POST /tasks: expected 201, got %d", resp.StatusCode)
	}

	resp, err = http.Get(appURL + "/tasks") //nolint:noctx
	if err != nil {
		t.Fatalf("GET /tasks: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /tasks: expected 200, got %d", resp.StatusCode)
	}
}

// waitForAgentCompletion polls the agent blackboard for a completion signal.
func waitForAgentCompletion(t *testing.T, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(agentURL + "/blackboard/status") //nolint:noctx
		if err == nil && resp.StatusCode == http.StatusOK {
			var status map[string]any
			if json.NewDecoder(resp.Body).Decode(&status) == nil {
				resp.Body.Close()
				if done, _ := status["completed"].(bool); done {
					t.Logf("agent completed: %v iterations", status["iterations"])
					return
				}
			} else {
				resp.Body.Close()
			}
		}
		time.Sleep(pollInterval)
	}
	t.Fatalf("timed out waiting for agent to complete")
}

func verifyGitHistory(t *testing.T, minCommits int) {
	t.Helper()
	out, err := exec.Command("docker", "compose", "exec", "-T", "agent",
		"git", "-C", "/data/repo", "log", "--oneline").Output()
	if err != nil {
		t.Fatalf("git log: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	// Exclude initial commit
	iterCommits := 0
	for _, line := range lines {
		if strings.Contains(line, "initial") {
			continue
		}
		if line != "" {
			iterCommits++
		}
	}
	if iterCommits < minCommits {
		t.Fatalf("expected at least %d iteration commits, got %d:\n%s", minCommits, iterCommits, out)
	}
	fmt.Printf("git history (%d iteration commits):\n%s\n", iterCommits, out)
}

func verifyBlackboard(t *testing.T) {
	t.Helper()
	resp, err := http.Get(agentURL + "/blackboard/artifacts") //nolint:noctx
	if err != nil {
		t.Fatalf("GET /blackboard/artifacts: %v", err)
	}
	defer resp.Body.Close()

	var artifacts []map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&artifacts); err != nil {
		t.Fatalf("decode artifacts: %v", err)
	}

	phases := map[string]bool{"audit": false, "plan": false, "deploy": false, "verify": false}
	for _, a := range artifacts {
		phase, _ := a["phase"].(string)
		if _, ok := phases[phase]; ok {
			phases[phase] = true
		}
	}
	for phase, found := range phases {
		if !found {
			t.Errorf("blackboard missing artifacts for phase %q", phase)
		}
	}
}

func verifyFinalApp(t *testing.T) {
	t.Helper()
	// The final app should respond to /healthz and have additional endpoints
	resp, err := http.Get(appURL + "/healthz") //nolint:noctx
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("final /healthz failed: err=%v", err)
	}
	resp.Body.Close()

	// Check that the final config has more pipelines than the base (6 base pipelines)
	out, err := exec.Command("docker", "compose", "exec", "-T", "app",
		"wfctl", "inspect", "/data/config/app.yaml", "--format", "json").Output()
	if err != nil {
		t.Logf("wfctl inspect failed (non-fatal): %v", err)
		return
	}
	var inspection map[string]any
	if err := json.Unmarshal(out, &inspection); err != nil {
		t.Logf("could not parse inspection output (non-fatal): %v", err)
		return
	}
	if pipelines, ok := inspection["pipelines"].([]any); ok {
		if len(pipelines) <= 6 {
			t.Errorf("final app should have more than 6 pipelines (base), got %d", len(pipelines))
		}
		t.Logf("final app has %d pipelines", len(pipelines))
	}
}
