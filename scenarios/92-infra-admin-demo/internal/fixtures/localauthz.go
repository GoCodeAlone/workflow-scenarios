package fixtures

import (
	"github.com/GoCodeAlone/modular"
	"github.com/GoCodeAlone/workflow/plugin"
)

// LocalAuthzPlugin returns an EnginePlugin that registers the "authz.local"
// module type — an in-process RBAC enforcer for the scenario demo. The module
// satisfies the module.Enforcer interface (variadic Enforce method) and
// registers itself as a service so infra.admin can resolve it via
// app.GetService(authzModule, &Enforcer).
//
// Config shape (YAML):
//
//	type: authz.local
//	config:
//	  policies:
//	    - ["operator", "infra:read",    "allow"]
//	    - ["operator", "infra:apply",   "allow"]
//	    - ["operator", "infra:destroy", "allow"]
//	    - ["viewer",   "infra:read",    "allow"]
//
// Each policy is a [subject, object, action] triple. Default-deny.
func LocalAuthzPlugin() plugin.EnginePlugin {
	return &localAuthzPlugin{
		BaseEnginePlugin: plugin.BaseEnginePlugin{
			BaseNativePlugin: plugin.BaseNativePlugin{
				PluginName:        "scenario92-localauthz",
				PluginVersion:     "0.1.0",
				PluginDescription: "Scenario-92 in-process RBAC enforcer (authz.local)",
			},
			Manifest: plugin.PluginManifest{
				Name:        "scenario92-localauthz",
				Version:     "0.1.0",
				Author:      "GoCodeAlone",
				Description: "Scenario-92 in-process RBAC enforcer (authz.local)",
				ModuleTypes: []string{"authz.local"},
			},
		},
	}
}

type localAuthzPlugin struct {
	plugin.BaseEnginePlugin
}

var _ plugin.EnginePlugin = (*localAuthzPlugin)(nil)

func (p *localAuthzPlugin) ModuleFactories() map[string]plugin.ModuleFactory {
	return map[string]plugin.ModuleFactory{
		"authz.local": func(name string, cfg map[string]any) modular.Module {
			return &localAuthzModule{name: name, cfg: cfg}
		},
	}
}

// ── policy triple ─────────────────────────────────────────────────────────────

type authzPolicy struct{ sub, obj, act string }

// ── module ────────────────────────────────────────────────────────────────────

type localAuthzModule struct {
	name     string
	cfg      map[string]any
	policies []authzPolicy
}

func (m *localAuthzModule) Name() string { return m.name }

func (m *localAuthzModule) Init(app modular.Application) error {
	m.policies = parseAuthzPolicies(m.cfg)
	app.Logger().Info("authz.local: loaded policies",
		"module", m.name,
		"count", len(m.policies),
	)
	return nil
}

// ProvidesServices registers this module under its own name so
// infra.admin can resolve it via app.GetService(authzModule, &Enforcer).
func (m *localAuthzModule) ProvidesServices() []modular.ServiceProvider {
	return []modular.ServiceProvider{{
		Name:        m.name,
		Description: "scenario-92 in-process RBAC enforcer",
		Instance:    m,
	}}
}

func (m *localAuthzModule) RequiresServices() []modular.ServiceDependency { return nil }

// Enforce checks whether (sub, obj, act) matches any configured policy.
// The variadic extra ...string matches the concrete module.Enforcer signature
// (plan-review C-NEW-1 constraint). Default-deny: returns false when no
// policy matches.
func (m *localAuthzModule) Enforce(sub, obj, act string, _ ...string) (bool, error) {
	for _, p := range m.policies {
		if p.sub == sub && p.obj == obj && p.act == act {
			return true, nil
		}
	}
	return false, nil
}

// parseAuthzPolicies decodes config.policies from the raw map.
// Accepts []any{[]any{string, string, string}, ...} (YAML-decoded shape).
func parseAuthzPolicies(cfg map[string]any) []authzPolicy {
	raw, ok := cfg["policies"]
	if !ok {
		return nil
	}
	items, ok := raw.([]any)
	if !ok {
		return nil
	}
	out := make([]authzPolicy, 0, len(items))
	for _, item := range items {
		row, ok := item.([]any)
		if !ok || len(row) < 3 {
			continue
		}
		sub, _ := row[0].(string)
		obj, _ := row[1].(string)
		act, _ := row[2].(string)
		if sub != "" && obj != "" && act != "" {
			out = append(out, authzPolicy{sub, obj, act})
		}
	}
	return out
}
