// Command scenario92-server is the workflow server for scenario 92
// (infra-admin migration demo). It bootstraps the workflow engine with:
//   - All default workflow plugins (auth, http, platform, etc.) — in-process
//   - External gRPC plugins discovered from <data-dir>/plugins:
//     stub-iac-provider: scenario fixture IaC provider (built from fixtures/stub-iac-provider)
//     workflow-plugin-admin: admin.dashboard module
//   - NO in-process test fixtures (migration: fixtures removed per ADR-0010)
//
// The stub-iac-provider is loaded as an EXTERNAL plugin. The engine's
// WiringHook (ExternalPluginAdapter.WiringHooks) registers it as an
// interfaces.IaCProvider service under the plugin name "stub-iac-provider"
// so the step.iac_provider_* steps can resolve it via `provider: stub-iac-provider`.
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

	// Build the engine with in-process plugins (defaults including the platform
	// plugin which registers step.iac_provider_*). No in-process fixtures —
	// the stub IaC provider is an external gRPC plugin.
	engine, err := workflow.NewEngineBuilder().
		WithAllDefaults().
		WithLogger(logger).
		WithPlugins(all.DefaultPlugins()...).
		Build()
	if err != nil {
		log.Fatalf("failed to build engine: %v", err)
	}

	// Discover + load external gRPC plugins from <data-dir>/plugins.
	// Required plugins:
	//   stub-iac-provider → IaCProvider service (WiringHook registers as "stub-iac-provider")
	//   workflow-plugin-admin → admin.dashboard module
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

	// Apply the configuration (admin.dashboard + stub-iac-provider all registered).
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
