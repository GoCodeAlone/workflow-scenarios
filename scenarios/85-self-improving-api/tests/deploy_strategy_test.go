package tests

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestDeployStrategy_HotReloadConfigured verifies that the agent-config
// specifies hot_reload as the deploy strategy.
func TestDeployStrategy_HotReloadConfigured(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read agent-config.yaml: %v", err)
	}
	content := string(data)

	if !containsString(content, "strategy: hot_reload") {
		t.Error("deploy step must use strategy: hot_reload")
	}
	if !containsString(content, "deploy_strategy: hot_reload") {
		t.Error("guardrails defaults must declare deploy_strategy: hot_reload")
	}
}

// TestDeployStrategy_ConfigPathSet verifies the deploy step targets the correct config path.
func TestDeployStrategy_ConfigPathSet(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read agent-config.yaml: %v", err)
	}
	content := string(data)

	if !containsString(content, "config_path: /data/config/app.yaml") {
		t.Error("deploy step must target config_path: /data/config/app.yaml")
	}
}

// TestDeployStrategy_SelfImproveStepsOrdered verifies that the pipeline
// steps are in the correct sequence: validate → diff → deploy.
func TestDeployStrategy_SelfImproveStepsOrdered(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read agent-config.yaml: %v", err)
	}
	content := string(data)

	validateLine := indexOfString(content, "type: step.self_improve_validate")
	diffLine := indexOfString(content, "type: step.self_improve_diff")
	deployLine := indexOfString(content, "type: step.self_improve_deploy")

	if validateLine < 0 {
		t.Fatal("step.self_improve_validate not found")
	}
	if diffLine < 0 {
		t.Fatal("step.self_improve_diff not found")
	}
	if deployLine < 0 {
		t.Fatal("step.self_improve_deploy not found")
	}

	if validateLine > diffLine {
		t.Error("step.self_improve_validate must come before step.self_improve_diff")
	}
	if diffLine > deployLine {
		t.Error("step.self_improve_diff must come before step.self_improve_deploy")
	}
}

// TestDeployStrategy_BlackboardPostBeforeValidate ensures the blackboard post
// comes before validation so artifacts are recorded even on validation failure.
func TestDeployStrategy_BlackboardPostBeforeValidate(t *testing.T) {
	cfg := filepath.Join(scenarioDir(t), "config", "agent-config.yaml")
	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read agent-config.yaml: %v", err)
	}
	content := string(data)

	postLine := indexOfString(content, "type: step.blackboard_post")
	validateLine := indexOfString(content, "type: step.self_improve_validate")

	if postLine < 0 {
		t.Fatal("step.blackboard_post not found")
	}
	if validateLine < 0 {
		t.Fatal("step.self_improve_validate not found")
	}

	if postLine > validateLine {
		t.Error("step.blackboard_post must come before step.self_improve_validate")
	}
}

// TestDeployStrategy_DockerComposeDefinesAgent verifies the docker-compose.yaml
// defines an agent service for running the improvement loop.
func TestDeployStrategy_DockerComposeDefinesAgent(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping docker-compose structure check in short mode")
	}
	dc := filepath.Join(scenarioDir(t), "docker-compose.yaml")
	data, err := os.ReadFile(dc)
	if err != nil {
		t.Fatalf("read docker-compose.yaml: %v", err)
	}
	content := string(data)

	checks := []struct {
		name    string
		pattern string
	}{
		{"ollama service", "ollama:"},
		{"app service", "app:"},
		{"agent service", "agent:"},
		{"ollama healthcheck", "service_healthy"},
		{"app-data volume", "app-data:"},
		{"agent-repo volume", "agent-repo:"},
		{"IMPROVEMENT_GOAL env", "IMPROVEMENT_GOAL="},
	}

	for _, c := range checks {
		t.Run(c.name, func(t *testing.T) {
			if !containsString(content, c.pattern) {
				t.Errorf("docker-compose.yaml missing: %q", c.pattern)
			}
		})
	}
}

// indexOfString returns the byte offset of the first occurrence of sub in s,
// or -1 if not found.
func indexOfString(s, sub string) int {
	return strings.Index(s, sub)
}
