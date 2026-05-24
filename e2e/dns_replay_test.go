package e2e

import (
	osexec "os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestDNSReplayMigrationScenario(t *testing.T) {
	repoRoot := filepath.Clean("..")
	script, err := filepath.Abs(filepath.Join(repoRoot, "scenarios", "88-iac-dns-replay-migration", "test", "run.sh"))
	if err != nil {
		t.Fatalf("resolve scenario script path: %v", err)
	}
	cmd := osexec.Command("bash", script)
	cmd.Dir = repoRoot
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("DNS replay scenario failed: %v\n%s", err, output)
	}
	text := string(output)
	for _, want := range []string{
		"PASS: provider coverage includes cloudflare",
		"PASS: MX records are preserved in target",
		"PASS: destructive deletes require explicit opt-in",
		"Results: 123 passed, 0 failed",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("DNS replay output missing %q\n%s", want, output)
		}
	}
}
