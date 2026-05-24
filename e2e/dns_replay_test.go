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
		"PASS: fixture declares export schema v1",
		"PASS: fixtures use only documentation/example IP addresses",
		"PASS: TXT records redact verification tokens and DKIM public keys",
		"PASS: provider coverage includes cloudflare",
		"PASS: provider coverage includes aws",
		"PASS: provider coverage includes azure",
		"PASS: provider coverage includes gcp",
		"PASS: fixture declares provider output contracts",
		"PASS: cloudflare output contract requires authority.name_servers",
		"PASS: namecheap output contract requires authority.is_using_our_dns",
		"PASS: aws output contract requires records",
		"PASS: Azure DNS contract declares record upsert semantics",
		"PASS: GCP Cloud DNS contract declares record upsert semantics",
		"PASS: imported state is marked as adoption provenance",
		"PASS: Cloudflare import omits provider record id from applied config",
		"PASS: MX records are preserved in target",
		"PASS: destructive deletes require explicit opt-in",
		"Results: 245 passed, 0 failed",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("DNS replay output missing %q\n%s", want, output)
		}
	}
}
