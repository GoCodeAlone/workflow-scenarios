// Package fixtures provides scenario-local test fixtures for scenario 92.
// These live IN the scenario repo (not the workflow engine repo) to keep
// test fixtures out of the production binary — the established pattern
// per scenarios/87-autonomous-agile-agent.
package fixtures

import (
	"context"
	"fmt"

	"github.com/GoCodeAlone/modular"
	"github.com/GoCodeAlone/workflow/interfaces"
	"github.com/GoCodeAlone/workflow/plugin"
)

// ── stub IaCProvider ──────────────────────────────────────────────────────────

// stubProvider is a no-op interfaces.IaCProvider for the scenario demo.
// No real cloud API calls are made — every lifecycle method returns a
// deterministic, non-error result.
type stubProvider struct{}

// Compile-time interface check.
var _ interfaces.IaCProvider = (*stubProvider)(nil)

func (p *stubProvider) Name() string                                          { return "stub" }
func (p *stubProvider) Version() string                                       { return "0.0.0-fixture" }
func (p *stubProvider) Initialize(_ context.Context, _ map[string]any) error { return nil }
func (p *stubProvider) Capabilities() []interfaces.IaCCapabilityDeclaration   { return nil }
func (p *stubProvider) SupportedCanonicalKeys() []string                      { return nil }
func (p *stubProvider) Close() error                                          { return nil }
func (p *stubProvider) Import(_ context.Context, _, _ string) (*interfaces.ResourceState, error) {
	return nil, nil
}
func (p *stubProvider) ResolveSizing(_ string, _ interfaces.Size, _ *interfaces.ResourceHints) (*interfaces.ProviderSizing, error) {
	return nil, nil
}
func (p *stubProvider) BootstrapStateBackend(_ context.Context, _ map[string]any) (*interfaces.BootstrapResult, error) {
	return nil, nil
}
func (p *stubProvider) Status(_ context.Context, _ []interfaces.ResourceRef) ([]interfaces.ResourceStatus, error) {
	return nil, nil
}

// Plan compares desired vs current by name: "create" for new, "update" for
// existing, "delete" for resources absent from desired.
func (p *stubProvider) Plan(_ context.Context, desired []interfaces.ResourceSpec, current []interfaces.ResourceState) (*interfaces.IaCPlan, error) {
	curByName := make(map[string]*interfaces.ResourceState, len(current))
	for i := range current {
		curByName[current[i].Name] = &current[i]
	}
	desiredNames := make(map[string]struct{}, len(desired))
	for _, s := range desired {
		desiredNames[s.Name] = struct{}{}
	}
	plan := &interfaces.IaCPlan{}
	for _, spec := range desired {
		if cur, ok := curByName[spec.Name]; ok {
			plan.Actions = append(plan.Actions, interfaces.PlanAction{Action: "update", Resource: spec, Current: cur})
		} else {
			plan.Actions = append(plan.Actions, interfaces.PlanAction{Action: "create", Resource: spec})
		}
	}
	for i := range current {
		st := &current[i]
		if _, wanted := desiredNames[st.Name]; !wanted {
			plan.Actions = append(plan.Actions, interfaces.PlanAction{
				Action:   "delete",
				Resource: interfaces.ResourceSpec{Name: st.Name, Type: st.Type},
				Current:  st,
			})
		}
	}
	return plan, nil
}

// Destroy marks all supplied refs as destroyed.
func (p *stubProvider) Destroy(_ context.Context, refs []interfaces.ResourceRef) (*interfaces.DestroyResult, error) {
	destroyed := make([]string, 0, len(refs))
	for _, r := range refs {
		destroyed = append(destroyed, r.Name)
	}
	return &interfaces.DestroyResult{Destroyed: destroyed}, nil
}

// DetectDrift returns Drifted:false with DriftClassInSync for every ref.
func (p *stubProvider) DetectDrift(_ context.Context, refs []interfaces.ResourceRef) ([]interfaces.DriftResult, error) {
	out := make([]interfaces.DriftResult, 0, len(refs))
	for _, r := range refs {
		out = append(out, interfaces.DriftResult{
			Name:    r.Name,
			Type:    r.Type,
			Drifted: false,
			Class:   interfaces.DriftClassInSync,
		})
	}
	return out, nil
}

// ResourceDriver returns a stub ResourceDriver for any resource type.
func (p *stubProvider) ResourceDriver(_ string) (interfaces.ResourceDriver, error) {
	return &stubDriver{}, nil
}

// ── stub ResourceDriver ───────────────────────────────────────────────────────

// stubDriver is a no-op ResourceDriver.
type stubDriver struct{}

var _ interfaces.ResourceDriver = (*stubDriver)(nil)

func (d *stubDriver) Create(_ context.Context, spec interfaces.ResourceSpec) (*interfaces.ResourceOutput, error) {
	return &interfaces.ResourceOutput{Name: spec.Name, Type: spec.Type, ProviderID: "stub-" + spec.Name}, nil
}

func (d *stubDriver) Read(_ context.Context, ref interfaces.ResourceRef) (*interfaces.ResourceOutput, error) {
	return &interfaces.ResourceOutput{Name: ref.Name, Type: ref.Type, ProviderID: ref.ProviderID}, nil
}

func (d *stubDriver) Update(_ context.Context, ref interfaces.ResourceRef, spec interfaces.ResourceSpec) (*interfaces.ResourceOutput, error) {
	return &interfaces.ResourceOutput{Name: spec.Name, Type: spec.Type, ProviderID: ref.ProviderID}, nil
}

func (d *stubDriver) Delete(_ context.Context, _ interfaces.ResourceRef) error { return nil }

func (d *stubDriver) Diff(_ context.Context, _ interfaces.ResourceSpec, _ *interfaces.ResourceOutput) (*interfaces.DiffResult, error) {
	return &interfaces.DiffResult{NeedsUpdate: false, NeedsReplace: false}, nil
}

func (d *stubDriver) HealthCheck(_ context.Context, ref interfaces.ResourceRef) (*interfaces.HealthResult, error) {
	return &interfaces.HealthResult{Healthy: true, Message: "stub: always healthy"}, nil
}

func (d *stubDriver) Scale(_ context.Context, _ interfaces.ResourceRef, _ int) (*interfaces.ResourceOutput, error) {
	return nil, nil
}

func (d *stubDriver) SensitiveKeys() []string { return nil }

// ── EnginePlugin ──────────────────────────────────────────────────────────────

// StubProviderPlugin returns an EnginePlugin that registers the "iac.provider"
// module type backed by the in-scenario stub provider. Pass this to
// workflow.NewEngineBuilder().WithPlugin(fixtures.StubProviderPlugin()).
func StubProviderPlugin() plugin.EnginePlugin {
	return &stubProviderPlugin{
		BaseEnginePlugin: plugin.BaseEnginePlugin{
			BaseNativePlugin: plugin.BaseNativePlugin{
				PluginName:        "scenario92-stubprovider",
				PluginVersion:     "0.1.0",
				PluginDescription: "Scenario-92 stub iac.provider — no real cloud ops",
			},
			Manifest: plugin.PluginManifest{
				Name:        "scenario92-stubprovider",
				Version:     "0.1.0",
				Author:      "GoCodeAlone",
				Description: "Scenario-92 stub iac.provider — no real cloud ops",
				ModuleTypes: []string{"iac.provider"},
			},
		},
	}
}

type stubProviderPlugin struct {
	plugin.BaseEnginePlugin
}

var _ plugin.EnginePlugin = (*stubProviderPlugin)(nil)

func (p *stubProviderPlugin) ModuleFactories() map[string]plugin.ModuleFactory {
	return map[string]plugin.ModuleFactory{
		"iac.provider": func(name string, cfg map[string]any) modular.Module {
			return &stubProviderModule{name: name, cfg: cfg}
		},
	}
}

// ── stubProviderModule ────────────────────────────────────────────────────────

type stubProviderModule struct {
	name     string
	cfg      map[string]any
	provider *stubProvider
}

func (m *stubProviderModule) Name() string { return m.name }

func (m *stubProviderModule) Init(app modular.Application) error {
	pt, _ := m.cfg["provider"].(string)
	if pt != "stub" {
		return fmt.Errorf("scenario92/fixtures: module %q: provider must be 'stub', got %q", m.name, pt)
	}
	m.provider = &stubProvider{}
	app.Logger().Warn("scenario-92 stub provider: NO real cloud operations — demo/test only", "module", m.name)
	return nil
}

// ProvidesServices registers the stub provider under the module name so
// infra.admin can resolve it via app.GetService(m.name, &iacProvider).
func (m *stubProviderModule) ProvidesServices() []modular.ServiceProvider {
	if m.provider == nil {
		m.provider = &stubProvider{}
	}
	return []modular.ServiceProvider{{
		Name:        m.name,
		Description: "scenario-92 stub iac.provider",
		Instance:    m.provider,
	}}
}

func (m *stubProviderModule) RequiresServices() []modular.ServiceDependency { return nil }
