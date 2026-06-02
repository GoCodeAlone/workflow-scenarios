// Command scenario92-server is the workflow server for scenario 92
// (infra-admin v1.1 demo). It bootstraps the workflow engine with:
//   - All default workflow plugins (auth, http, etc.) — in-process
//   - Scenario-local stub iac.provider + authz.local RBAC enforcer — in-process
//     fixtures that live in THIS repo, never in the workflow engine binary
//   - workflow-plugin-admin (admin.dashboard) — discovered + loaded as an
//     external gRPC plugin from <data-dir>/plugins, exactly as the stock
//     workflow server does
//
// Keeping test fixtures inside the scenario repo (not the workflow engine)
// follows the established pattern from scenarios/85/86/87.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/GoCodeAlone/workflow"
	"github.com/GoCodeAlone/workflow/config"
	pluginexternal "github.com/GoCodeAlone/workflow/plugin/external"
	"github.com/GoCodeAlone/workflow/plugins/all"
	_ "github.com/GoCodeAlone/workflow/setup"
	_ "modernc.org/sqlite"

	"github.com/GoCodeAlone/workflow-scenarios/scenarios/92-infra-admin-demo/internal/fixtures"
)

var (
	configPath = flag.String("config", "config/app.yaml", "path to workflow config file")
	dataDir    = flag.String("data-dir", "/home/nonroot", "data directory (plugins/ sub-dir, SQLite store)")
)

func main() {
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	logger.Info("starting scenario-92 server", "config", *configPath, "data-dir", *dataDir)

	cfg, err := config.LoadFromFile(*configPath)
	if err != nil {
		log.Fatalf("failed to load config %s: %v", *configPath, err)
	}

	// Build the engine with in-process plugins (defaults + scenario fixtures),
	// but NOT yet configured — Build() (not BuildFromConfig) so we can load
	// external plugins before config validation runs.
	engine, err := workflow.NewEngineBuilder().
		WithAllDefaults().
		WithLogger(logger).
		WithPlugins(all.DefaultPlugins()...).
		// Scenario-local fixtures — never enter the production workflow binary.
		WithPlugin(fixtures.StubProviderPlugin()).
		WithPlugin(fixtures.LocalAuthzPlugin()).
		Build()
	if err != nil {
		log.Fatalf("failed to build engine: %v", err)
	}

	// Discover + load external gRPC plugins (workflow-plugin-admin →
	// admin.dashboard) from <data-dir>/plugins, mirroring the stock server.
	// Must happen before BuildFromConfig so admin.dashboard validates.
	extPluginDir := filepath.Join(*dataDir, "plugins")
	extMgr := pluginexternal.NewExternalPluginManager(extPluginDir, log.Default())
	extMgr.SetCallbackServer(pluginexternal.NewCallbackServer(
		func(triggerType, action string, data map[string]any) error {
			return engine.TriggerWorkflow(context.Background(), triggerType, action, data)
		},
		nil,
		log.Default(),
	))
	discovered, discoverErr := extMgr.DiscoverPlugins()
	if discoverErr != nil {
		logger.Warn("failed to discover external plugins", "error", discoverErr)
	}
	for _, name := range discovered {
		adapter, loadErr := extMgr.LoadPlugin(name)
		if loadErr != nil {
			logger.Warn("failed to load external plugin", "plugin", name, "error", loadErr)
			continue
		}
		if err := engine.LoadPlugin(adapter); err != nil {
			logger.Warn("failed to register external plugin", "plugin", name, "error", err)
			continue
		}
		logger.Info("loaded external plugin", "plugin", name)
	}

	// Register a custom HTTP pipeline trigger config wrapper that injects the
	// router and server names. This ensures pipeline HTTP triggers (e.g.
	// infra-catalog, infra-plan, etc.) bind to the workflow engine's http-router
	// instead of the admin plugin's admin-router. Without this, the engine scans
	// all services for the first HTTPRouter implementation — which is
	// non-deterministic when both http-router and admin-router are present.
	//
	// The wrapper mirrors the default (from plugins/http/plugin.go) but adds
	// router: "http-router" and server: "http" so ConfigureWorkflow uses the
	// explicit names instead of falling back to the service scan.
	// The custom HTTP trigger wrapper is no longer needed now that the router
	// module is named "router" (a well-known name in HTTPTrigger.Configure's
	// scan list: ["httpRouter", "api-router", "router"]). When the router is
	// found by name, it reliably binds to our workflow server (port 8080)
	// rather than the admin plugin's admin-router (port 8081).
	// Wrapper left as a no-op for documentation purposes.

	// Now apply the configuration (admin.dashboard + infra.admin + authz.local
	// + stub-provider all registered).
	if err := engine.BuildFromConfig(cfg); err != nil {
		log.Fatalf("failed to build from config: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	if err := engine.Start(ctx); err != nil {
		log.Fatalf("failed to start engine: %v", err)
	}
	fmt.Println("Scenario 92 server running")

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	cancel()
	if err := engine.Stop(context.Background()); err != nil {
		logger.Error("engine stop error", "error", err)
	}
}
