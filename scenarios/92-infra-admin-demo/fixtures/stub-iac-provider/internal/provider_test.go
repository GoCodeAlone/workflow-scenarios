package internal_test

import (
	"context"
	"testing"

	pb "github.com/GoCodeAlone/workflow/plugin/external/proto"

	"github.com/GoCodeAlone/workflow-scenarios/scenarios/92-infra-admin-demo/fixtures/stub-iac-provider/internal"
)

// ctx is a convenience shorthand — all stub methods ignore the context.
var ctx = context.Background()

// newStub returns a zeroed StubIaCServer ready for testing.
func newStub() *internal.StubIaCServer { return &internal.StubIaCServer{} }

// ── Name / Version ────────────────────────────────────────────────────────────

func TestName(t *testing.T) {
	resp, err := newStub().Name(ctx, &pb.NameRequest{})
	if err != nil {
		t.Fatalf("Name: unexpected error: %v", err)
	}
	if got := resp.GetName(); got != "stub" {
		t.Errorf("Name() = %q; want %q", got, "stub")
	}
}

func TestVersion(t *testing.T) {
	resp, err := newStub().Version(ctx, &pb.VersionRequest{})
	if err != nil {
		t.Fatalf("Version: unexpected error: %v", err)
	}
	if got := resp.GetVersion(); got != "0.1.0" {
		t.Errorf("Version() = %q; want %q", got, "0.1.0")
	}
}

// ── Capabilities ──────────────────────────────────────────────────────────────

func TestCapabilities(t *testing.T) {
	resp, err := newStub().Capabilities(ctx, &pb.CapabilitiesRequest{})
	if err != nil {
		t.Fatalf("Capabilities: unexpected error: %v", err)
	}

	caps := resp.GetCapabilities()
	if len(caps) != 2 {
		t.Fatalf("Capabilities() returned %d declarations; want 2", len(caps))
	}

	wantTypes := map[string]bool{"stub.database": true, "stub.bucket": true}
	for _, c := range caps {
		if !wantTypes[c.GetResourceType()] {
			t.Errorf("unexpected resource type %q in capabilities", c.GetResourceType())
		}
		if len(c.GetOperations()) == 0 {
			t.Errorf("resource type %q has no operations", c.GetResourceType())
		}
	}

	if got := resp.GetComputePlanVersion(); got != "v2" {
		t.Errorf("ComputePlanVersion = %q; want %q", got, "v2")
	}
}

// ── ListRegions ───────────────────────────────────────────────────────────────

func TestListRegions_ReturnsBothRegions(t *testing.T) {
	resp, err := newStub().ListRegions(ctx, &pb.ListRegionsRequest{})
	if err != nil {
		t.Fatalf("ListRegions: unexpected error: %v", err)
	}

	regions := resp.GetRegions()
	if len(regions) != 2 {
		t.Fatalf("ListRegions() returned %d regions; want 2", len(regions))
	}

	// Assert deterministic names — Playwright assertions match these.
	wantNames := map[string]string{
		"stub-east": "Stub East",
		"stub-west": "Stub West",
	}
	for _, r := range regions {
		wantDisplay, ok := wantNames[r.GetName()]
		if !ok {
			t.Errorf("unexpected region name %q", r.GetName())
			continue
		}
		if r.GetDisplayName() != wantDisplay {
			t.Errorf("region %q: DisplayName = %q; want %q", r.GetName(), r.GetDisplayName(), wantDisplay)
		}
	}
}

// ── Plan ──────────────────────────────────────────────────────────────────────

func TestPlan_OneDesiredSpec_OneCreateAction(t *testing.T) {
	req := &pb.PlanRequest{
		Desired: []*pb.ResourceSpec{
			{Name: "my-db", Type: "stub.database"},
		},
	}
	resp, err := newStub().Plan(ctx, req)
	if err != nil {
		t.Fatalf("Plan: unexpected error: %v", err)
	}

	plan := resp.GetPlan()
	if plan == nil {
		t.Fatal("Plan() returned nil IaCPlan")
	}
	actions := plan.GetActions()
	if len(actions) != 1 {
		t.Fatalf("Plan() produced %d actions; want 1", len(actions))
	}
	if got := actions[0].GetAction(); got != "create" {
		t.Errorf("actions[0].Action = %q; want %q", got, "create")
	}
	if got := actions[0].GetResource().GetName(); got != "my-db" {
		t.Errorf("actions[0].Resource.Name = %q; want %q", got, "my-db")
	}
}

func TestPlan_MultipleDesiredSpecs_AllCreateActions(t *testing.T) {
	req := &pb.PlanRequest{
		Desired: []*pb.ResourceSpec{
			{Name: "db1", Type: "stub.database"},
			{Name: "bkt1", Type: "stub.bucket"},
		},
	}
	resp, err := newStub().Plan(ctx, req)
	if err != nil {
		t.Fatalf("Plan: unexpected error: %v", err)
	}

	actions := resp.GetPlan().GetActions()
	if len(actions) != 2 {
		t.Fatalf("Plan() produced %d actions; want 2", len(actions))
	}
	for i, a := range actions {
		if a.GetAction() != "create" {
			t.Errorf("actions[%d].Action = %q; want %q", i, a.GetAction(), "create")
		}
	}
}

func TestPlan_EmptyDesired_NoActions(t *testing.T) {
	resp, err := newStub().Plan(ctx, &pb.PlanRequest{})
	if err != nil {
		t.Fatalf("Plan: unexpected error: %v", err)
	}
	if n := len(resp.GetPlan().GetActions()); n != 0 {
		t.Errorf("Plan(empty) produced %d actions; want 0", n)
	}
}

// ── Status ────────────────────────────────────────────────────────────────────

func TestStatus_EchosRefsAsRunning(t *testing.T) {
	req := &pb.StatusRequest{
		Refs: []*pb.ResourceRef{
			{Name: "db1", Type: "stub.database", ProviderId: "stub-db1"},
		},
	}
	resp, err := newStub().Status(ctx, req)
	if err != nil {
		t.Fatalf("Status: unexpected error: %v", err)
	}
	statuses := resp.GetStatuses()
	if len(statuses) != 1 {
		t.Fatalf("Status() returned %d statuses; want 1", len(statuses))
	}
	if got := statuses[0].GetStatus(); got != "running" {
		t.Errorf("Status()[0].Status = %q; want %q", got, "running")
	}
	if got := statuses[0].GetName(); got != "db1" {
		t.Errorf("Status()[0].Name = %q; want %q", got, "db1")
	}
}

func TestStatus_EmptyRefs_EmptyResult(t *testing.T) {
	resp, err := newStub().Status(ctx, &pb.StatusRequest{})
	if err != nil {
		t.Fatalf("Status: unexpected error: %v", err)
	}
	if n := len(resp.GetStatuses()); n != 0 {
		t.Errorf("Status(empty) returned %d statuses; want 0", n)
	}
}

// ── Destroy ───────────────────────────────────────────────────────────────────

func TestDestroy_EchosRefNamesAsDestroyed(t *testing.T) {
	req := &pb.DestroyRequest{
		Refs: []*pb.ResourceRef{
			{Name: "db1", Type: "stub.database"},
			{Name: "bkt1", Type: "stub.bucket"},
		},
	}
	resp, err := newStub().Destroy(ctx, req)
	if err != nil {
		t.Fatalf("Destroy: unexpected error: %v", err)
	}
	destroyed := resp.GetResult().GetDestroyed()
	if len(destroyed) != 2 {
		t.Fatalf("Destroy() returned %d destroyed names; want 2", len(destroyed))
	}
	wantSet := map[string]bool{"db1": true, "bkt1": true}
	for _, name := range destroyed {
		if !wantSet[name] {
			t.Errorf("unexpected destroyed name %q", name)
		}
	}
}

// ── DetectDrift ───────────────────────────────────────────────────────────────

func TestDetectDrift_NoDriftForAnyRef(t *testing.T) {
	req := &pb.DetectDriftRequest{
		Refs: []*pb.ResourceRef{
			{Name: "db1", Type: "stub.database"},
			{Name: "bkt1", Type: "stub.bucket"},
		},
	}
	resp, err := newStub().DetectDrift(ctx, req)
	if err != nil {
		t.Fatalf("DetectDrift: unexpected error: %v", err)
	}
	drifts := resp.GetDrifts()
	if len(drifts) != 2 {
		t.Fatalf("DetectDrift() returned %d results; want 2", len(drifts))
	}
	for _, d := range drifts {
		if d.GetDrifted() {
			t.Errorf("ref %q: Drifted = true; want false", d.GetName())
		}
	}
}

// ── Initialize / BootstrapStateBackend / ResolveSizing ───────────────────────

func TestInitialize_NoError(t *testing.T) {
	_, err := newStub().Initialize(ctx, &pb.InitializeRequest{})
	if err != nil {
		t.Errorf("Initialize: unexpected error: %v", err)
	}
}

func TestBootstrapStateBackend_ReturnsStubBucket(t *testing.T) {
	resp, err := newStub().BootstrapStateBackend(ctx, &pb.BootstrapStateBackendRequest{})
	if err != nil {
		t.Fatalf("BootstrapStateBackend: unexpected error: %v", err)
	}
	if got := resp.GetResult().GetBucket(); got != "stub-state" {
		t.Errorf("BootstrapStateBackend.Bucket = %q; want %q", got, "stub-state")
	}
}

func TestResolveSizing_NoError(t *testing.T) {
	_, err := newStub().ResolveSizing(ctx, &pb.ResolveSizingRequest{})
	if err != nil {
		t.Errorf("ResolveSizing: unexpected error: %v", err)
	}
}
