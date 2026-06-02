// Package internal implements the stub IaC provider for scenario 92.
//
// The stub serves deterministic, credential-free data over the typed IaC gRPC
// contract (pb.IaCProviderRequiredServer + pb.IaCProviderRegionListerServer +
// pb.IaCProviderDriftDetectorServer). It is compiled into a separate binary
// (cmd/stub-iac-provider) that the scenario engine loads as an external plugin
// via sdk.ServeIaCPlugin — consistent with ADR-0010 (fixture lives in the
// scenario repo, never in engine core).
//
// # Deterministic data
//
//   - Name()    → "stub"
//   - Version() → "0.0.1-stub"
//   - Capabilities() → stub.database, stub.bucket (Tier 1, full CRUD ops)
//   - ListRegions()  → [{name:"stub-east"}, {name:"stub-west"}]
//   - Plan(desired) → one "create" action per desired spec (all assumed new)
//   - Status(refs)  → each ref echoed back as "running"
//   - Destroy(refs) → each ref name echoed back as destroyed
//   - DetectDrift   → Drifted:false for every ref
//   - Import / ResolveSizing / BootstrapStateBackend → minimal valid stubs
package internal

import (
	"context"

	pb "github.com/GoCodeAlone/workflow/plugin/external/proto"
)

// StubIaCServer implements the required + two optional IaC gRPC services.
// Embed the Unimplemented stubs for forward-compat; override only the methods
// needed by scenario 92 assertions.
type StubIaCServer struct {
	pb.UnimplementedIaCProviderRequiredServer
	pb.UnimplementedIaCProviderRegionListerServer
	pb.UnimplementedIaCProviderDriftDetectorServer
}

// Compile-time assertions: StubIaCServer must satisfy every gRPC server
// interface we claim to serve so sdk.RegisterAllIaCProviderServices
// auto-registers them (type-assertion in registerIaCServicesOnly).
var (
	_ pb.IaCProviderRequiredServer      = (*StubIaCServer)(nil)
	_ pb.IaCProviderRegionListerServer  = (*StubIaCServer)(nil)
	_ pb.IaCProviderDriftDetectorServer = (*StubIaCServer)(nil)
)

// ── IaCProviderRequired ───────────────────────────────────────────────────────

// Initialize accepts any config; no cloud credentials required.
func (s *StubIaCServer) Initialize(_ context.Context, _ *pb.InitializeRequest) (*pb.InitializeResponse, error) {
	return &pb.InitializeResponse{}, nil
}

// Name returns the stable provider identifier used in scenario assertions.
func (s *StubIaCServer) Name(_ context.Context, _ *pb.NameRequest) (*pb.NameResponse, error) {
	return &pb.NameResponse{Name: "stub"}, nil
}

// Version returns the fixture version tag used in scenario assertions.
func (s *StubIaCServer) Version(_ context.Context, _ *pb.VersionRequest) (*pb.VersionResponse, error) {
	return &pb.VersionResponse{Version: "0.0.1-stub"}, nil
}

// Capabilities returns two resource types with full CRUD operations.
// Resource types use the "stub." namespace to make the fixture origin obvious
// in log output and plan previews.
func (s *StubIaCServer) Capabilities(_ context.Context, _ *pb.CapabilitiesRequest) (*pb.CapabilitiesResponse, error) {
	ops := []string{"create", "read", "update", "delete"}
	return &pb.CapabilitiesResponse{
		Capabilities: []*pb.IaCCapabilityDeclaration{
			{ResourceType: "stub.database", Tier: 1, Operations: ops},
			{ResourceType: "stub.bucket", Tier: 1, Operations: ops},
		},
		// ComputePlanVersion "v2" routes through ApplyPlanWithHooks; required
		// by the strict lifecycle cutover (workflow v0.70.0+, ADR 0024).
		ComputePlanVersion: "v2",
	}, nil
}

// Plan treats every desired spec as a "create" (no real cloud state to diff).
// Returns exactly one PlanAction per desired spec — deterministic for scenario
// assertions that check action counts.
func (s *StubIaCServer) Plan(_ context.Context, req *pb.PlanRequest) (*pb.PlanResponse, error) {
	actions := make([]*pb.PlanAction, 0, len(req.GetDesired()))
	for _, spec := range req.GetDesired() {
		actions = append(actions, &pb.PlanAction{
			Action:   "create",
			Resource: spec,
		})
	}
	return &pb.PlanResponse{
		Plan: &pb.IaCPlan{
			Actions: actions,
		},
	}, nil
}

// Destroy echoes every ref name back as destroyed (no real cloud call).
func (s *StubIaCServer) Destroy(_ context.Context, req *pb.DestroyRequest) (*pb.DestroyResponse, error) {
	destroyed := make([]string, 0, len(req.GetRefs()))
	for _, r := range req.GetRefs() {
		destroyed = append(destroyed, r.GetName())
	}
	return &pb.DestroyResponse{
		Result: &pb.DestroyResult{Destroyed: destroyed},
	}, nil
}

// Status echoes each ref back as "running" (no real cloud probe).
func (s *StubIaCServer) Status(_ context.Context, req *pb.StatusRequest) (*pb.StatusResponse, error) {
	statuses := make([]*pb.ResourceStatus, 0, len(req.GetRefs()))
	for _, r := range req.GetRefs() {
		statuses = append(statuses, &pb.ResourceStatus{
			Name:       r.GetName(),
			Type:       r.GetType(),
			ProviderId: r.GetProviderId(),
			Status:     "running",
		})
	}
	return &pb.StatusResponse{Statuses: statuses}, nil
}

// Import returns a minimal ResourceState echo so wfctl state-import round-trips
// without error (no real cloud lookup).
func (s *StubIaCServer) Import(_ context.Context, req *pb.ImportRequest) (*pb.ImportResponse, error) {
	return &pb.ImportResponse{
		State: &pb.ResourceState{
			Name:        req.GetProviderId(),
			Type:        req.GetResourceType(),
			ProviderRef: req.GetProviderId(),
		},
	}, nil
}

// ResolveSizing returns an empty ProviderSizing (stub has no slug mapping).
func (s *StubIaCServer) ResolveSizing(_ context.Context, _ *pb.ResolveSizingRequest) (*pb.ResolveSizingResponse, error) {
	return &pb.ResolveSizingResponse{Sizing: &pb.ProviderSizing{}}, nil
}

// BootstrapStateBackend returns a minimal BootstrapResult (no real storage).
func (s *StubIaCServer) BootstrapStateBackend(_ context.Context, _ *pb.BootstrapStateBackendRequest) (*pb.BootstrapStateBackendResponse, error) {
	return &pb.BootstrapStateBackendResponse{
		Result: &pb.BootstrapResult{
			Bucket:   "stub-state",
			Region:   "stub-east",
			Endpoint: "http://stub.local",
		},
	}, nil
}

// ── IaCProviderRegionLister ───────────────────────────────────────────────────

// ListRegions returns the fixed stub region set used in scenario assertions.
// Both region names are stable across runs — DO NOT change without updating
// the Playwright assertion in the infra-admin demo test.
func (s *StubIaCServer) ListRegions(_ context.Context, _ *pb.ListRegionsRequest) (*pb.ListRegionsResponse, error) {
	return &pb.ListRegionsResponse{
		Regions: []*pb.ProviderRegion{
			{Name: "stub-east", DisplayName: "Stub East"},
			{Name: "stub-west", DisplayName: "Stub West"},
		},
	}, nil
}

// ── IaCProviderDriftDetector ──────────────────────────────────────────────────

// DetectDrift reports every ref as in-sync (no drift) — the stub has no real
// cloud state to compare against.
func (s *StubIaCServer) DetectDrift(_ context.Context, req *pb.DetectDriftRequest) (*pb.DetectDriftResponse, error) {
	drifts := make([]*pb.DriftResult, 0, len(req.GetRefs()))
	for _, r := range req.GetRefs() {
		drifts = append(drifts, &pb.DriftResult{
			Name:    r.GetName(),
			Type:    r.GetType(),
			Drifted: false,
		})
	}
	return &pb.DetectDriftResponse{Drifts: drifts}, nil
}
