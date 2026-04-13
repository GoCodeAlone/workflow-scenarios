// Command scenario85-server is the workflow server for scenario 85.
// It bootstraps the workflow engine with the agent plugin loaded,
// enabling self-improvement pipelines (step.agent_execute,
// step.blackboard_*, step.self_improve_*, agent.guardrails, etc.).
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

	ratchetplugin "github.com/GoCodeAlone/workflow-plugin-agent/orchestrator"
	"github.com/GoCodeAlone/workflow"
	"github.com/GoCodeAlone/workflow/config"
	"github.com/GoCodeAlone/workflow/plugins/all"
	_ "github.com/GoCodeAlone/workflow/setup"
	_ "modernc.org/sqlite"
)

var (
	configPath = flag.String("config", "config/base-app.yaml", "path to workflow config file")
	dataDir    = flag.String("data-dir", "/data", "data directory for SQLite stores")
)

func main() {
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	logger.Info("starting scenario-87 server",
		"config", *configPath,
		"data-dir", *dataDir,
	)

	cfg, err := config.LoadFromFile(*configPath)
	if err != nil {
		log.Fatalf("Failed to load config %s: %v", *configPath, err)
	}

	engine, err := workflow.NewEngineBuilder().
		WithAllDefaults().
		WithLogger(logger).
		WithPlugins(all.DefaultPlugins()...).
		WithPlugin(ratchetplugin.New()).
		BuildFromConfig(cfg)
	if err != nil {
		log.Fatalf("Failed to build engine: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	if err := engine.Start(ctx); err != nil {
		log.Fatalf("Failed to start engine: %v", err)
	}

	fmt.Println("Scenario 87 server running")

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	cancel()
	if err := engine.Stop(context.Background()); err != nil {
		logger.Error("engine stop error", "error", err)
	}
}
