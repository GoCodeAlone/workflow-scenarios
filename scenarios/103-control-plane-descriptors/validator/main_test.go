package main

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/GoCodeAlone/workflow-plugin-control-plane/descriptors"
	"github.com/GoCodeAlone/workflow-plugin-control-plane/envelopes"
	"github.com/GoCodeAlone/workflow-plugin-control-plane/registry"
)

func TestScenarioControlPlaneBundlesUseReleasedContracts(t *testing.T) {
	for name, version := range map[string]string{
		"descriptors": descriptors.Version,
		"envelopes":   envelopes.Version,
		"registry":    registry.Version,
	} {
		if version != "control-plane.v1alpha1" {
			t.Fatalf("%s version = %q, want control-plane.v1alpha1", name, version)
		}
	}
}

func TestScenarioControlPlaneBundlesValidateRealArtifacts(t *testing.T) {
	validFiles, err := filepath.Glob(filepath.Join("..", "bundles", "valid", "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(validFiles) == 0 {
		t.Fatal("valid bundle fixtures are required")
	}
	for _, file := range validFiles {
		t.Run("valid/"+filepath.Base(file), func(t *testing.T) {
			result, err := validateBundleFile(file, true)
			if err != nil {
				t.Fatalf("valid bundle rejected: %v", err)
			}
			if result.Kind == "" || result.Path == "" {
				t.Fatalf("validation result missing provenance: %+v", result)
			}
		})
	}
}

func TestScenarioControlPlaneBundlesRejectAuthorityTransferAndStaleArtifacts(t *testing.T) {
	invalidFiles, err := filepath.Glob(filepath.Join("..", "bundles", "invalid", "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(invalidFiles) < 4 {
		t.Fatalf("expected at least four invalid fixtures, got %d", len(invalidFiles))
	}
	for _, file := range invalidFiles {
		t.Run("invalid/"+filepath.Base(file), func(t *testing.T) {
			_, err := validateBundleFile(file, false)
			if err != nil {
				t.Fatalf("invalid bundle assertion failed: %v", err)
			}
		})
	}
}

func TestScenarioControlPlaneBundleRunnerPrintsGeneratedSummary(t *testing.T) {
	output, err := runValidation([]string{
		"--valid-dir", filepath.Join("..", "bundles", "valid"),
		"--invalid-dir", filepath.Join("..", "bundles", "invalid"),
	})
	if err != nil {
		t.Fatalf("runner failed: %v\n%s", err, output)
	}
	for _, want := range []string{
		"valid=3",
		"invalid=4",
		"public_contract=control-plane.v1alpha1",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("runner output missing %q:\n%s", want, output)
		}
	}
}
