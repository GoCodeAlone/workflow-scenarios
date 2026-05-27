// Package main — Go-level IaCProvider impl + ResourceDriver for the DNS
// stub plugin. Mirrors interfaces.IaCProvider so wfctl's typed gRPC
// dispatch (driven by platform.ComputePlan + wfctlhelpers.ApplyPlanHooks)
// works end-to-end without provider-specific quirks.
//
// The stub deliberately treats `infra.dns` as the sole resource type and
// keeps the diff logic minimal: a desired-vs-current comparison on the
// zone NAME identifier — record-level diff is intentionally elided to
// keep scenarios deterministic. Per docs/plans/2026-05-26-dns-provider-contract.md
// PR 9 (Task 30).
package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/GoCodeAlone/workflow/interfaces"
	"github.com/GoCodeAlone/workflow/platform"
	"gopkg.in/yaml.v3"
)

// stubProvider satisfies interfaces.IaCProvider. Holds a single
// ResourceDriver bound to "infra.dns" and a stubStore wired to a per-
// instance JSON file. fixturePath, when non-empty + set BEFORE the
// state file exists, is loaded into state on Initialize so scenario 89
// can drive an "import then plan NoOp" path without an explicit apply.
type stubProvider struct {
	store        *stubStore
	driver       *stubDriver
	fixturePath  string // optional fixture loaded on first Initialize
	providerName string // for error messages — matches the iac.provider module name
}

func (p *stubProvider) Name() string    { return "dns-stub" }
func (p *stubProvider) Version() string { return Version }

// Initialize reads the stub-specific config keys:
//
//	state_path   — JSON file path for persistent state (default:
//	               /tmp/dns-stub-state-<provider>.json or
//	               $DNS_STUB_STATE_PATH if env set)
//	fixture_path — optional YAML fixture loaded into state when the
//	               state file does not exist (gives scenarios a
//	               pre-applied baseline without an explicit apply)
//	provider     — informational; used in error messages
func (p *stubProvider) Initialize(_ context.Context, config map[string]any) error {
	providerName, _ := config["provider"].(string)
	if providerName == "" {
		providerName = "stub"
	}
	p.providerName = providerName

	statePath, _ := config["state_path"].(string)
	if statePath == "" {
		statePath = os.Getenv("DNS_STUB_STATE_PATH")
	}
	if statePath == "" {
		statePath = filepath.Join(os.TempDir(), "dns-stub-state-"+sanitizeFilename(providerName)+".json")
	}
	p.store = newStubStore(statePath)

	fixturePath, _ := config["fixture_path"].(string)
	if fixturePath == "" {
		fixturePath = os.Getenv("DNS_STUB_FIXTURE")
	}
	p.fixturePath = fixturePath

	if fixturePath != "" {
		if err := p.maybeSeedFromFixture(); err != nil {
			return fmt.Errorf("stub %q: seed fixture: %w", providerName, err)
		}
	}

	p.driver = &stubDriver{store: p.store, provider: providerName}
	return nil
}

// maybeSeedFromFixture loads the YAML fixture into state IFF the state
// file does not yet exist. This guarantees apply→import roundtrips on
// scenarios that already have state aren't wiped by a re-run.
func (p *stubProvider) maybeSeedFromFixture() error {
	zones, err := p.store.load()
	if err != nil {
		return fmt.Errorf("load existing state: %w", err)
	}
	if len(zones) > 0 {
		return nil
	}
	data, err := os.ReadFile(p.fixturePath)
	if err != nil {
		return fmt.Errorf("read fixture %s: %w", p.fixturePath, err)
	}
	var fixture struct {
		Zones []stubZone `yaml:"zones"`
	}
	if err := yaml.Unmarshal(data, &fixture); err != nil {
		return fmt.Errorf("parse fixture %s: %w", p.fixturePath, err)
	}
	seeded := map[string]*stubZone{}
	for i := range fixture.Zones {
		z := fixture.Zones[i]
		if z.ID == "" {
			z.ID = z.Zone
		}
		seeded[z.ID] = &z
	}
	return p.store.save(seeded)
}

func (p *stubProvider) Capabilities() []interfaces.IaCCapabilityDeclaration {
	return []interfaces.IaCCapabilityDeclaration{
		{ResourceType: "infra.dns", Tier: 1, Operations: []string{"create", "read", "update", "delete"}},
	}
}

func (p *stubProvider) ResourceDriver(resourceType string) (interfaces.ResourceDriver, error) {
	if p.driver == nil {
		return nil, fmt.Errorf("stub %q: ResourceDriver called before Initialize", p.providerName)
	}
	switch resourceType {
	case "", "infra.dns":
		return p.driver, nil
	default:
		return nil, fmt.Errorf("stub %q: unsupported resource type %q", p.providerName, resourceType)
	}
}

func (p *stubProvider) Plan(ctx context.Context, desired []interfaces.ResourceSpec, current []interfaces.ResourceState) (*interfaces.IaCPlan, error) {
	plan, err := platform.ComputePlan(ctx, p, desired, current)
	return &plan, err
}

func (p *stubProvider) Destroy(ctx context.Context, refs []interfaces.ResourceRef) (*interfaces.DestroyResult, error) {
	if p.store == nil {
		return nil, fmt.Errorf("stub %q: Destroy called before Initialize", p.providerName)
	}
	var destroyed []string
	var errs []interfaces.ActionError
	for _, ref := range refs {
		if err := p.store.delete(zoneIDFromRef(ref)); err != nil {
			errs = append(errs, interfaces.ActionError{Resource: ref.Name, Action: "delete", Error: err.Error()})
			continue
		}
		destroyed = append(destroyed, ref.Name)
	}
	return &interfaces.DestroyResult{Destroyed: destroyed, Errors: errs}, nil
}

func (p *stubProvider) Status(ctx context.Context, refs []interfaces.ResourceRef) ([]interfaces.ResourceStatus, error) {
	out := make([]interfaces.ResourceStatus, 0, len(refs))
	for _, ref := range refs {
		z, err := p.store.get(zoneIDFromRef(ref))
		if err != nil || z == nil {
			out = append(out, interfaces.ResourceStatus{Name: ref.Name, Type: ref.Type, Status: "missing"})
			continue
		}
		out = append(out, interfaces.ResourceStatus{
			Name:       ref.Name,
			Type:       ref.Type,
			ProviderID: z.ID,
			Status:     "active",
			Outputs:    zoneToOutputs(z),
		})
	}
	return out, nil
}

func (p *stubProvider) DetectDrift(_ context.Context, _ []interfaces.ResourceRef) ([]interfaces.DriftResult, error) {
	return nil, nil
}

// Import returns the persisted state for cloudID. wfctl infra import-all
// drives this after EnumerateAll lists the available IDs.
func (p *stubProvider) Import(ctx context.Context, cloudID, resourceType string) (*interfaces.ResourceState, error) {
	if p.store == nil {
		return nil, fmt.Errorf("stub %q: Import called before Initialize", p.providerName)
	}
	if resourceType == "" {
		resourceType = "infra.dns"
	}
	z, err := p.store.get(cloudID)
	if err != nil {
		return nil, fmt.Errorf("stub %q: import load: %w", p.providerName, err)
	}
	if z == nil {
		return nil, fmt.Errorf("stub %q: import: zone %q not found", p.providerName, cloudID)
	}
	now := time.Now()
	return &interfaces.ResourceState{
		ID:                  z.ID,
		Name:                z.ID,
		Type:                resourceType,
		Provider:            p.providerName,
		ProviderID:          z.ID,
		AppliedConfig:       zoneToAppliedConfig(z, p.providerName),
		AppliedConfigSource: "adoption",
		Outputs:             zoneToOutputs(z),
		CreatedAt:           now,
		UpdatedAt:           now,
	}, nil
}

func (p *stubProvider) ResolveSizing(_ string, _ interfaces.Size, _ *interfaces.ResourceHints) (*interfaces.ProviderSizing, error) {
	return nil, nil
}

func (p *stubProvider) BootstrapStateBackend(_ context.Context, _ map[string]any) (*interfaces.BootstrapResult, error) {
	return nil, nil
}

func (p *stubProvider) SupportedCanonicalKeys() []string { return interfaces.CanonicalKeys() }

func (p *stubProvider) Close() error { return nil }

// EnumerateAll lists every zone in state. wfctl infra import-all calls
// this to discover the per-cloud IDs that get fed back through Import.
func (p *stubProvider) EnumerateAll(_ context.Context, resourceType string) ([]*interfaces.ResourceOutput, error) {
	if p.store == nil {
		return nil, fmt.Errorf("stub %q: EnumerateAll called before Initialize", p.providerName)
	}
	if resourceType != "infra.dns" {
		return nil, fmt.Errorf("stub %q: EnumerateAll: resource type %q not supported", p.providerName, resourceType)
	}
	zones, err := p.store.list()
	if err != nil {
		return nil, err
	}
	out := make([]*interfaces.ResourceOutput, 0, len(zones))
	for _, z := range zones {
		out = append(out, &interfaces.ResourceOutput{
			ProviderID: z.ID,
			Type:       "infra.dns",
			Outputs:    zoneToOutputs(z),
		})
	}
	return out, nil
}

// ── ResourceDriver impl ───────────────────────────────────────────────────

// stubDriver satisfies interfaces.ResourceDriver. Plan→apply for the stub
// is intentionally trivial: every Create/Update writes the desired spec
// directly into stubStore; Delete removes; Diff compares zone identity
// only (record-level diff is elided per the package doc on stubProvider).
type stubDriver struct {
	store    *stubStore
	provider string
}

func (d *stubDriver) Create(_ context.Context, spec interfaces.ResourceSpec) (*interfaces.ResourceOutput, error) {
	z := zoneFromSpec(spec)
	if err := d.store.upsert(z); err != nil {
		return nil, fmt.Errorf("stub %q: create %q: %w", d.provider, spec.Name, err)
	}
	return &interfaces.ResourceOutput{
		Name:       spec.Name,
		Type:       spec.Type,
		ProviderID: z.ID,
		Outputs:    zoneToOutputs(z),
		Status:     "active",
	}, nil
}

func (d *stubDriver) Read(_ context.Context, ref interfaces.ResourceRef) (*interfaces.ResourceOutput, error) {
	id := zoneIDFromRef(ref)
	z, err := d.store.get(id)
	if err != nil {
		return nil, fmt.Errorf("stub %q: read %q: %w", d.provider, id, err)
	}
	if z == nil {
		// Surface not-found by wrapping interfaces.ErrResourceNotFound so the
		// wfctl host's isIaCNotFound string-fallback (workflow/cmd/wfctl/
		// infra_apply.go:919-937) and the typed-sentinel errors.Is path both
		// recognise it. The Go wrap chain is stripped across the gRPC wire,
		// so the literal "iac: resource not found" tail is what survives.
		return nil, fmt.Errorf("stub %q: read %q: %w", d.provider, id, interfaces.ErrResourceNotFound)
	}
	return &interfaces.ResourceOutput{
		Name:       ref.Name,
		Type:       ref.Type,
		ProviderID: z.ID,
		Outputs:    zoneToOutputs(z),
		Status:     "active",
	}, nil
}

func (d *stubDriver) Update(_ context.Context, ref interfaces.ResourceRef, spec interfaces.ResourceSpec) (*interfaces.ResourceOutput, error) {
	z := zoneFromSpec(spec)
	if z.ID == "" {
		z.ID = zoneIDFromRef(ref)
	}
	if err := d.store.upsert(z); err != nil {
		return nil, fmt.Errorf("stub %q: update %q: %w", d.provider, spec.Name, err)
	}
	return &interfaces.ResourceOutput{
		Name:       spec.Name,
		Type:       spec.Type,
		ProviderID: z.ID,
		Outputs:    zoneToOutputs(z),
		Status:     "active",
	}, nil
}

func (d *stubDriver) Delete(_ context.Context, ref interfaces.ResourceRef) error {
	return d.store.delete(zoneIDFromRef(ref))
}

// Diff classifies whether spec needs an update relative to current. The
// stub intentionally returns NeedsUpdate=false unconditionally — scenarios
// that exercise import→plan NoOp rely on this so imported state with full
// record content isn't reported as drift from a minimal config that only
// declares the zone name. ComputePlan still emits Create actions when
// current is absent (driven by Read returning not-found), so apply paths
// still work end-to-end.
func (d *stubDriver) Diff(_ context.Context, _ interfaces.ResourceSpec, _ *interfaces.ResourceOutput) (*interfaces.DiffResult, error) {
	return &interfaces.DiffResult{NeedsUpdate: false, NeedsReplace: false}, nil
}

func (d *stubDriver) HealthCheck(_ context.Context, ref interfaces.ResourceRef) (*interfaces.HealthResult, error) {
	z, err := d.store.get(zoneIDFromRef(ref))
	if err != nil || z == nil {
		return &interfaces.HealthResult{Healthy: false}, nil
	}
	return &interfaces.HealthResult{Healthy: true}, nil
}

func (d *stubDriver) Scale(_ context.Context, ref interfaces.ResourceRef, _ int) (*interfaces.ResourceOutput, error) {
	return nil, fmt.Errorf("stub %q: scale not supported for infra.dns", d.provider)
}

func (d *stubDriver) SensitiveKeys() []string { return nil }

// ── helpers ───────────────────────────────────────────────────────────────

// zoneFromSpec builds a stubZone from a ResourceSpec.Config map. The
// canonical fields surfaced are domain/zone (name), records (list),
// and any other keys that ride through Extras to keep apply→import
// roundtrips total-recall.
func zoneFromSpec(spec interfaces.ResourceSpec) *stubZone {
	cfg := spec.Config
	if cfg == nil {
		cfg = map[string]any{}
	}
	zone := strVal(cfg, "domain")
	if zone == "" {
		zone = strVal(cfg, "zone")
	}
	if zone == "" {
		zone = spec.Name
	}
	id := strVal(cfg, "zone_id")
	if id == "" {
		id = strVal(cfg, "id")
	}
	if id == "" {
		id = zone
	}
	var records []map[string]any
	if rawList, ok := cfg["records"].([]any); ok {
		for _, r := range rawList {
			if m, ok := r.(map[string]any); ok {
				records = append(records, m)
			}
		}
	} else if rawList, ok := cfg["records"].([]map[string]any); ok {
		records = append(records, rawList...)
	}
	extras := map[string]any{}
	for k, v := range cfg {
		switch k {
		case "domain", "zone", "zone_id", "id", "records", "provider":
			continue
		default:
			extras[k] = v
		}
	}
	if len(extras) == 0 {
		extras = nil
	}
	return &stubZone{ID: id, Zone: zone, Records: records, Extras: extras}
}

// zoneToOutputs flattens a stubZone into the Outputs map shape the gRPC
// surface expects. The records list rides through as []any so JSON
// round-trips preserve key ordering.
func zoneToOutputs(z *stubZone) map[string]any {
	out := map[string]any{
		"zone":      z.Zone,
		"zone_id":   z.ID,
		"domain_id": z.ID, // alias for the Hover-shaped scenarios
	}
	if len(z.Records) > 0 {
		recs := make([]any, 0, len(z.Records))
		for _, r := range z.Records {
			recs = append(recs, r)
		}
		out["records"] = recs
	}
	for k, v := range z.Extras {
		out[k] = v
	}
	return out
}

// zoneToAppliedConfig builds the persisted ResourceState.AppliedConfig
// map. Includes provider name + zone + records so jq assertions on
// .applied_config.records[] work straight off the import output.
func zoneToAppliedConfig(z *stubZone, providerName string) map[string]any {
	out := map[string]any{
		"provider": providerName,
		"domain":   z.Zone,
		"zone_id":  z.ID,
	}
	if len(z.Records) > 0 {
		recs := make([]any, 0, len(z.Records))
		for _, r := range z.Records {
			recs = append(recs, r)
		}
		out["records"] = recs
	}
	return out
}

// zoneIDFromRef returns the cloud ID for a ResourceRef, preferring the
// ProviderID field when populated (apply path) and falling back to Name
// (initial import path).
func zoneIDFromRef(ref interfaces.ResourceRef) string {
	if ref.ProviderID != "" {
		return ref.ProviderID
	}
	return ref.Name
}

// strVal returns m[key] as string when set; "" otherwise.
func strVal(m map[string]any, key string) string {
	if m == nil {
		return ""
	}
	v, _ := m[key].(string)
	return v
}

// sanitizeFilename strips path separators + other shell-unsafe chars from
// a provider name so it's safe to embed in a default state-file path.
func sanitizeFilename(name string) string {
	bad := []string{"/", `\`, ":", " ", "\t", "\n"}
	out := name
	for _, b := range bad {
		out = strings.ReplaceAll(out, b, "_")
	}
	if out == "" {
		return "stub"
	}
	return out
}
