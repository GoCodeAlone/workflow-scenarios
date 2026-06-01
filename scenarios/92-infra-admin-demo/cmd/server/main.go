// Command scenario92-server is the workflow server for scenario 92
// (infra-admin v1.1 demo). It bootstraps the workflow engine with:
//   - All default workflow plugins (auth, http, admin, etc.)
//   - workflow-plugin-admin (loaded externally via -data-dir)
//   - Scenario-local stub iac.provider (no real cloud API calls)
//   - Scenario-local authz.local in-process RBAC enforcer
//
// Keeping test fixtures inside the scenario repo (not the workflow engine)
// follows the established pattern from scenarios/87-autonomous-agile-agent.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/GoCodeAlone/workflow"
	"github.com/GoCodeAlone/workflow/config"
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

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	logger.Info("starting scenario-92 server",
		"config", *configPath,
		"data-dir", *dataDir,
	)

	cfg, err := config.LoadFromFile(*configPath)
	if err != nil {
		log.Fatalf("failed to load config %s: %v", *configPath, err)
	}

	engine, err := workflow.NewEngineBuilder().
		WithAllDefaults().
		WithLogger(logger).
		WithPlugins(all.DefaultPlugins()...).
		// Scenario-local fixtures: stub iac.provider + in-process authz.local RBAC.
		// These live in the scenario repo so test fixtures never enter the
		// production workflow binary.
		WithPlugin(fixtures.StubProviderPlugin()).
		WithPlugin(fixtures.LocalAuthzPlugin()).
		BuildFromConfig(cfg)
	if err != nil {
		log.Fatalf("failed to build engine: %v", err)
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
