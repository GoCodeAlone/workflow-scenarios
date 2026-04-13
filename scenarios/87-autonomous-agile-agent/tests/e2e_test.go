package tests

import (
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
	// basePipelineCount is the number of pipelines in base-app.yaml.
	// The agent must add at least one more for verifyFinalApp to pass.
	basePipelineCount = 6
)

// TestE2EAutonomousAgentIterations runs the full autonomous agile agent scenario:
// 1. Base app responds to CRUD
// 2. Agent improvement loop triggered via POST /improve
// 3. Agent completes at least 3 improvement iterations
// 4. Git history shows meaningful progression
// 5. Final app has more pipelines than the base config
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

	t.Log("Step 4: wait for agent to complete at least 3 iterations")
	waitForIterations(t, 3, e2eTimeout)

	t.Log("Step 5: verify git history shows at least 3 commits")
	verifyGitHistory(t, 3)

	t.Log("Step 6: verify final app has more capabilities than the base")
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

// waitForIterations polls git log inside the agent container until minCommits iteration commits appear.
func waitForIterations(t *testing.T, minCommits int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		cmd := exec.Command("docker", "compose", "exec", "-T", "agent",
			"git", "-C", "/data/repo", "log", "--oneline")
		cmd.Dir = scenarioDir(t)
		if out, err := cmd.Output(); err == nil {
			iterCount := countIterCommits(string(out))
			if iterCount >= minCommits {
				t.Logf("agent completed %d iteration commits", iterCount)
				return
			}
		}
		time.Sleep(pollInterval)
	}
	t.Fatalf("timed out waiting for %d iteration commits", minCommits)
}

func countIterCommits(gitLog string) int {
	n := 0
	for _, line := range strings.Split(strings.TrimSpace(gitLog), "\n") {
		if line != "" && !strings.Contains(line, "initial") {
			n++
		}
	}
	return n
}

func verifyGitHistory(t *testing.T, minCommits int) {
	t.Helper()
	cmd := exec.Command("docker", "compose", "exec", "-T", "agent",
		"git", "-C", "/data/repo", "log", "--oneline")
	cmd.Dir = scenarioDir(t)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("git log: %v", err)
	}
	if n := countIterCommits(string(out)); n < minCommits {
		t.Fatalf("expected at least %d iteration commits, got %d:\n%s", minCommits, n, out)
	}
	fmt.Printf("git history:\n%s\n", out)
}

// verifyFinalApp asserts the agent actually improved the application by checking
// that the final app.yaml has more pipeline triggers than the base config.
func verifyFinalApp(t *testing.T) {
	t.Helper()

	// Read the final app.yaml from inside the app container.
	cmd := exec.Command("docker", "compose", "exec", "-T", "app",
		"cat", "/data/config/app.yaml")
	cmd.Dir = scenarioDir(t)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("read final app.yaml: %v", err)
	}

	// Count pipeline trigger blocks — each pipeline has exactly one.
	finalCount := strings.Count(string(out), "trigger:")
	t.Logf("final app.yaml has %d pipelines (base had %d)", finalCount, basePipelineCount)

	if finalCount <= basePipelineCount {
		t.Errorf("agent did not improve the app: final pipeline count %d <= base %d",
			finalCount, basePipelineCount)
	}

	// Also confirm the app is still healthy after all improvements.
	resp, err := http.Get(appURL + "/healthz") //nolint:noctx
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("final /healthz failed after agent improvements: err=%v", err)
	}
	resp.Body.Close()
}
