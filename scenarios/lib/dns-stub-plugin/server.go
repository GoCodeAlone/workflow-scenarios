// Package main — pb.IaCProvider*Server wrapper for the DNS stub plugin.
// Mirrors the shape of workflow-plugin-cloudflare/internal/iacserver.go
// + workflow-plugin-digitalocean/internal/iacserver.go (the canonical
// marshalling reference); every gRPC method delegates to *stubProvider
// after JSON-unmarshalling the wire payload to the matching
// interfaces.* type. Per docs/plans/2026-05-26-dns-provider-contract.md
// PR 9 (Task 30).
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"time"

	"github.com/GoCodeAlone/workflow/interfaces"
	"github.com/GoCodeAlone/workflow/platform"
	pb "github.com/GoCodeAlone/workflow/plugin/external/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// Version stamped via -ldflags at build time.
var Version = "0.0.1"

type stubIaCServer struct {
	pb.UnimplementedIaCProviderRequiredServer
	pb.UnimplementedIaCProviderFinalizerServer
	pb.UnimplementedIaCProviderEnumeratorServer

	provider *stubProvider
}

var (
	_ pb.IaCProviderRequiredServer   = (*stubIaCServer)(nil)
	_ pb.IaCProviderFinalizerServer  = (*stubIaCServer)(nil)
	_ pb.IaCProviderEnumeratorServer = (*stubIaCServer)(nil)
)

func NewIaCServer() *stubIaCServer {
	return &stubIaCServer{provider: &stubProvider{}}
}

// ── Required service methods ─────────────────────────────────────────────

func (s *stubIaCServer) Name(_ context.Context, _ *pb.NameRequest) (*pb.NameResponse, error) {
	return &pb.NameResponse{Name: s.provider.Name()}, nil
}

func (s *stubIaCServer) Version(_ context.Context, _ *pb.VersionRequest) (*pb.VersionResponse, error) {
	return &pb.VersionResponse{Version: s.provider.Version()}, nil
}

func (s *stubIaCServer) Capabilities(_ context.Context, _ *pb.CapabilitiesRequest) (*pb.CapabilitiesResponse, error) {
	caps := s.provider.Capabilities()
	out := make([]*pb.IaCCapabilityDeclaration, 0, len(caps))
	for _, c := range caps {
		tier := c.Tier
		if tier < math.MinInt32 {
			tier = math.MinInt32
		} else if tier > math.MaxInt32 {
			tier = math.MaxInt32
		}
		out = append(out, &pb.IaCCapabilityDeclaration{
			ResourceType: c.ResourceType,
			Tier:         int32(tier), //nolint:gosec // bounded above
			Operations:   append([]string(nil), c.Operations...),
		})
	}
	return &pb.CapabilitiesResponse{Capabilities: out, ComputePlanVersion: "v2"}, nil
}

func (s *stubIaCServer) Initialize(ctx context.Context, req *pb.InitializeRequest) (*pb.InitializeResponse, error) {
	cfg, err := unmarshalJSONMap(req.GetConfigJson())
	if err != nil {
		return nil, fmt.Errorf("stub iacserver: parse config_json: %w", err)
	}
	if err := s.provider.Initialize(ctx, cfg); err != nil {
		return nil, err
	}
	return &pb.InitializeResponse{}, nil
}

func (s *stubIaCServer) Plan(ctx context.Context, req *pb.PlanRequest) (*pb.PlanResponse, error) {
	desired, err := specsFromPB(req.GetDesired())
	if err != nil {
		return nil, fmt.Errorf("stub iacserver: decode Plan desired: %w", err)
	}
	current, err := statesFromPB(req.GetCurrent())
	if err != nil {
		return nil, fmt.Errorf("stub iacserver: decode Plan current: %w", err)
	}
	plan, err := platform.ComputePlan(ctx, s.provider, desired, current)
	if err != nil {
		return nil, err
	}
	pbPlan, err := planToPB(&plan)
	if err != nil {
		return nil, fmt.Errorf("stub iacserver: encode Plan response: %w", err)
	}
	return &pb.PlanResponse{Plan: pbPlan}, nil
}

func (s *stubIaCServer) Destroy(ctx context.Context, req *pb.DestroyRequest) (*pb.DestroyResponse, error) {
	refs := refsFromPB(req.GetRefs())
	result, err := s.provider.Destroy(ctx, refs)
	if err != nil {
		return nil, err
	}
	pbErrs := make([]*pb.ActionError, 0, len(result.Errors))
	for _, e := range result.Errors {
		pbErrs = append(pbErrs, &pb.ActionError{Resource: e.Resource, Action: e.Action, Error: e.Error})
	}
	return &pb.DestroyResponse{Result: &pb.DestroyResult{Destroyed: result.Destroyed, Errors: pbErrs}}, nil
}

func (s *stubIaCServer) Status(ctx context.Context, req *pb.StatusRequest) (*pb.StatusResponse, error) {
	refs := refsFromPB(req.GetRefs())
	statuses, err := s.provider.Status(ctx, refs)
	if err != nil {
		return nil, err
	}
	pbStats := make([]*pb.ResourceStatus, 0, len(statuses))
	for _, st := range statuses {
		outputsJSON, _ := json.Marshal(st.Outputs)
		pbStats = append(pbStats, &pb.ResourceStatus{
			Name:        st.Name,
			Type:        st.Type,
			ProviderId:  st.ProviderID,
			Status:      st.Status,
			OutputsJson: outputsJSON,
		})
	}
	return &pb.StatusResponse{Statuses: pbStats}, nil
}

func (s *stubIaCServer) Import(ctx context.Context, req *pb.ImportRequest) (*pb.ImportResponse, error) {
	resourceType := req.GetResourceType()
	if resourceType == "" {
		resourceType = "infra.dns"
	}
	state, err := s.provider.Import(ctx, req.GetProviderId(), resourceType)
	if err != nil {
		return nil, err
	}
	pbState, err := stateToPB(state)
	if err != nil {
		return nil, fmt.Errorf("stub iacserver: encode Import state: %w", err)
	}
	return &pb.ImportResponse{State: pbState}, nil
}

func (s *stubIaCServer) ResolveSizing(_ context.Context, _ *pb.ResolveSizingRequest) (*pb.ResolveSizingResponse, error) {
	return &pb.ResolveSizingResponse{Sizing: nil}, nil
}

func (s *stubIaCServer) BootstrapStateBackend(_ context.Context, _ *pb.BootstrapStateBackendRequest) (*pb.BootstrapStateBackendResponse, error) {
	return &pb.BootstrapStateBackendResponse{Result: nil}, nil
}

func (s *stubIaCServer) FinalizeApply(_ context.Context, _ *pb.FinalizeApplyRequest) (*pb.FinalizeApplyResponse, error) {
	return &pb.FinalizeApplyResponse{}, nil
}

// EnumerateAll satisfies pb.IaCProviderEnumeratorServer.EnumerateAll —
// wfctl infra import-all drives this for the stub.
func (s *stubIaCServer) EnumerateAll(ctx context.Context, req *pb.EnumerateAllRequest) (*pb.EnumerateAllResponse, error) {
	outs, err := s.provider.EnumerateAll(ctx, req.GetResourceType())
	if err != nil {
		return nil, err
	}
	pbOuts := make([]*pb.ResourceOutput, 0, len(outs))
	for _, o := range outs {
		if o == nil {
			continue
		}
		outputsJSON, err := marshalJSONMap(o.Outputs)
		if err != nil {
			return nil, fmt.Errorf("stub iacserver: encode EnumerateAll outputs: %w", err)
		}
		sensitive := make(map[string]bool, len(o.Sensitive))
		for k, v := range o.Sensitive {
			sensitive[k] = v
		}
		pbOuts = append(pbOuts, &pb.ResourceOutput{
			Name:        o.Name,
			Type:        o.Type,
			ProviderId:  o.ProviderID,
			OutputsJson: outputsJSON,
			Sensitive:   sensitive,
			Status:      o.Status,
		})
	}
	return &pb.EnumerateAllResponse{Outputs: pbOuts}, nil
}

// ── pb<->Go marshalling helpers ──────────────────────────────────────────
// Mirror workflow-plugin-digitalocean/internal/iacserver.go (canonical
// reference). Stub provider only needs the subset exercised by Plan +
// Import + EnumerateAll, so DriftDetector / DriftConfig / Validator
// marshalling is intentionally omitted.

func marshalJSONMap(m map[string]any) ([]byte, error) {
	if m == nil {
		return nil, nil
	}
	return json.Marshal(m)
}

func unmarshalJSONMap(b []byte) (map[string]any, error) {
	if len(b) == 0 {
		return nil, nil
	}
	var out map[string]any
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func marshalJSONAny(v any) ([]byte, error) {
	if v == nil {
		return nil, nil
	}
	return json.Marshal(v)
}

func unmarshalJSONAny(b []byte) (any, error) {
	if len(b) == 0 {
		return nil, nil
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func timeToPB(t time.Time) *timestamppb.Timestamp {
	if t.IsZero() {
		return nil
	}
	return timestamppb.New(t)
}

func timeFromPB(t *timestamppb.Timestamp) time.Time {
	if t == nil {
		return time.Time{}
	}
	return t.AsTime()
}

func refFromPB(r *pb.ResourceRef) interfaces.ResourceRef {
	if r == nil {
		return interfaces.ResourceRef{}
	}
	return interfaces.ResourceRef{Name: r.GetName(), Type: r.GetType(), ProviderID: r.GetProviderId()}
}

func refsFromPB(refs []*pb.ResourceRef) []interfaces.ResourceRef {
	out := make([]interfaces.ResourceRef, 0, len(refs))
	for _, r := range refs {
		out = append(out, refFromPB(r))
	}
	return out
}

func specToPB(s interfaces.ResourceSpec) (*pb.ResourceSpec, error) {
	cfgJSON, err := marshalJSONMap(s.Config)
	if err != nil {
		return nil, err
	}
	return &pb.ResourceSpec{
		Name:       s.Name,
		Type:       s.Type,
		ConfigJson: cfgJSON,
		Size:       string(s.Size),
		DependsOn:  append([]string(nil), s.DependsOn...),
	}, nil
}

func specFromPB(s *pb.ResourceSpec) (interfaces.ResourceSpec, error) {
	if s == nil {
		return interfaces.ResourceSpec{}, nil
	}
	cfg, err := unmarshalJSONMap(s.GetConfigJson())
	if err != nil {
		return interfaces.ResourceSpec{}, err
	}
	return interfaces.ResourceSpec{
		Name:      s.GetName(),
		Type:      s.GetType(),
		Config:    cfg,
		Size:      interfaces.Size(s.GetSize()),
		DependsOn: append([]string(nil), s.GetDependsOn()...),
	}, nil
}

func specsFromPB(specs []*pb.ResourceSpec) ([]interfaces.ResourceSpec, error) {
	out := make([]interfaces.ResourceSpec, 0, len(specs))
	for _, s := range specs {
		gs, err := specFromPB(s)
		if err != nil {
			return nil, err
		}
		out = append(out, gs)
	}
	return out, nil
}

func stateToPB(st *interfaces.ResourceState) (*pb.ResourceState, error) {
	if st == nil {
		return nil, nil
	}
	appliedJSON, err := marshalJSONMap(st.AppliedConfig)
	if err != nil {
		return nil, err
	}
	outputsJSON, err := marshalJSONMap(st.Outputs)
	if err != nil {
		return nil, err
	}
	return &pb.ResourceState{
		Id:                  st.ID,
		Name:                st.Name,
		Type:                st.Type,
		Provider:            st.Provider,
		ProviderRef:         st.ProviderRef,
		ProviderId:          st.ProviderID,
		ConfigHash:          st.ConfigHash,
		AppliedConfigJson:   appliedJSON,
		AppliedConfigSource: st.AppliedConfigSource,
		OutputsJson:         outputsJSON,
		Dependencies:        append([]string(nil), st.Dependencies...),
		CreatedAt:           timeToPB(st.CreatedAt),
		UpdatedAt:           timeToPB(st.UpdatedAt),
		LastDriftCheck:      timeToPB(st.LastDriftCheck),
	}, nil
}

func stateFromPB(s *pb.ResourceState) (*interfaces.ResourceState, error) {
	if s == nil {
		return nil, nil
	}
	applied, err := unmarshalJSONMap(s.GetAppliedConfigJson())
	if err != nil {
		return nil, err
	}
	outputs, err := unmarshalJSONMap(s.GetOutputsJson())
	if err != nil {
		return nil, err
	}
	return &interfaces.ResourceState{
		ID:                  s.GetId(),
		Name:                s.GetName(),
		Type:                s.GetType(),
		Provider:            s.GetProvider(),
		ProviderRef:         s.GetProviderRef(),
		ProviderID:          s.GetProviderId(),
		ConfigHash:          s.GetConfigHash(),
		AppliedConfig:       applied,
		AppliedConfigSource: s.GetAppliedConfigSource(),
		Outputs:             outputs,
		Dependencies:        append([]string(nil), s.GetDependencies()...),
		CreatedAt:           timeFromPB(s.GetCreatedAt()),
		UpdatedAt:           timeFromPB(s.GetUpdatedAt()),
		LastDriftCheck:      timeFromPB(s.GetLastDriftCheck()),
	}, nil
}

func statesFromPB(states []*pb.ResourceState) ([]interfaces.ResourceState, error) {
	out := make([]interfaces.ResourceState, 0, len(states))
	for _, s := range states {
		gs, err := stateFromPB(s)
		if err != nil {
			return nil, err
		}
		if gs != nil {
			out = append(out, *gs)
		}
	}
	return out, nil
}

func changesToPB(changes []interfaces.FieldChange) ([]*pb.FieldChange, error) {
	out := make([]*pb.FieldChange, 0, len(changes))
	for _, c := range changes {
		oldJSON, err := marshalJSONAny(c.Old)
		if err != nil {
			return nil, err
		}
		newJSON, err := marshalJSONAny(c.New)
		if err != nil {
			return nil, err
		}
		out = append(out, &pb.FieldChange{
			Path:     c.Path,
			OldJson:  oldJSON,
			NewJson:  newJSON,
			ForceNew: c.ForceNew,
		})
	}
	return out, nil
}

func planActionToPB(a interfaces.PlanAction) (*pb.PlanAction, error) {
	pbSpec, err := specToPB(a.Resource)
	if err != nil {
		return nil, err
	}
	var pbCurrent *pb.ResourceState
	if a.Current != nil {
		pbCurrent, err = stateToPB(a.Current)
		if err != nil {
			return nil, err
		}
	}
	pbChanges, err := changesToPB(a.Changes)
	if err != nil {
		return nil, err
	}
	return &pb.PlanAction{
		Action:             a.Action,
		Resource:           pbSpec,
		Current:            pbCurrent,
		Changes:            pbChanges,
		ResolvedConfigHash: a.ResolvedConfigHash,
	}, nil
}

func planToPB(p *interfaces.IaCPlan) (*pb.IaCPlan, error) {
	if p == nil {
		return nil, nil
	}
	pbActions := make([]*pb.PlanAction, 0, len(p.Actions))
	for i := range p.Actions {
		pa, err := planActionToPB(p.Actions[i])
		if err != nil {
			return nil, err
		}
		pbActions = append(pbActions, pa)
	}
	if p.SchemaVersion < math.MinInt32 || p.SchemaVersion > math.MaxInt32 {
		return nil, fmt.Errorf("stub iacserver: plan SchemaVersion %d out of int32 range", p.SchemaVersion)
	}
	return &pb.IaCPlan{
		Id:            p.ID,
		Actions:       pbActions,
		CreatedAt:     timeToPB(p.CreatedAt),
		DesiredHash:   p.DesiredHash,
		SchemaVersion: int32(p.SchemaVersion), //nolint:gosec // range-checked above
		InputSnapshot: copyStringMap(p.InputSnapshot),
	}, nil
}

func copyStringMap(m map[string]string) map[string]string {
	if len(m) == 0 {
		return nil
	}
	out := make(map[string]string, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

// unused-import guards so a future maintainer doesn't trim a helper that's
// referenced solely from a test in this package (none yet, but the slot
// exists for backstop coverage).
var (
	_ = unmarshalJSONAny
	_ = changesToPB
)
