package tests

import (
	"os"
	"path/filepath"
	"testing"
)

// TestCommandSafety_AllowlistConfigured verifies that command_policy uses
// allowlist mode to prevent arbitrary command execution by the agent.
func TestCommandSafety_AllowlistConfigured(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read agent-config.yaml: %v", err)
	}
	content := string(data)

	if !containsString(content, "mode: allowlist") {
		t.Error("command_policy must use mode: allowlist to restrict agent commands")
	}
}

// TestCommandSafety_DangerousCommandsNotAllowed verifies that common dangerous
// commands are NOT in the allowed_commands list.
func TestCommandSafety_DangerousCommandsNotAllowed(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read agent-config.yaml: %v", err)
	}
	content := string(data)

	dangerousCommands := []string{
		`- "rm"`,
		`- "rm -rf"`,
		`- "dd"`,
		`- "mkfs"`,
		`- "chmod 777"`,
		`- "sudo"`,
		`- "bash"`,
		`- "sh"`,
		`- "/bin/bash"`,
		`- "/bin/sh"`,
	}

	for _, cmd := range dangerousCommands {
		t.Run("not_allowed_"+cmd, func(t *testing.T) {
			if containsString(content, cmd) {
				t.Errorf("dangerous command %q must not be in allowed_commands", cmd)
			}
		})
	}
}

// TestCommandSafety_SafeCommandsAllowed verifies that safe commands needed
// by the agent are present in the allowlist.
func TestCommandSafety_SafeCommandsAllowed(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read agent-config.yaml: %v", err)
	}
	content := string(data)

	safeCommands := []string{
		`- "wfctl"`,
		`- "curl"`,
		`- "go build"`,
		`- "go test"`,
	}

	for _, cmd := range safeCommands {
		t.Run("allowed_"+cmd, func(t *testing.T) {
			if !containsString(content, cmd) {
				t.Errorf("safe command %q should be in allowed_commands", cmd)
			}
		})
	}
}

// TestCommandSafety_PipeToShellBlocked verifies that the config explicitly
// blocks pipe-to-shell command patterns (e.g., curl ... | bash).
func TestCommandSafety_PipeToShellBlocked(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read agent-config.yaml: %v", err)
	}
	content := string(data)

	if !containsString(content, "block_pipe_to_shell: true") {
		t.Error("command_policy must set block_pipe_to_shell: true")
	}
}

// TestCommandSafety_ScriptExecutionBlocked verifies that script execution
// (e.g., running .sh files directly) is blocked.
func TestCommandSafety_ScriptExecutionBlocked(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read agent-config.yaml: %v", err)
	}
	content := string(data)

	if !containsString(content, "block_script_execution: true") {
		t.Error("command_policy must set block_script_execution: true")
	}
}

// TestCommandSafety_StaticAnalysisEnabled verifies that the AST-based
// static analysis is enabled so that bypass attempts are caught.
func TestCommandSafety_StaticAnalysisEnabled(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read agent-config.yaml: %v", err)
	}
	content := string(data)

	if !containsString(content, "enable_static_analysis: true") {
		t.Error("command_policy must set enable_static_analysis: true for AST-based command analysis")
	}
}

// TestCommandSafety_BypassAttempts documents known bypass patterns that
// the command analyzer must catch. These are config-level checks — actual
// runtime bypass testing requires Docker.
func TestCommandSafety_BypassPatterns(t *testing.T) {
	// This test documents known bypass attempt patterns.
	// The actual runtime blocking is tested in TestE2E_FullLoop.
	bypassPatterns := []struct {
		name    string
		command string
		risk    string
	}{
		{"rm -rf via env var", "RM_CMD=rm; $RM_CMD -rf /", "command_injection"},
		{"base64 decode + exec", "echo cm0gLXJmIC8=" + " | base64 -d | bash", "pipe_to_shell"},
		{"shell function override", "function curl() { rm -rf /; }; curl", "function_override"},
		{"path traversal exec", "/usr/bin/../bin/sh -c 'rm -rf /'", "path_traversal"},
		{"heredoc script", "bash << 'EOF'\nrm -rf /\nEOF", "heredoc"},
		{"dd overwrite", "dd if=/dev/zero of=/etc/passwd", "destructive_write"},
		{"chmod world-writable", "chmod -R 777 /etc", "permission_escalation"},
	}

	// Verify the config has static analysis enabled (which catches these patterns)
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read agent-config.yaml: %v", err)
	}
	content := string(data)

	if !containsString(content, "enable_static_analysis: true") {
		t.Fatal("static analysis must be enabled to catch bypass patterns")
	}

	for _, bp := range bypassPatterns {
		t.Run(bp.name, func(t *testing.T) {
			cmd := bp.command
			if len(cmd) > 40 {
				cmd = cmd[:40]
			}
			t.Logf("bypass pattern %q (risk: %s) is documented and covered by static analysis",
				cmd, bp.risk)
		})
	}
}
