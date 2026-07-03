package fakes

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestResolveWithoutAudienceMetadataAllowsRequestedAudience(t *testing.T) {
	dir, err := NewDirectory("", "test-token")
	if err != nil {
		t.Fatalf("new directory: %v", err)
	}
	dir.entries["intake/test"] = Entry{
		Bundle: map[string]any{
			"type": "test-bundle",
		},
		PublicMetadata: map[string]any{
			"allowed_purpose": "public-contact",
		},
		BundleSHA256:           "bundle-sha",
		IdentityKeyFingerprint: "identity-fingerprint",
	}

	req := httptest.NewRequest(http.MethodGet, "/entries/intake%2Ftest?audience_ref=audience://caller&requested_at_unix=1783000060", nil)
	req.Header.Set("X-Directory-Token", "test-token")
	rec := httptest.NewRecorder()

	dir.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var response ResolveResponse
	if err := json.NewDecoder(strings.NewReader(rec.Body.String())).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Status != "resolved" {
		t.Fatalf("status = %q, want resolved; body = %s", response.Status, rec.Body.String())
	}
	if response.Entry == nil {
		t.Fatalf("entry is nil; body = %s", rec.Body.String())
	}
}
