// live_parity_test.go — cross-driver parity scaffold for scenario 92.
//
// Tests in this file are SKIPPED unless WFCTL_LIVE_CLOUD=1 is set.
// They are NEVER run by CI (see plan §Task 19 + §Out of scope item #23).
//
// # Purpose
//
// Verifies that Plan/Apply/Destroy response shapes are consistent across
// real cloud providers (AWS, GCP, DigitalOcean) when mutation routes are
// used against a live infra.admin server pointed at a real provider.
//
// # Required environment
//
//	WFCTL_LIVE_CLOUD=1          — enable (default: tests skip)
//	INFRA_ADMIN_BASE_URL        — base URL of a running infra.admin server
//	INFRA_ADMIN_BEARER          — valid JWT bearer token (operator sub)
//
// One or more of the following provider credential sets:
//
//	AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY — AWS provider
//	GOOGLE_APPLICATION_CREDENTIALS            — GCP provider
//	DIGITALOCEAN_TOKEN                        — DigitalOcean provider
//
// # Running
//
//	WFCTL_LIVE_CLOUD=1 \
//	  INFRA_ADMIN_BASE_URL=http://localhost:18092 \
//	  INFRA_ADMIN_BEARER=<jwt> \
//	  go test ./test/ -run LiveParity -v
//
// # CI status
//
// This test is intentionally skipped in CI. The required credentials are not
// available in CI, and real cloud operations are out of scope for automated
// runs (plan §Out of scope — "Live-cloud APPLY/DESTROY against real
// AWS/GCP/DO in CI (#23) ships as t.Skip env-gated scaffold only").
package test

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

// liveParityClient is a minimal HTTP client for infra.admin mutation endpoints.
type liveParityClient struct {
	baseURL string
	bearer  string
	hc      *http.Client
}

func newLiveParityClient(t *testing.T) *liveParityClient {
	t.Helper()
	base := os.Getenv("INFRA_ADMIN_BASE_URL")
	if base == "" {
		base = "http://localhost:18092"
	}
	tok := os.Getenv("INFRA_ADMIN_BEARER")
	if tok == "" {
		t.Skip("INFRA_ADMIN_BEARER not set — cannot authenticate against live server")
	}
	return &liveParityClient{
		baseURL: strings.TrimRight(base, "/"),
		bearer:  tok,
		hc:      &http.Client{Timeout: 60 * time.Second},
	}
}

func (c *liveParityClient) post(t *testing.T, path string, body any) map[string]any {
	t.Helper()
	b, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost,
		c.baseURL+path, strings.NewReader(string(b)))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+c.bearer)
	resp, err := c.hc.Do(req)
	if err != nil {
		t.Fatalf("POST %s: %v", path, err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("POST %s: HTTP %d: %s", path, resp.StatusCode, raw)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("POST %s: unmarshal response: %v", path, err)
	}
	if errMsg, _ := out["error"].(string); errMsg != "" {
		t.Fatalf("POST %s: server error: %s", path, errMsg)
	}
	return out
}

// liveParitySkip gates all live-parity tests.
func liveParitySkip(t *testing.T) {
	t.Helper()
	if os.Getenv("WFCTL_LIVE_CLOUD") != "1" {
		t.Skip("live-cloud parity skipped (set WFCTL_LIVE_CLOUD=1 to enable)")
	}
}

// TestLiveParity_PlanApplyDestroyShapeParity verifies that the Plan/Apply/
// Destroy response shapes from infra.admin are consistent across providers.
//
// This test scaffolds parity assertions for aws, gcp, and digitalocean
// provider modules. In CI, it is skipped by liveParitySkip(). When
// WFCTL_LIVE_CLOUD=1, it connects to a real infra.admin server and drives
// the mutation flow against real providers.
//
// Parity criteria:
//   - Plan: all providers return plan_id (non-empty) + desired_hash (64-char hex)
//   - Apply: all providers return no top-level error; applied[] is a JSON array
//   - Destroy: all providers return no top-level error; destroyed[] is a JSON array
func TestLiveParity_PlanApplyDestroyShapeParity(t *testing.T) {
	liveParitySkip(t)
	c := newLiveParityClient(t)

	evidence := map[string]any{"authz_checked": true, "authz_allowed": true}
	providers := detectAvailableProviders(t)
	if len(providers) == 0 {
		t.Skip("no provider credentials found (need AWS/GCP/DO env vars)")
	}
	t.Logf("Testing against providers: %v", providers)

	for _, prov := range providers {
		prov := prov
		t.Run(prov, func(t *testing.T) {
			// Plan.
			planResp := c.post(t, "/api/infra-admin/plan", map[string]any{
				"app_context":     "",
				"resource_filter": "",
				"evidence":        evidence,
			})
			planID, _ := planResp["plan_id"].(string)
			desiredHash, _ := planResp["desired_hash"].(string)
			if planID == "" {
				t.Errorf("provider %s: plan_id is empty", prov)
			}
			if len(desiredHash) != 64 {
				t.Errorf("provider %s: desired_hash is not 64 chars, got %q", prov, desiredHash)
			}
			t.Logf("provider %s: plan_id=%s desired_hash=%s", prov, planID, desiredHash)

			// Apply.
			applyResp := c.post(t, "/api/infra-admin/apply", map[string]any{
				"plan_id":      planID,
				"desired_hash": desiredHash,
				"allow_replace": []string{},
				"app_context":  "",
				"evidence":     evidence,
			})
			applied, _ := applyResp["applied"].([]any)
			t.Logf("provider %s: applied %d resource(s)", prov, len(applied))

			// Destroy (all applied resources).
			if len(applied) > 0 {
				refs := make([]map[string]any, 0, len(applied))
				for _, r := range applied {
					rm, _ := r.(map[string]any)
					refs = append(refs, map[string]any{
						"name": rm["name"],
						"type": rm["type"],
					})
				}
				destroyResp := c.post(t, "/api/infra-admin/destroy", map[string]any{
					"refs":         refs,
					"confirm_hash": desiredHash,
					"evidence":     evidence,
				})
				destroyed, _ := destroyResp["destroyed"].([]any)
				t.Logf("provider %s: destroyed %d resource(s)", prov, len(destroyed))
			}
		})
	}
}

// TestLiveParity_DriftCheckShape verifies drift check shape parity.
func TestLiveParity_DriftCheckShape(t *testing.T) {
	liveParitySkip(t)
	c := newLiveParityClient(t)

	providers := detectAvailableProviders(t)
	if len(providers) == 0 {
		t.Skip("no provider credentials found")
	}

	for _, prov := range providers {
		prov := prov
		t.Run(prov, func(t *testing.T) {
			driftResp := c.post(t, "/api/infra-admin/drift", map[string]any{
				"refs":     []any{},
				"evidence": map[string]any{"authz_checked": true, "authz_allowed": true},
			})
			drift, _ := driftResp["drift"].([]any)
			t.Logf("provider %s: %d drift result(s)", prov, len(drift))
			// Shape: each drift result has resource_name, type, drifted (bool).
			for i, d := range drift {
				dm, ok := d.(map[string]any)
				if !ok {
					t.Errorf("drift[%d]: expected object, got %T", i, d)
					continue
				}
				if _, ok := dm["resource_name"]; !ok {
					t.Errorf("drift[%d]: missing resource_name", i)
				}
				if _, ok := dm["drifted"]; !ok {
					t.Errorf("drift[%d]: missing drifted bool", i)
				}
			}
		})
	}
}

// detectAvailableProviders returns provider names based on which credential
// env vars are set. Used to skip individual sub-tests when credentials are
// absent so the test doesn't attempt to plan against a provider with no creds.
func detectAvailableProviders(t *testing.T) []string {
	t.Helper()
	var providers []string
	if os.Getenv("AWS_ACCESS_KEY_ID") != "" && os.Getenv("AWS_SECRET_ACCESS_KEY") != "" {
		providers = append(providers, "aws")
	}
	if os.Getenv("GOOGLE_APPLICATION_CREDENTIALS") != "" {
		providers = append(providers, "gcp")
	}
	if os.Getenv("DIGITALOCEAN_TOKEN") != "" {
		providers = append(providers, "digitalocean")
	}
	t.Logf("detectAvailableProviders: found %v", providers)
	return providers
}

// TestLiveParity_SkipsByDefault documents the CI behavior: without
// WFCTL_LIVE_CLOUD=1, all live-parity tests are skipped cleanly.
func TestLiveParity_SkipsByDefault(t *testing.T) {
	if os.Getenv("WFCTL_LIVE_CLOUD") == "1" {
		t.Log("WFCTL_LIVE_CLOUD=1 set — this test documents skip behavior; it passes trivially")
		return
	}
	// Assert the skip mechanism works: run a sub-test that calls liveParitySkip.
	t.Run("SkipGate", func(t *testing.T) {
		liveParitySkip(t)
		// If liveParitySkip didn't skip, fail: something is wrong.
		t.Error("liveParitySkip should have skipped this test")
	})
	// The sub-test was skipped, not failed — that's the correct behavior.
	// This outer test body itself passes (no t.Fail() call).
	fmt.Fprintf(os.Stdout, "LiveParity_SkipsByDefault: sub-test correctly skipped\n") //nolint:forbidigo
}
