// Package tests validates scenario 85 — Self-Improving API.
// Config validation tests run wfctl validate on base-app.yaml and agent-config.yaml.
package tests

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
)

// scenarioDir returns the absolute path to the scenario root.
func scenarioDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not determine test file location")
	}
	// tests/ is one level inside the scenario dir
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
	candidates := []string{
		"wfctl",
		filepath.Join(os.Getenv("HOME"), "go/bin/wfctl"),
		"/usr/local/bin/wfctl",
		"/tmp/wfctl",
	}
	for _, c := range candidates {
		if path, err := exec.LookPath(c); err == nil {
			return path
		}
	}
	t.Skip("wfctl not found — set WFCTL_BIN to override")
	return ""
}

func TestConfigValidation_BaseAppExists(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "base-app.yaml")
	if _, err := os.Stat(cfg); err != nil {
		t.Fatalf("base-app.yaml missing: %v", err)
	}
}

func TestConfigValidation_AgentConfigExists(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	if _, err := os.Stat(cfg); err != nil {
		t.Fatalf("agent-config.yaml missing: %v", err)
	}
}

func TestConfigValidation_BaseAppYAML(t *testing.T) {
	wfctl := wfctlBin(t)
	cfg := filepath.Join(scenarioDir(t), "config", "base-app.yaml")

	out, err := exec.Command(wfctl, "validate", "--skip-unknown-types", cfg).CombinedOutput()
	if err != nil {
		t.Fatalf("wfctl validate base-app.yaml failed:\n%s", out)
	}
}

func TestConfigValidation_AgentConfigYAML(t *testing.T) {
	wfctl := wfctlBin(t)
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")

	out, err := exec.Command(wfctl, "validate", "--skip-unknown-types", cfg).CombinedOutput()
	if err != nil {
		t.Fatalf("wfctl validate agent-config.yaml failed:\n%s", out)
	}
}

func TestConfigValidation_BaseAppModules(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "base-app.yaml")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read base-app.yaml: %v", err)
	}
	content := string(data)

	checks := []struct {
		name    string
		pattern string
	}{
		{"storage.sqlite module", "type: storage.sqlite"},
		{"http.server module", "type: http.server"},
		{"http.router module", "type: http.router"},
		{"create_task pipeline", "create_task:"},
		{"list_tasks pipeline", "list_tasks:"},
		{"get_task pipeline", "get_task:"},
		{"update_task pipeline", "update_task:"},
		{"delete_task pipeline", "delete_task:"},
		{"health_check pipeline", "health_check:"},
		{"/tasks route", "path: /tasks"},
		{"/healthz route", "path: /healthz"},
		{"step.db_exec", "type: step.db_exec"},
		{"step.db_query", "type: step.db_query"},
		{"step.json_response", "type: step.json_response"},
	}

	for _, c := range checks {
		t.Run(c.name, func(t *testing.T) {
			if !containsString(content, c.pattern) {
				t.Errorf("base-app.yaml missing: %q", c.pattern)
			}
		})
	}
}

func TestConfigValidation_AgentConfigModules(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read agent-config.yaml: %v", err)
	}
	content := string(data)

	checks := []struct {
		name    string
		pattern string
	}{
		{"agent.provider module", "type: agent.provider"},
		{"ollama provider", "provider: ollama"},
		{"gemma4 model", "model: gemma4"},
		{"http.server module", "type: http.server"},
		{"http.router module", "type: http.router"},
		{"agent.guardrails module", "type: agent.guardrails"},
		{"immutable_sections", "immutable_sections:"},
		{"modules.guardrails path", `path: "modules.guardrails"`},
		{"challenge_token override", "override: challenge_token"},
		{"command_policy allowlist", "mode: allowlist"},
		{"block_pipe_to_shell", "block_pipe_to_shell: true"},
		{"self_improvement_loop pipeline", "self_improvement_loop:"},
		{"step.agent_execute", "type: step.agent_execute"},
		{"step.blackboard_post", "type: step.blackboard_post"},
		{"step.self_improve_validate", "type: step.self_improve_validate"},
		{"step.self_improve_diff", "type: step.self_improve_diff"},
		{"step.self_improve_deploy", "type: step.self_improve_deploy"},
		{"hot_reload strategy", "strategy: hot_reload"},
		{"mcp:wfctl tools", `"mcp:wfctl:validate_config"`},
		{"mcp:lsp tools", `"mcp:lsp:diagnose"`},
	}

	for _, c := range checks {
		t.Run(c.name, func(t *testing.T) {
			if !containsString(content, c.pattern) {
				t.Errorf("agent-config.yaml missing: %q", c.pattern)
			}
		})
	}
}

// TestConfigValidation_NoGoTemplates checks that agent-config.yaml (which uses only
// new self-improvement step types) does not use legacy Go template syntax.
// base-app.yaml may use {{ }} for existing step types (step.db_exec, step.db_query).
func TestConfigValidation_NoGoTemplates(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read agent-config.yaml: %v", err)
	}
	if containsString(string(data), "{{") {
		t.Error("agent-config.yaml uses Go template syntax {{ }} — must use expr syntax ${ }")
	}
}

func containsString(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(sub) == 0 ||
		func() bool {
			for i := 0; i <= len(s)-len(sub); i++ {
				if s[i:i+len(sub)] == sub {
					return true
				}
			}
			return false
		}())
}
