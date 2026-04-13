package tests

import (
	"path/filepath"
	"strings"
	"testing"
)

// TestMCPToolCreation_AgentHasSelfImprovePermission verifies mcp:self_improve:* is in allowed_tools.
func TestMCPToolCreation_AgentHasSelfImprovePermission(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	if !strings.Contains(content, `"mcp:self_improve:*"`) {
		t.Error("agent-config.yaml must include mcp:self_improve:* in allowed_tools")
	}
}

// TestMCPToolCreation_PipelineExists verifies mcp_tool_creation_loop pipeline is defined.
func TestMCPToolCreation_PipelineExists(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	if !strings.Contains(content, "mcp_tool_creation_loop:") {
		t.Error("agent-config.yaml must define mcp_tool_creation_loop pipeline")
	}
}

// TestMCPToolCreation_PipelineSteps verifies required steps exist in the pipeline.
func TestMCPToolCreation_PipelineSteps(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	steps := []string{
		"name: load_config",
		"name: inspect",
		"name: post_design",
		"name: validate",
		"name: deploy_tool",
		"name: use_tool",
		"name: post_iteration",
		"name: deploy_forecast",
	}
	for _, step := range steps {
		if !strings.Contains(content, step) {
			t.Errorf("agent-config.yaml mcp_tool_creation_loop missing step: %q", step)
		}
	}
}

// TestMCPToolCreation_ModelIsGemma4 verifies the Ollama model is gemma4.
func TestMCPToolCreation_ModelIsGemma4(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	if !strings.Contains(content, "model: gemma4") {
		t.Error("agent-config.yaml agent.provider must use model: gemma4")
	}
}

// TestMCPToolCreation_GuardrailsImmutable verifies modules.guardrails is immutable.
func TestMCPToolCreation_GuardrailsImmutable(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	if !strings.Contains(content, `path: "modules.guardrails"`) {
		t.Error(`agent-config.yaml must mark "modules.guardrails" as immutable`)
	}
	if !strings.Contains(content, "override: challenge_token") {
		t.Error("agent-config.yaml immutable section must use challenge_token override")
	}
}

// TestMCPToolCreation_CommandPolicy verifies the command policy blocks dangerous operations.
func TestMCPToolCreation_CommandPolicy(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	checks := []struct {
		name    string
		pattern string
	}{
		{"allowlist mode", "mode: allowlist"},
		{"block_pipe_to_shell", "block_pipe_to_shell: true"},
		{"block_script_execution", "block_script_execution: true"},
		{"static analysis", "enable_static_analysis: true"},
	}
	for _, c := range checks {
		t.Run(c.name, func(t *testing.T) {
			if !strings.Contains(content, c.pattern) {
				t.Errorf("agent-config.yaml missing command policy setting: %q", c.pattern)
			}
		})
	}
}

// TestMCPToolCreation_BlackboardPhases verifies design and iterate phases are both present.
func TestMCPToolCreation_BlackboardPhases(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	if !strings.Contains(content, "phase: design") {
		t.Error("agent-config.yaml must have a blackboard_post with phase: design")
	}
	if !strings.Contains(content, "phase: iterate") {
		t.Error("agent-config.yaml must have a blackboard_post with phase: iterate")
	}
}
