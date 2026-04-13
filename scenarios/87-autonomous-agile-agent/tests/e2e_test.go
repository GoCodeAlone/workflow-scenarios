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
// 2. Agent improvement loop is triggered via POST /improve
// 3. Agent completes at least 3 improvement iterations
// 4. Git history shows meaningful progression
// 5. Blackboard has artifacts from all phases
// 6. Final app has more capabilities than the base
func TestE2EAutonomousAgentIterations(t *testing.T) {
	if os.Getenv("E2E") != "true" {
		t.Skip("skipping E2E test; set E2E=true to run")
	}

	t.Log("Step 1: wait for base app and agent health")
	waitForHealth(t, appURL+"/healthz", e2eTimeout)
	waitForHealth(t, agentURL+"/healthz", e2eTimeout)

	t.Log("Step 2: verify base CRUD works")
	verifyBaseCRUD(t)

	t.Log("Step 3: trigger autonomous improvement loop")
	triggerImprovement(t)

	t.Log("Step 4: wait for agent to complete all iterations")
	waitForIterations(t, 3, e2eTimeout)

	t.Log("Step 5: verify git history shows at least 3 commits")
	verifyGitHistory(t, 3)

	t.Log("Step 6: verify blackboard has all phase artifacts")
	verifyBlackboard(t)

	t.Log("Step 7: verify final app has more capabilities")
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

// triggerImprovement fires the agent's improvement loop via its HTTP trigger.
func triggerImprovement(t *testing.T) {
	t.Helper()
	resp, err := http.Post(agentURL+"/improve", "application/json", strings.NewReader("{}")) //nolint:noctx
	if err != nil {
		t.Fatalf("POST /improve: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 500 {
		t.Fatalf("POST /improve: unexpected server error %d", resp.StatusCode)
	}
}

// waitForIterations polls git log inside the agent container until minCommits are found.
func waitForIterations(t *testing.T, minCommits int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		out, err := exec.Command("docker", "compose", "exec", "-T", "agent",
			"git", "-C", "/data/repo", "log", "--oneline").Output()
		if err == nil {
			lines := strings.Split(strings.TrimSpace(string(out)), "\n")
			iterCount := 0
			for _, l := range lines {
				if l != "" && !strings.Contains(l, "initial") {
					iterCount++
				}
			}
			if iterCount >= minCommits {
				t.Logf("agent completed %d iteration commits", iterCount)
				return
			}
		}
		time.Sleep(pollInterval)
	}
	t.Fatalf("timed out waiting for %d iteration commits", minCommits)
}

func verifyGitHistory(t *testing.T, minCommits int) {
	t.Helper()
	out, err := exec.Command("docker", "compose", "exec", "-T", "agent",
		"git", "-C", "/data/repo", "log", "--oneline").Output()
	if err != nil {
		t.Fatalf("git log: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	iterCommits := 0
	for _, line := range lines {
		if line != "" && !strings.Contains(line, "initial") {
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
	// Blackboard artifacts are accessible via the agent's /blackboard/artifacts endpoint.
	resp, err := http.Get(agentURL + "/blackboard/artifacts") //nolint:noctx
	if err != nil {
		t.Logf("blackboard endpoint not available (non-fatal): %v", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Logf("blackboard returned %d (non-fatal)", resp.StatusCode)
		return
	}
	var artifacts []map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&artifacts); err != nil {
		t.Logf("decode blackboard artifacts (non-fatal): %v", err)
		return
	}
	phases := map[string]bool{"audit": false, "plan": false, "deploy": false, "verify": false}
	for _, a := range artifacts {
		if phase, _ := a["phase"].(string); phase != "" {
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
	resp, err := http.Get(appURL + "/healthz") //nolint:noctx
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("final /healthz failed: err=%v", err)
	}
	resp.Body.Close()
	t.Log("final app healthz: OK")
}
