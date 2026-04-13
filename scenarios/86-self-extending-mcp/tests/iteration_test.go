// Package tests validates scenario 86 — Self-Extending MCP Tooling.
// Config validation tests verify agent-config.yaml has the correct structure
// for MCP tool creation: mcp:self_improve:* permissions, blackboard posts,
// two validate+deploy steps (one per tool), and the use_tool step.
package tests

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// scenarioDir returns the absolute path to the scenario root.
func scenarioDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not determine test file location")
	}
	return filepath.Dir(filepath.Dir(file))
}

// wfctlBin returns the wfctl binary path, skipping if not found.
func wfctlBin(t *testing.T) string {
	t.Helper()
	if bin := os.Getenv("WFCTL_BIN"); bin != "" {
		if _, err := os.Stat(bin); err == nil {
			return bin
		}
	}
	for _, c := range []string{
		"wfctl",
		filepath.Join(os.Getenv("HOME"), "go/bin/wfctl"),
		"/usr/local/bin/wfctl",
		"/tmp/wfctl",
	} {
		if path, err := exec.LookPath(c); err == nil {
			return path
		}
	}
	t.Skip("wfctl not found — set WFCTL_BIN to override")
	return ""
}

// readFile reads a file and returns its content as a string.
func readFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("readFile %s: %v", path, err)
	}
	return string(data)
}

// has is a helper to count occurrences of substr in s.
func countOccurrences(s, substr string) int {
	return strings.Count(s, substr)
}

// TestIterationBlackboardPosts verifies agent-config.yaml has at least 2 blackboard_post steps.
func TestIterationBlackboardPosts(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	count := countOccurrences(content, "type: step.blackboard_post")
	if count < 2 {
		t.Errorf("expected at least 2 step.blackboard_post steps (one per iteration), got %d", count)
	}
}

// TestIterationDeploySteps verifies there are at least 2 deploy steps (one per tool).
func TestIterationDeploySteps(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	count := countOccurrences(content, "type: step.self_improve_deploy")
	if count < 2 {
		t.Errorf("expected at least 2 step.self_improve_deploy steps (analytics + forecast), got %d", count)
	}
}

// TestIterationValidationSteps verifies there are at least 2 validate steps.
func TestIterationValidationSteps(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	count := countOccurrences(content, "type: step.self_improve_validate")
	if count < 2 {
		t.Errorf("expected at least 2 step.self_improve_validate steps, got %d", count)
	}
}

// TestUseToolStepReferencesAnalytics verifies the use_tool step's prompt mentions both tools.
func TestUseToolStepReferencesAnalytics(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	if !strings.Contains(content, "task_analytics") {
		t.Error("agent-config.yaml must reference task_analytics in the use_tool step prompt")
	}
	if !strings.Contains(content, "task_forecast") {
		t.Error("agent-config.yaml must reference task_forecast in the use_tool step prompt")
	}
}

// TestConfigValidation_BaseAppYAML runs wfctl validate on base-app.yaml.
func TestConfigValidation_BaseAppYAML(t *testing.T) {
	wfctl := wfctlBin(t)
	cfg := filepath.Join(scenarioDir(t), "config", "base-app.yaml")
	out, err := exec.Command(wfctl, "validate", "--skip-unknown-types", cfg).CombinedOutput()
	if err != nil {
		t.Fatalf("wfctl validate base-app.yaml failed:\n%s", out)
	}
}

// TestConfigValidation_AgentConfigYAML runs wfctl validate on agent-config.yaml.
func TestConfigValidation_AgentConfigYAML(t *testing.T) {
	wfctl := wfctlBin(t)
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	out, err := exec.Command(wfctl, "validate", "--skip-unknown-types", cfg).CombinedOutput()
	if err != nil {
		t.Fatalf("wfctl validate agent-config.yaml failed:\n%s", out)
	}
}
