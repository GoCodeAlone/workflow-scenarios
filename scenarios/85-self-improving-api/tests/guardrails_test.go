package tests

import (
	"os"
	"path/filepath"
	"testing"
)

// TestGuardrails_ImmutableSectionsConfigured verifies that the agent-config.yaml
// correctly declares immutable_sections to protect the guardrails module.
func TestGuardrails_ImmutableSectionsConfigured(t *testing.T) {
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
		{"immutable_sections declared", "immutable_sections:"},
		{"modules.guardrails is immutable", `path: "modules.guardrails"`},
		{"challenge_token override mechanism", "override: challenge_token"},
		{"admin secret env var", "admin_secret_env:"},
		{"WFCTL_ADMIN_SECRET", `"WFCTL_ADMIN_SECRET"`},
	}

	for _, c := range checks {
		t.Run(c.name, func(t *testing.T) {
			if !containsString(content, c.pattern) {
				t.Errorf("agent-config.yaml missing: %q", c.pattern)
			}
		})
	}
}

// TestGuardrails_CommandPolicyConfigured verifies that the command_policy is
// set to allowlist mode with static analysis enabled.
func TestGuardrails_CommandPolicyConfigured(t *testing.T) {
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
		{"command_policy block", "command_policy:"},
		{"allowlist mode", "mode: allowlist"},
		{"static analysis enabled", "enable_static_analysis: true"},
		{"pipe-to-shell blocked", "block_pipe_to_shell: true"},
		{"script execution blocked", "block_script_execution: true"},
		{"wfctl allowed", `- "wfctl"`},
		{"go build allowed", `- "go build"`},
		{"curl allowed", `- "curl"`},
	}

	for _, c := range checks {
		t.Run(c.name, func(t *testing.T) {
			if !containsString(content, c.pattern) {
				t.Errorf("agent-config.yaml missing: %q", c.pattern)
			}
		})
	}
}

// TestGuardrails_ToolScopeConfigured verifies that allowed_tools restricts
// the agent to wfctl and lsp MCP namespaces only.
func TestGuardrails_ToolScopeConfigured(t *testing.T) {
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
		{"allowed_tools declared", "allowed_tools:"},
		{"mcp:wfctl scope", `- "mcp:wfctl:*"`},
		{"mcp:lsp scope", `- "mcp:lsp:*"`},
	}

	for _, c := range checks {
		t.Run(c.name, func(t *testing.T) {
			if !containsString(content, c.pattern) {
				t.Errorf("agent-config.yaml missing: %q", c.pattern)
			}
		})
	}
}

// TestGuardrails_SelfImprovementEnabled verifies that the guardrails
// defaults enable self-improvement while keeping IaC modification off.
func TestGuardrails_SelfImprovementEnabled(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read agent-config.yaml: %v", err)
	}
	content := string(data)

	if !containsString(content, "enable_self_improvement: true") {
		t.Error("guardrails must have enable_self_improvement: true")
	}
	if !containsString(content, "enable_iac_modification: false") {
		t.Error("guardrails must have enable_iac_modification: false for scenario 85")
	}
	if !containsString(content, "require_diff_review: true") {
		t.Error("guardrails must have require_diff_review: true")
	}
}

// TestGuardrails_MaxIterationsCapped verifies the iteration cap is set.
func TestGuardrails_MaxIterationsCapped(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read agent-config.yaml: %v", err)
	}
	content := string(data)

	if !containsString(content, "max_iterations_per_cycle:") {
		t.Error("guardrails must declare max_iterations_per_cycle")
	}
	// Ensure it's not unbounded (should be a reasonable number like 5)
	if !containsString(content, "max_iterations_per_cycle: 5") {
		t.Error("expected max_iterations_per_cycle: 5 for scenario 85")
	}
}
