package e2e

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	osexec "os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"
)

// An optional Git ref lets the same compiled tests exercise the original scripts
// without changing the working checkout. Only synthetic scenario fixtures run.
var scenarioHarnessRef = flag.String("scenario-harness-ref", "", "read scenario harness files from an existing Git ref")

// An explicit executable keeps baseline and corrected aggregate checks on the
// same Make implementation without depending on a host's tool-selection shim.
var scenarioHarnessMake = flag.String("scenario-harness-make", "make", "Make executable for aggregate harness checks")

type scenarioResult struct {
	Namespace  string `json:"namespace"`
	Status     string `json:"status"`
	LastResult string `json:"lastResult"`
	TestCount  int    `json:"testCount"`
	PassCount  int    `json:"passCount"`
	FailCount  int    `json:"failCount"`
	SkipCount  int    `json:"skipCount"`
}

func harnessFixture(t *testing.T, scenarios map[string]string) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate harness source")
	}
	repo := filepath.Dir(filepath.Dir(source))
	root := t.TempDir()
	for _, name := range []string{"Makefile", "scripts/test.sh", "scripts/update-status.sh"} {
		var data []byte
		var err error
		if *scenarioHarnessRef == "" {
			data, err = os.ReadFile(filepath.Join(repo, name))
		} else {
			data, err = osexec.Command("git", "-C", repo, "show", *scenarioHarnessRef+":"+name).Output()
		}
		if err != nil {
			t.Fatalf("read production %s: %v", name, err)
		}
		writeHarnessFile(t, filepath.Join(root, name), data)
	}
	state := make(map[string]scenarioResult)
	for name, script := range scenarios {
		state[name] = scenarioResult{Namespace: "fixture-" + name, Status: "pending", LastResult: "unknown"}
		writeHarnessFile(t, filepath.Join(root, "scenarios", name, "test", "run.sh"), []byte("#!/usr/bin/env bash\nset -eu\nprintf '%s\\n' \"$SCENARIO\" >> ran.log\n"+script))
	}
	if err := os.MkdirAll(filepath.Join(root, "scenarios"), 0o700); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(map[string]any{"scenarios": state})
	if err != nil {
		t.Fatal(err)
	}
	writeHarnessFile(t, filepath.Join(root, "scenarios.json"), data)
	return root
}

func writeHarnessFile(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o700); err != nil {
		t.Fatal(err)
	}
}

func runHarness(t *testing.T, root string, extraEnv []string, args ...string) (string, int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := osexec.CommandContext(ctx, args[0], args[1:]...)
	// Bound pipe draining after child exit or cancellation; the command's
	// execution deadline remains ten seconds.
	cmd.WaitDelay = time.Second
	cmd.Dir = root
	// Keep fixture execution independent of caller flags, Python startup hooks,
	// Make parallelism and application credentials.
	cmd.Env = append([]string{"PATH=" + os.Getenv("PATH"), "TMPDIR=" + os.Getenv("TMPDIR"), "LC_ALL=C", "PYTHONDONTWRITEBYTECODE=1", "PYTHONNOUSERSITE=1"}, extraEnv...)
	output, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("harness timed out: command=%q resolved=%q context=%v wait=%v state=%v; output:\n%s", args, cmd.Path, ctx.Err(), err, cmd.ProcessState, output)
	}
	if err == nil {
		return string(output), 0
	}
	if exit, ok := err.(*osexec.ExitError); ok {
		return string(output), exit.ExitCode()
	}
	t.Fatalf("harness execution failed: command=%q resolved=%q wait=%v state=%v; output:\n%s", args, cmd.Path, err, cmd.ProcessState, output)
	return "", -1
}

func readScenarioResult(t *testing.T, root, scenario string) scenarioResult {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(root, "scenarios.json"))
	if err != nil {
		t.Fatal(err)
	}
	var state struct {
		Scenarios map[string]scenarioResult `json:"scenarios"`
	}
	if err := json.Unmarshal(data, &state); err != nil {
		t.Fatalf("invalid persisted JSON: %v", err)
	}
	return state.Scenarios[scenario]
}

func TestScenarioResultClassification(t *testing.T) {
	cases := []struct {
		name, script, result, status  string
		exit, passed, failed, skipped int
	}{
		{"pass", "printf 'PASS: one\\nPASS: two\\n'\n", "pass", "passed", 0, 2, 0, 0},
		{"fail-marker-zero-exit", "printf 'FAIL: assertion\\n'\n", "fail", "failed", 1, 0, 1, 0},
		{"nonzero-no-markers", "exit 9\n", "fail", "failed", 1, 0, 0, 0},
		{"nonzero-after-pass", "printf 'PASS: one\\n'\nexit 9\n", "fail", "failed", 1, 1, 0, 0},
		{"child-77-is-failure", "exit 77\n", "fail", "failed", 1, 0, 0, 0},
		{"child-77-with-skip", "printf 'SKIP: dependency\\n'\nexit 77\n", "fail", "failed", 1, 0, 0, 1},
		{"missing-tool", "printf 'SKIP: wfctl binary not found\\n'\n", "skip", "skipped", 77, 0, 0, 1},
		{"no-assertions", "printf 'No assertions ran\\n'\n", "skip", "skipped", 77, 0, 0, 0},
		{"silent", "exit 0\n", "skip", "skipped", 77, 0, 0, 0},
		{"mixed-pass-fail", "printf 'PASS: one\\nFAIL: two\\n'\n", "fail", "failed", 1, 1, 1, 0},
		{"mixed-pass-skip", "printf 'PASS: one\\nSKIP: two\\n'\n", "skip", "skipped", 77, 1, 0, 1},
		{"mixed-fail-skip", "printf 'FAIL: one\\nSKIP: two\\n'\n", "fail", "failed", 1, 0, 1, 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := harnessFixture(t, map[string]string{"fixture": tc.script})
			output, exit := runHarness(t, root, nil, "bash", "scripts/test.sh", "fixture")
			if exit != tc.exit {
				t.Errorf("exit = %d, want %d; output:\n%s", exit, tc.exit, output)
			}
			want := scenarioResult{"fixture-fixture", tc.status, tc.result, tc.passed + tc.failed, tc.passed, tc.failed, tc.skipped}
			if got := readScenarioResult(t, root, "fixture"); got != want {
				t.Errorf("persisted result = %+v, want %+v", got, want)
			}
			if strings.Contains(output, "RESULT: ALL TESTS PASSED") != (tc.result == "pass") {
				t.Errorf("incorrect success summary:\n%s", output)
			}
			if _, err := os.Stat(filepath.Join(root, "scenarios/fixture/test/artifacts/last-run.log")); err != nil {
				t.Errorf("missing test artifact: %v", err)
			}
			if tc.result == "fail" && strings.Contains(tc.script, "exit 9") && !strings.Contains(output, "child exit 9") {
				t.Errorf("failure summary lost child status:\n%s", output)
			}
		})
	}
}

func TestScenarioResultPersistenceFailure(t *testing.T) {
	for _, fault := range []string{"artifact-directory", "artifact-file", "status-replace"} {
		t.Run(fault, func(t *testing.T) {
			root := harnessFixture(t, map[string]string{"fixture": "printf 'PASS: one\\n'\n"})
			before, err := os.ReadFile(filepath.Join(root, "scenarios.json"))
			if err != nil {
				t.Fatal(err)
			}
			var env []string
			artifacts := filepath.Join(root, "scenarios/fixture/test/artifacts")
			switch fault {
			case "artifact-directory":
				writeHarnessFile(t, artifacts, []byte("blocked"))
			case "artifact-file":
				if err := os.MkdirAll(filepath.Join(artifacts, "last-run.log"), 0o700); err != nil {
					t.Fatal(err)
				}
			case "status-replace":
				// Fail the actual Python updater's rename boundary deterministically,
				// including when tests run as root; do not replace its JSON logic.
				hook := filepath.Join(root, "python-hook")
				writeHarnessFile(t, filepath.Join(hook, "sitecustomize.py"), []byte("import sys\ndef refuse_rename(event, args):\n    if event == 'os.rename':\n        raise OSError('fixture status publication failure')\nsys.addaudithook(refuse_rename)\n"))
				env = []string{"PYTHONPATH=" + hook}
			}
			output, exit := runHarness(t, root, env, "bash", "scripts/test.sh", "fixture")
			if exit != 1 || !strings.Contains(output, "ERROR:") || strings.Contains(output, "RESULT: ALL TESTS PASSED") {
				t.Errorf("persistence failure exit=%d; output:\n%s", exit, output)
			}
			after, err := os.ReadFile(filepath.Join(root, "scenarios.json"))
			if err != nil || string(after) != string(before) {
				t.Errorf("failed publication changed prior state: read error=%v", err)
			}
			if leftovers, err := filepath.Glob(filepath.Join(root, ".scenarios.*")); err != nil || len(leftovers) != 0 {
				t.Errorf("status staging files remain: %v, %v", leftovers, err)
			}
			if fault == "status-replace" {
				if _, err := os.Stat(filepath.Join(artifacts, "last-run.log")); err != nil {
					t.Errorf("artifacts were not saved before status publication: %v", err)
				}
			}
		})
	}
}

func TestScenarioAggregateResults(t *testing.T) {
	for _, tc := range []struct {
		name, first, summary string
		wantSuccess          bool
	}{
		{"pass", "PASS: one", "2 passed, 0 failed, 0 skipped", true},
		{"failure-before-pass", "FAIL: one", "1 passed, 1 failed, 0 skipped", false},
		{"skip-before-pass", "SKIP: dependency", "1 passed, 0 failed, 1 skipped", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := harnessFixture(t, map[string]string{
				"01-first":  fmt.Sprintf("printf '%%s\\n' '%s'\n", tc.first),
				"02-second": "printf 'PASS: two\\n'\n",
			})
			output, exit := runHarness(t, root, nil, *scenarioHarnessMake, "--no-print-directory", "test-all")
			if (exit == 0) != tc.wantSuccess || !strings.Contains(output, tc.summary) {
				t.Errorf("aggregate exit=%d; output:\n%s", exit, output)
			}
			ran, err := os.ReadFile(filepath.Join(root, "ran.log"))
			if err != nil || !reflect.DeepEqual(strings.Fields(string(ran)), []string{"01-first", "02-second"}) {
				t.Errorf("scenarios did not all run in order: %q, %v", ran, err)
			}
		})
	}
	t.Run("failure-precedes-skip", func(t *testing.T) {
		root := harnessFixture(t, map[string]string{
			"01-fail": "printf 'FAIL: one\\n'\n",
			"02-skip": "printf 'SKIP: two\\n'\n",
			"03-pass": "printf 'PASS: three\\n'\n",
		})
		output, exit := runHarness(t, root, nil, *scenarioHarnessMake, "--no-print-directory", "test-all")
		if exit == 0 || !strings.Contains(output, "1 passed, 1 failed, 1 skipped") || !strings.Contains(output, "RESULT: SCENARIO TESTS FAILED") {
			t.Errorf("mixed aggregate exit=%d; output:\n%s", exit, output)
		}
		ran, err := os.ReadFile(filepath.Join(root, "ran.log"))
		if err != nil || string(ran) != "01-fail\n02-skip\n03-pass\n" {
			t.Errorf("mixed aggregate did not finish in order: %q, %v", ran, err)
		}
	})
	t.Run("empty", func(t *testing.T) {
		root := harnessFixture(t, nil)
		output, exit := runHarness(t, root, nil, *scenarioHarnessMake, "--no-print-directory", "test-all")
		if exit == 0 || !strings.Contains(output, "No runnable scenarios") {
			t.Errorf("empty selection exit=%d; output:\n%s", exit, output)
		}
	})
}
