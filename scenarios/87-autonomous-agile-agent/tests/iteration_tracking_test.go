// Package tests validates scenario 87 — Autonomous Agile Agent.
// Config validation and structural tests ensure the agent config has
// the correct structure for fully-autonomous iteration: audit → plan →
// validate → deploy → verify → commit, repeated up to 5 times.
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

func readFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("readFile %s: %v", path, err)
	}
	return string(data)
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

// TestIterationPipeline_Exists verifies the autonomous_improvement_loop pipeline is defined.
func TestIterationPipeline_Exists(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	if !strings.Contains(content, "autonomous_improvement_loop:") {
		t.Error("agent-config.yaml must define autonomous_improvement_loop pipeline")
	}
}

// TestIterationPipeline_HasTrigger verifies the pipeline has an HTTP trigger.
func TestIterationPipeline_HasTrigger(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	if !strings.Contains(content, "path: /improve") {
		t.Error("autonomous_improvement_loop must have an HTTP trigger at /improve")
	}
}

// TestIterationPipeline_HasAllPhases verifies all iteration phase steps are present.
func TestIterationPipeline_HasAllPhases(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	phases := []struct {
		name    string
		pattern string
	}{
		{"audit step", "name: audit"},
		{"plan step", "name: plan"},
		{"validate step", "name: validate"},
		{"deploy step", "name: deploy"},
		{"verify step", "name: verify"},
		{"commit step", "name: commit_iteration"},
	}
	for _, p := range phases {
		t.Run(p.name, func(t *testing.T) {
			if !strings.Contains(content, p.pattern) {
				t.Errorf("autonomous_improvement_loop missing %s: %q", p.name, p.pattern)
			}
		})
	}
}

// TestIterationPipeline_BlackboardPostsPerPhase verifies blackboard posts for all phases.
func TestIterationPipeline_BlackboardPostsPerPhase(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	for _, phase := range []string{"phase: audit", "phase: plan", "phase: deploy", "phase: verify"} {
		if !strings.Contains(content, phase) {
			t.Errorf("agent-config.yaml missing blackboard_post with %q", phase)
		}
	}
}

// TestIterationPipeline_AuditUsesDetectFeatures verifies audit step uses detect_project_features.
func TestIterationPipeline_AuditUsesDetectFeatures(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	if !strings.Contains(content, "mcp:wfctl:detect_project_features") {
		t.Error("audit step must include mcp:wfctl:detect_project_features tool")
	}
}

// TestIterationPipeline_AuditUsesAPIExtract verifies agent uses api_extract.
func TestIterationPipeline_AuditUsesAPIExtract(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	if !strings.Contains(content, "mcp:wfctl:api_extract") {
		t.Error("agent-config.yaml must include mcp:wfctl:api_extract tool")
	}
}

// TestIterationPipeline_MaxIterations verifies max_iterations_per_cycle is 5.
func TestIterationPipeline_MaxIterations(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	if !strings.Contains(content, "max_iterations_per_cycle: 5") {
		t.Error("agent-config.yaml must set max_iterations_per_cycle: 5")
	}
}

// TestIterationPipeline_GitCommitStep verifies a git_commit step is present.
func TestIterationPipeline_GitCommitStep(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	if !strings.Contains(content, "type: step.git_commit") {
		t.Error("autonomous_improvement_loop must include a step.git_commit step")
	}
}

// TestAgentModel_IsGemma4 verifies the Ollama model is gemma4.
func TestAgentModel_IsGemma4(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	if !strings.Contains(content, "model: gemma4") {
		t.Error("agent.provider must use model: gemma4")
	}
}

// TestAgentConfig_ModuleListFormat verifies agent-config.yaml uses list format for modules.
func TestAgentConfig_ModuleListFormat(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	if !strings.Contains(content, "- name: ai") {
		t.Error("agent-config.yaml modules must use list format (- name: ai)")
	}
	if !strings.Contains(content, "- name: guardrails") {
		t.Error("agent-config.yaml modules must use list format (- name: guardrails)")
	}
}

// TestAgentGuardrails_ImmutableSection verifies modules.guardrails is immutable.
func TestAgentGuardrails_ImmutableSection(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	if !strings.Contains(content, `path: "modules.guardrails"`) {
		t.Error(`agent-config.yaml must mark "modules.guardrails" as immutable`)
	}
}

// TestAgentGuardrails_CommandPolicy verifies command policy blocks dangerous ops.
func TestAgentGuardrails_CommandPolicy(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	for _, check := range []string{
		"mode: allowlist",
		"block_pipe_to_shell: true",
		"block_script_execution: true",
	} {
		if !strings.Contains(content, check) {
			t.Errorf("agent-config.yaml missing command policy: %q", check)
		}
	}
}

// TestAgentPrompt_ContainsGoal verifies the autonomous agent prompt contains the goal text.
func TestAgentPrompt_ContainsGoal(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "agent-config.yaml"))
	for _, kw := range []string{"full control", "agile", "iterative", "production-ready"} {
		if !strings.Contains(content, kw) {
			t.Errorf("audit step system_prompt missing keyword %q", kw)
		}
	}
}

// TestDockerCompose_NoDockerfileRefs verifies no Dockerfile build references.
func TestDockerCompose_NoDockerfileRefs(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "docker-compose.yaml"))
	if strings.Contains(content, "dockerfile: Dockerfile") {
		t.Error("docker-compose.yaml must use pre-built image, not build from Dockerfile")
	}
}

// TestDockerCompose_HasGemma4 verifies docker-compose.yaml references gemma4.
func TestDockerCompose_HasGemma4(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "docker-compose.yaml"))
	if !strings.Contains(content, "gemma4") {
		t.Error("docker-compose.yaml must reference gemma4 (e.g. OLLAMA_MODEL=gemma4)")
	}
}

// TestDockerCompose_HasHealthcheck verifies app service has a healthcheck.
func TestDockerCompose_HasHealthcheck(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "docker-compose.yaml"))
	if !strings.Contains(content, "/healthz") {
		t.Error("docker-compose.yaml app service must have a healthcheck pointing to /healthz")
	}
}

// TestDockerCompose_UsesPrebuiltImage verifies pre-built workflow image is used.
func TestDockerCompose_UsesPrebuiltImage(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "docker-compose.yaml"))
	if !strings.Contains(content, "ghcr.io/gocodealone/workflow:latest") {
		t.Error("docker-compose.yaml must use ghcr.io/gocodealone/workflow:latest image")
	}
}

// TestScenarioYAML_Exists verifies scenario.yaml is present with correct id.
func TestScenarioYAML_Exists(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "scenario.yaml"))
	if !strings.Contains(content, `id: "87-autonomous-agile-agent"`) {
		t.Error(`scenario.yaml must contain id: "87-autonomous-agile-agent"`)
	}
}

// TestBaseApp_ModuleListFormat verifies base-app.yaml uses list format for modules.
func TestBaseApp_ModuleListFormat(t *testing.T) {
	content := readFile(t, filepath.Join(scenarioDir(t), "config", "base-app.yaml"))
	if !strings.Contains(content, "- name: db") {
		t.Error("base-app.yaml modules must use list format (- name: db)")
	}
	if !strings.Contains(content, "type: storage.sqlite") {
		t.Error("base-app.yaml must use type: storage.sqlite")
	}
}
