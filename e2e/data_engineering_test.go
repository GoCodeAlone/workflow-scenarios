// Package e2e contains Go execution tests for the data-engineering scenarios.
// Each test creates plugin instances, initialises modules with configs that
// mirror the scenario app.yaml, runs step lifecycles, and verifies outputs.
package e2e

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	sqlmock "github.com/DATA-DOG/go-sqlmock"
	"github.com/GoCodeAlone/workflow-plugin-data-engineering/testhelpers"
	sdk "github.com/GoCodeAlone/workflow/plugin/external/sdk"
)

// ─── helpers ─────────────────────────────────────────────────────────────────

// dePlugin is the minimal interface exported by the data-engineering plugin.
type dePlugin interface {
	ModuleTypes() []string
	CreateModule(typeName, name string, config map[string]any) (sdk.ModuleInstance, error)
	StepTypes() []string
	CreateStep(typeName, name string, config map[string]any) (sdk.StepInstance, error)
}

func newDEPlugin(t *testing.T) dePlugin {
	t.Helper()
	p, ok := testhelpers.NewPlugin("e2e-test").(dePlugin)
	if !ok {
		t.Fatal("plugin does not implement expected provider interfaces")
	}
	return p
}

// exec runs a step with the given runtime config.
func exec(ctx context.Context, step sdk.StepInstance, config map[string]any) (*sdk.StepResult, error) {
	return step.Execute(ctx, nil, nil, nil, nil, config)
}

// writeJSON is a test-server helper that encodes v as JSON with the given status.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// ─── Scenario 79 — CDC Pipeline ──────────────────────────────────────────────
//
// Mirrors: scenarios/79-data-cdc-pipeline/config/app.yaml
// Modules: cdc.source (provider: memory) + data.tenancy (schema_per_tenant)

func TestScenario79_CDCPipeline(t *testing.T) {
	p := newDEPlugin(t)
	ctx := context.Background()

	sourceID := "s79-pg-cdc"
	testhelpers.CDCUnregisterSource(sourceID)
	t.Cleanup(func() { testhelpers.CDCUnregisterSource(sourceID) })

	// ── Module: cdc.source (provider: memory, mirrors the bento+postgres in prod) ──
	cdcMod, err := p.CreateModule("cdc.source", "s79-cdc-mod", map[string]any{
		"provider":    "memory",
		"source_id":   sourceID,
		"source_type": "postgres",
		"connection":  "postgres://postgres.internal/appdb",
	})
	if err != nil {
		t.Fatalf("CreateModule cdc.source: %v", err)
	}
	if err := cdcMod.Init(); err != nil {
		t.Fatalf("cdcMod.Init: %v", err)
	}
	if err := cdcMod.Start(ctx); err != nil {
		t.Fatalf("cdcMod.Start: %v", err)
	}
	t.Cleanup(func() {
		if err := cdcMod.Stop(ctx); err != nil {
			if !strings.Contains(err.Error(), "not found") && !strings.Contains(err.Error(), "not connected") {
				t.Logf("cdcMod.Stop: %v", err)
			}
		}
	})

	// ── Module: data.tenancy ──
	tenancyMod, err := p.CreateModule("data.tenancy", "s79-tenancy-mod", map[string]any{
		"strategy":      "schema_per_tenant",
		"schema_prefix": "tenant_",
	})
	if err != nil {
		t.Fatalf("CreateModule data.tenancy: %v", err)
	}
	if err := tenancyMod.Init(); err != nil {
		t.Fatalf("tenancyMod.Init: %v", err)
	}
	if err := tenancyMod.Start(ctx); err != nil {
		t.Fatalf("tenancyMod.Start: %v", err)
	}
	t.Cleanup(func() { _ = tenancyMod.Stop(ctx) })

	// ── step.tenant_provision ──
	provStep, err := p.CreateStep("step.tenant_provision", "s79-prov", map[string]any{
		"strategy":      "schema_per_tenant",
		"schema_prefix": "tenant_",
	})
	if err != nil {
		t.Fatalf("CreateStep tenant_provision: %v", err)
	}
	result, err := exec(ctx, provStep, map[string]any{"tenant_id": "acme"})
	if err != nil {
		t.Fatalf("tenant_provision: %v", err)
	}
	if result.Output["status"] != "provisioned" {
		t.Errorf("tenant_provision: expected status=provisioned, got %v", result.Output["status"])
	}

	// ── step.cdc_start ──
	startStep, err := p.CreateStep("step.cdc_start", "s79-start", nil)
	if err != nil {
		t.Fatalf("CreateStep cdc_start: %v", err)
	}
	result, err = exec(ctx, startStep, map[string]any{
		"source_id": sourceID,
		"tables":    []any{"tenant_acme.users", "tenant_acme.orders"},
	})
	if err != nil {
		t.Fatalf("cdc_start: %v", err)
	}
	if result.Output["action"] == nil && result.Output["source_id"] == nil {
		t.Errorf("cdc_start: expected non-empty output, got %v", result.Output)
	}

	// ── step.cdc_status ──
	statusStep, err := p.CreateStep("step.cdc_status", "s79-status", nil)
	if err != nil {
		t.Fatalf("CreateStep cdc_status: %v", err)
	}
	result, err = exec(ctx, statusStep, map[string]any{"source_id": sourceID})
	if err != nil {
		t.Fatalf("cdc_status: %v", err)
	}
	if result.Output["state"] != "running" {
		t.Errorf("cdc_status: expected state=running, got %v", result.Output["state"])
	}

	// ── step.cdc_snapshot ──
	snapStep, err := p.CreateStep("step.cdc_snapshot", "s79-snap", nil)
	if err != nil {
		t.Fatalf("CreateStep cdc_snapshot: %v", err)
	}
	result, err = exec(ctx, snapStep, map[string]any{
		"source_id": sourceID,
		"tables":    []any{"tenant_acme.users", "tenant_acme.orders", "tenant_acme.products"},
	})
	if err != nil {
		t.Fatalf("cdc_snapshot: %v", err)
	}
	if result.Output["action"] != "snapshot_triggered" {
		t.Errorf("cdc_snapshot: expected action=snapshot_triggered, got %v", result.Output["action"])
	}

	// Seed a schema version so cdc_schema_history returns data.
	if mp, ok := testhelpers.CDCLookupMemoryProvider(sourceID); ok {
		_ = mp.AddSchemaVersion(sourceID, testhelpers.CDCSchemaVersion{
			Table:     "tenant_acme.users",
			Version:   1,
			DDL:       "ALTER TABLE users ADD COLUMN email TEXT",
			AppliedAt: "2026-03-28T00:00:00Z",
		})
	}

	// ── step.cdc_schema_history ──
	histStep, err := p.CreateStep("step.cdc_schema_history", "s79-hist", nil)
	if err != nil {
		t.Fatalf("CreateStep cdc_schema_history: %v", err)
	}
	result, err = exec(ctx, histStep, map[string]any{
		"source_id": sourceID,
		"table":     "tenant_acme.users",
	})
	if err != nil {
		t.Fatalf("cdc_schema_history: %v", err)
	}
	if result.Output["count"] == nil {
		t.Errorf("cdc_schema_history: expected count in output, got %v", result.Output)
	}

	// ── step.cdc_stop ──
	stopStep, err := p.CreateStep("step.cdc_stop", "s79-stop", nil)
	if err != nil {
		t.Fatalf("CreateStep cdc_stop: %v", err)
	}
	result, err = exec(ctx, stopStep, map[string]any{"source_id": sourceID})
	if err != nil {
		t.Fatalf("cdc_stop: %v", err)
	}
	if result.Output["action"] != "stopped" {
		t.Errorf("cdc_stop: expected action=stopped, got %v", result.Output["action"])
	}
}

// ─── Scenario 80 — Lakehouse Pipeline ────────────────────────────────────────
//
// Mirrors: scenarios/80-data-lakehouse-pipeline/config/app.yaml
// Modules: catalog.iceberg (mocked REST) + quality.checks

func TestScenario80_LakehousePipeline(t *testing.T) {
	p := newDEPlugin(t)
	ctx := context.Background()

	// ── Mock Iceberg REST Catalog server ──
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/config", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, 200, map[string]any{"defaults": map[string]string{}, "overrides": map[string]string{}})
	})
	// HEAD — table existence check (not found initially so create proceeds)
	mux.HandleFunc("HEAD /v1/namespaces/{ns}/tables/{tbl}", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(404)
	})
	// POST namespace/tables — create table
	mux.HandleFunc("POST /v1/namespaces/{ns}/tables", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, 200, map[string]any{
			"metadata": map[string]any{
				"format-version":    2,
				"table-uuid":        "s80-table-uuid",
				"location":          "s3://data-warehouse/iceberg/analytics/events",
				"current-schema-id": 0,
				"schemas":           []any{},
				"properties":        map[string]string{},
			},
		})
	})
	// POST namespace/tables/tbl — update (evolve schema / compact / expire)
	mux.HandleFunc("POST /v1/namespaces/{ns}/tables/{tbl}", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, 200, map[string]any{
			"metadata": map[string]any{
				"format-version":    2,
				"table-uuid":        "s80-table-uuid",
				"location":          "s3://data-warehouse/iceberg/analytics/events",
				"current-schema-id": 1,
				"schemas":           []any{},
				"properties":        map[string]string{},
			},
		})
	})
	// GET namespace/tables/tbl — query / snapshot list
	mux.HandleFunc("GET /v1/namespaces/{ns}/tables/{tbl}", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, 200, map[string]any{
			"metadata": map[string]any{
				"format-version":      2,
				"table-uuid":          "s80-table-uuid",
				"location":            "s3://data-warehouse/iceberg/analytics/events",
				"current-schema-id":   0,
				"current-snapshot-id": int64(101),
				"schemas":             []any{},
				"snapshots": []any{
					map[string]any{
						"snapshot-id":   int64(101),
						"timestamp-ms":  int64(1700000000000),
						"manifest-list": "s3://data-warehouse/iceberg/manifests",
						"summary":       map[string]string{"operation": "append"},
					},
				},
				"properties": map[string]string{},
			},
		})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	catName := "s80-iceberg-catalog"
	testhelpers.LakehouseUnregisterCatalog(catName)
	t.Cleanup(func() { testhelpers.LakehouseUnregisterCatalog(catName) })

	// ── Module: catalog.iceberg ──
	catMod, err := p.CreateModule("catalog.iceberg", catName, map[string]any{
		"endpoint":   srv.URL + "/v1",
		"credential": "test-token",
	})
	if err != nil {
		t.Fatalf("CreateModule catalog.iceberg: %v", err)
	}
	if err := catMod.Init(); err != nil {
		t.Fatalf("catMod.Init: %v", err)
	}
	if err := catMod.Start(ctx); err != nil {
		t.Fatalf("catMod.Start: %v", err)
	}
	t.Cleanup(func() { _ = catMod.Stop(ctx) })

	// ── Module: quality.checks (with sqlmock executor for DB-backed checks) ──
	qualDB, qualMockDB, err := sqlmock.New()
	if err != nil {
		t.Fatalf("sqlmock.New: %v", err)
	}
	t.Cleanup(func() { qualDB.Close() })
	// Expect COUNT(*) for not_null check on column "id"
	qualMockDB.ExpectQuery("SELECT COUNT").WillReturnRows(sqlmock.NewRows([]string{"count"}).AddRow(0))
	// Expect COUNT(*) for row_count check
	qualMockDB.ExpectQuery("SELECT COUNT").WillReturnRows(sqlmock.NewRows([]string{"count"}).AddRow(5))

	if err := testhelpers.QualityNewModuleWithExecutor("s80-quality", qualDB); err != nil {
		t.Fatalf("QualityNewModuleWithExecutor: %v", err)
	}
	t.Cleanup(func() { testhelpers.QualityUnregisterChecksModule("s80-quality") })

	// ── step.lakehouse_create_table ──
	createStep, err := p.CreateStep("step.lakehouse_create_table", "s80-create", nil)
	if err != nil {
		t.Fatalf("CreateStep lakehouse_create_table: %v", err)
	}
	result, err := exec(ctx, createStep, map[string]any{
		"catalog":   catName,
		"namespace": []any{"analytics"},
		"table":     "events",
		"schema": map[string]any{
			"fields": []any{
				map[string]any{"name": "id", "type": "long", "required": true},
				map[string]any{"name": "event_time", "type": "timestamp", "required": true},
				map[string]any{"name": "event_type", "type": "string", "required": false},
			},
		},
	})
	if err != nil {
		t.Fatalf("lakehouse_create_table: %v", err)
	}
	if result.Output["status"] != "created" {
		t.Errorf("lakehouse_create_table: expected status=created, got %v", result.Output["status"])
	}

	// ── step.lakehouse_evolve_schema (add column) ──
	evolveStep, err := p.CreateStep("step.lakehouse_evolve_schema", "s80-evolve", nil)
	if err != nil {
		t.Fatalf("CreateStep lakehouse_evolve_schema: %v", err)
	}
	result, err = exec(ctx, evolveStep, map[string]any{
		"catalog":   catName,
		"namespace": []any{"analytics"},
		"table":     "events",
		"changes":   []any{map[string]any{"action": "add-column", "name": "user_id", "type": "long"}},
	})
	if err != nil {
		t.Fatalf("lakehouse_evolve_schema: %v", err)
	}
	if result.Output["status"] != "evolved" {
		t.Errorf("lakehouse_evolve_schema: expected status=evolved, got %v", result.Output["status"])
	}

	// ── step.lakehouse_write ──
	writeStep, err := p.CreateStep("step.lakehouse_write", "s80-write", nil)
	if err != nil {
		t.Fatalf("CreateStep lakehouse_write: %v", err)
	}
	result, err = exec(ctx, writeStep, map[string]any{
		"catalog":   catName,
		"namespace": []any{"analytics"},
		"table":     "events",
		"records":   []any{map[string]any{"id": 1, "event_type": "click"}},
		"writeMode": "append",
	})
	if err != nil {
		t.Fatalf("lakehouse_write: %v", err)
	}
	if result.Output["status"] == nil {
		t.Errorf("lakehouse_write: expected status in output, got %v", result.Output)
	}

	// ── step.lakehouse_query (snapshots) ──
	queryStep, err := p.CreateStep("step.lakehouse_query", "s80-query", nil)
	if err != nil {
		t.Fatalf("CreateStep lakehouse_query: %v", err)
	}
	result, err = exec(ctx, queryStep, map[string]any{
		"catalog":   catName,
		"namespace": []any{"analytics"},
		"table":     "events",
	})
	if err != nil {
		t.Fatalf("lakehouse_query: %v", err)
	}
	if result.Output["snapshots"] == nil {
		t.Errorf("lakehouse_query: expected snapshots in output, got %v", result.Output)
	}

	// ── step.lakehouse_compact ──
	compactStep, err := p.CreateStep("step.lakehouse_compact", "s80-compact", nil)
	if err != nil {
		t.Fatalf("CreateStep lakehouse_compact: %v", err)
	}
	result, err = exec(ctx, compactStep, map[string]any{
		"catalog":   catName,
		"namespace": []any{"analytics"},
		"table":     "events",
	})
	if err != nil {
		t.Fatalf("lakehouse_compact: %v", err)
	}
	if result.Output["status"] == nil {
		t.Errorf("lakehouse_compact: expected status in output, got %v", result.Output)
	}

	// ── step.lakehouse_expire_snapshots ──
	expireStep, err := p.CreateStep("step.lakehouse_expire_snapshots", "s80-expire", nil)
	if err != nil {
		t.Fatalf("CreateStep lakehouse_expire_snapshots: %v", err)
	}
	result, err = exec(ctx, expireStep, map[string]any{
		"catalog":       catName,
		"namespace":     []any{"analytics"},
		"table":         "events",
		"olderThanDays": 7,
		"retainLast":    5,
	})
	if err != nil {
		t.Fatalf("lakehouse_expire_snapshots: %v", err)
	}
	if result.Output["status"] == nil {
		t.Errorf("lakehouse_expire_snapshots: expected status in output, got %v", result.Output)
	}

	// ── step.quality_check (not_null + row_count, mirrors scenario config) ──
	qcStep, err := p.CreateStep("step.quality_check", "s80-qc", nil)
	if err != nil {
		t.Fatalf("CreateStep quality_check: %v", err)
	}
	result, err = exec(ctx, qcStep, map[string]any{
		"module": "s80-quality",
		"table":  "events",
		"checks": []any{
			map[string]any{"type": "not_null", "columns": []any{"id"}},
			map[string]any{"type": "row_count", "minRows": 0},
		},
	})
	if err != nil {
		t.Fatalf("quality_check: %v", err)
	}
	if result.Output["passed"] == nil {
		t.Errorf("quality_check: expected passed in output, got %v", result.Output)
	}
}

// ─── Scenario 81 — Time-Series Analytics ─────────────────────────────────────
//
// Mirrors: scenarios/81-data-timeseries-analytics/config/app.yaml
// Modules: timeseries.influxdb (mocked) + timeseries.druid (mocked)

func TestScenario81_TimeSeriesAnalytics(t *testing.T) {
	p := newDEPlugin(t)
	ctx := context.Background()

	// ── Mock InfluxDB v2 server ──
	// Uses annotated CSV format required by the influxdb-client-go library.
	const csvResp = "#datatype,string,long,dateTime:RFC3339,dateTime:RFC3339,dateTime:RFC3339,double,string,string\r\n" +
		"#group,false,false,true,true,false,false,true,true\r\n" +
		"#default,_result,,,,,,,\r\n" +
		",result,table,_start,_stop,_time,_value,_field,_measurement\r\n" +
		",_result,0,2021-01-01T00:00:00Z,2021-01-02T00:00:00Z,2021-01-01T12:00:00Z,42.0,latency,request_latency\r\n\r\n"

	influxMux := http.NewServeMux()
	influxMux.HandleFunc("/ping", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(204) })
	influxMux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"name":"influxdb","status":"pass","version":"2.7.0"}`))
	})
	influxMux.HandleFunc("/api/v2/write", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(204) })
	influxMux.HandleFunc("/api/v2/query", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/csv; charset=utf-8")
		_, _ = io.WriteString(w, csvResp)
	})
	influxMux.HandleFunc("/api/v2/buckets", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, 200, map[string]any{
			"buckets": []map[string]any{{"id": "bkt1", "name": "metrics", "retentionRules": []any{}}},
		})
	})
	influxSrv := httptest.NewServer(influxMux)
	t.Cleanup(influxSrv.Close)

	influxName := "s81-influx"
	testhelpers.TSUnregister(influxName)
	t.Cleanup(func() { testhelpers.TSUnregister(influxName) })

	// ── Module: timeseries.influxdb ──
	influxMod, err := p.CreateModule("timeseries.influxdb", influxName, map[string]any{
		"url":    influxSrv.URL,
		"token":  "test-token",
		"org":    "myorg",
		"bucket": "metrics",
	})
	if err != nil {
		t.Fatalf("CreateModule timeseries.influxdb: %v", err)
	}
	if err := influxMod.Init(); err != nil {
		t.Fatalf("influxMod.Init: %v", err)
	}
	if err := influxMod.Start(ctx); err != nil {
		t.Fatalf("influxMod.Start: %v", err)
	}
	t.Cleanup(func() { _ = influxMod.Stop(ctx) })

	// ── Mock Druid Router server ──
	druidMux := http.NewServeMux()
	druidMux.HandleFunc("/status", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, 200, map[string]any{"version": "30.0.0", "loading": false})
	})
	druidMux.HandleFunc("/druid/indexer/v1/supervisor", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, 200, map[string]any{"id": "s81-supervisor", "state": "RUNNING"})
	})
	druidMux.HandleFunc("/druid/v2/sql", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, 200, []map[string]any{
			{"__time": "2026-03-28T00:00:00Z", "count": float64(100)},
		})
	})
	druidSrv := httptest.NewServer(druidMux)
	t.Cleanup(druidSrv.Close)

	druidName := "s81-druid"
	testhelpers.TSUnregister(druidName)
	t.Cleanup(func() { testhelpers.TSUnregister(druidName) })

	// ── Module: timeseries.druid ──
	druidMod, err := p.CreateModule("timeseries.druid", druidName, map[string]any{
		"routerUrl": druidSrv.URL,
	})
	if err != nil {
		t.Fatalf("CreateModule timeseries.druid: %v", err)
	}
	if err := druidMod.Init(); err != nil {
		t.Fatalf("druidMod.Init: %v", err)
	}
	if err := druidMod.Start(ctx); err != nil {
		t.Fatalf("druidMod.Start: %v", err)
	}
	t.Cleanup(func() { _ = druidMod.Stop(ctx) })

	// ── step.ts_write (single point, mirrors ingest_metrics pipeline) ──
	writeStep, err := p.CreateStep("step.ts_write", "s81-write", nil)
	if err != nil {
		t.Fatalf("CreateStep ts_write: %v", err)
	}
	result, err := exec(ctx, writeStep, map[string]any{
		"module":      influxName,
		"measurement": "request_latency",
		"fields":      map[string]any{"value": 42.0},
		"tags":        map[string]any{"service": "api-gateway"},
	})
	if err != nil {
		t.Fatalf("ts_write: %v", err)
	}
	if result.Output["status"] != "written" {
		t.Errorf("ts_write: expected status=written, got %v", result.Output["status"])
	}

	// ── step.ts_write_batch (multiple points) ──
	writeBatchStep, err := p.CreateStep("step.ts_write_batch", "s81-batch", nil)
	if err != nil {
		t.Fatalf("CreateStep ts_write_batch: %v", err)
	}
	result, err = exec(ctx, writeBatchStep, map[string]any{
		"module": influxName,
		"points": []any{
			map[string]any{
				"measurement": "cpu_usage",
				"fields":      map[string]any{"value": 55.3},
				"tags":        map[string]any{"host": "server1"},
			},
			map[string]any{
				"measurement": "memory_usage",
				"fields":      map[string]any{"value": 72.1},
				"tags":        map[string]any{"host": "server1"},
			},
		},
	})
	if err != nil {
		t.Fatalf("ts_write_batch: %v", err)
	}
	if result.Output["count"] == nil && result.Output["status"] == nil {
		t.Errorf("ts_write_batch: expected count or status in output, got %v", result.Output)
	}

	// ── step.ts_query (Flux query, mirrors anomaly_scan pipeline) ──
	queryStep, err := p.CreateStep("step.ts_query", "s81-query", nil)
	if err != nil {
		t.Fatalf("CreateStep ts_query: %v", err)
	}
	result, err = exec(ctx, queryStep, map[string]any{
		"module": influxName,
		"query":  `from(bucket: "metrics") |> range(start: -30m) |> filter(fn: (r) => r._measurement == "request_latency") |> mean()`,
	})
	if err != nil {
		t.Fatalf("ts_query: %v", err)
	}
	if result.Output == nil {
		t.Error("ts_query: expected non-nil output")
	}

	// ── step.ts_downsample (mirrors downsample_hourly pipeline) ──
	downsampleStep, err := p.CreateStep("step.ts_downsample", "s81-downsample", nil)
	if err != nil {
		t.Fatalf("CreateStep ts_downsample: %v", err)
	}
	result, err = exec(ctx, downsampleStep, map[string]any{
		"module":      influxName,
		"source":      "request_latency",
		"target":      "request_latency_1h",
		"aggregation": "mean",
		"interval":    "1h",
	})
	if err != nil {
		t.Fatalf("ts_downsample: %v", err)
	}
	if result.Output == nil {
		t.Error("ts_downsample: expected non-nil output")
	}

	// ── step.ts_druid_ingest (Kafka supervisor spec, mirrors druid_ingest pipeline) ──
	ingestStep, err := p.CreateStep("step.ts_druid_ingest", "s81-druid-ingest", nil)
	if err != nil {
		t.Fatalf("CreateStep ts_druid_ingest: %v", err)
	}
	result, err = exec(ctx, ingestStep, map[string]any{
		"module": druidName,
		"spec": map[string]any{
			"type": "kafka",
			"dataSchema": map[string]any{
				"dataSource": "metrics",
				"timestampSpec": map[string]any{
					"column": "event_time",
					"format": "iso",
				},
				"dimensionsSpec": map[string]any{
					"dimensions": []any{"service", "host"},
				},
				"granularitySpec": map[string]any{
					"segmentGranularity": "HOUR",
					"queryGranularity":   "MINUTE",
				},
			},
			"ioConfig": map[string]any{
				"topic": "metrics",
				"consumerProperties": map[string]any{
					"bootstrap.servers": "kafka-1.internal:9092",
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("ts_druid_ingest: %v", err)
	}
	if result.Output["supervisorId"] == nil {
		t.Errorf("ts_druid_ingest: expected supervisorId in output, got %v", result.Output)
	}

	// ── step.ts_druid_query (SQL, mirrors druid query in scenario) ──
	druidQueryStep, err := p.CreateStep("step.ts_druid_query", "s81-druid-query", nil)
	if err != nil {
		t.Fatalf("CreateStep ts_druid_query: %v", err)
	}
	result, err = exec(ctx, druidQueryStep, map[string]any{
		"module": druidName,
		"query":  "SELECT COUNT(*) AS count FROM metrics WHERE __time >= CURRENT_TIMESTAMP - INTERVAL '1' HOUR",
	})
	if err != nil {
		t.Fatalf("ts_druid_query: %v", err)
	}
	rows, _ := result.Output["rows"].([]map[string]any)
	if len(rows) == 0 {
		t.Errorf("ts_druid_query: expected rows in output, got %v", result.Output)
	}
}

// ─── Scenario 82 — Graph + Catalog ───────────────────────────────────────────
//
// Mirrors: scenarios/82-data-graph-catalog/config/app.yaml
// Modules: graph.neo4j (mocked driver) + catalog.datahub (mocked HTTP)
//          + migrate.schema (declarative strategy)

func TestScenario82_GraphCatalog(t *testing.T) {
	p := newDEPlugin(t)
	ctx := context.Background()

	// ── Register mock Neo4j module ──
	neo4jName := "s82-neo4j"
	testhelpers.UnregisterNeo4jModule(neo4jName)
	neo4jMod := testhelpers.NewNeo4jModuleForTest(neo4jName, &s82MockNeo4jDriver{})
	if err := testhelpers.RegisterNeo4jModule(neo4jName, neo4jMod); err != nil {
		t.Fatalf("RegisterNeo4jModule: %v", err)
	}
	t.Cleanup(func() { testhelpers.UnregisterNeo4jModule(neo4jName) })

	// ── Mock DataHub GMS server ──
	datahubMux := http.NewServeMux()
	// catalog_register calls /aspects (DataHub GMS REST API)
	datahubMux.HandleFunc("/aspects", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(200)
	})
	// catalog_search calls /entities/v1/search
	datahubMux.HandleFunc("/entities/v1/search", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, 200, map[string]any{
			"numEntities": 1,
			"entities": []any{
				map[string]any{"urn": "urn:li:dataset:cdc-events", "name": "cdc-events", "platform": "kafka"},
			},
		})
	})
	// Catch-all for /entities path
	datahubMux.HandleFunc("/entities", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(200)
	})
	datahubSrv := httptest.NewServer(datahubMux)
	t.Cleanup(datahubSrv.Close)

	datahubName := "s82-datahub"
	testhelpers.CatalogUnregisterModule(datahubName)
	t.Cleanup(func() { testhelpers.CatalogUnregisterModule(datahubName) })

	// ── Module: catalog.datahub ──
	dhMod, err := p.CreateModule("catalog.datahub", datahubName, map[string]any{
		"endpoint": datahubSrv.URL,
	})
	if err != nil {
		t.Fatalf("CreateModule catalog.datahub: %v", err)
	}
	if err := dhMod.Init(); err != nil {
		t.Fatalf("dhMod.Init: %v", err)
	}
	if err := dhMod.Start(ctx); err != nil {
		t.Fatalf("dhMod.Start: %v", err)
	}
	t.Cleanup(func() { _ = dhMod.Stop(ctx) })

	// ── Module: migrate.schema (declarative strategy) ──
	migName := "s82-migrator"
	migMod, err := p.CreateModule("migrate.schema", migName, map[string]any{
		"strategy": "declarative",
	})
	if err != nil {
		t.Fatalf("CreateModule migrate.schema: %v", err)
	}
	if err := migMod.Init(); err != nil {
		t.Fatalf("migMod.Init: %v", err)
	}
	if err := migMod.Start(ctx); err != nil {
		t.Fatalf("migMod.Start: %v", err)
	}
	t.Cleanup(func() {
		_ = migMod.Stop(ctx)
		testhelpers.MigrateUnregisterModule(migName)
	})

	// ── step.graph_extract_entities (mirrors build_knowledge_graph pipeline) ──
	extractStep, err := p.CreateStep("step.graph_extract_entities", "s82-extract", nil)
	if err != nil {
		t.Fatalf("CreateStep graph_extract_entities: %v", err)
	}
	result, err := exec(ctx, extractStep, map[string]any{
		"text":  "Alice Smith works at Acme Corp in New York. Contact: alice@acme.com. Bob Jones is CEO of GlobalTech.",
		"types": []any{"person", "org", "location", "email"},
	})
	if err != nil {
		t.Fatalf("graph_extract_entities: %v", err)
	}
	count, _ := result.Output["count"].(int)
	if count == 0 {
		t.Error("graph_extract_entities: expected at least one entity extracted")
	}

	// ── step.graph_write (write nodes using mock driver) ──
	writeStep, err := p.CreateStep("step.graph_write", "s82-write", nil)
	if err != nil {
		t.Fatalf("CreateStep graph_write: %v", err)
	}
	result, err = exec(ctx, writeStep, map[string]any{
		"module": neo4jName,
		"nodes": []any{
			map[string]any{"label": "Person", "properties": map[string]any{"name": "Alice Smith"}},
			map[string]any{"label": "Organization", "properties": map[string]any{"name": "Acme Corp"}},
		},
	})
	if err != nil {
		t.Fatalf("graph_write: %v", err)
	}
	if result.Output == nil {
		t.Error("graph_write: expected non-nil output")
	}

	// ── step.graph_link (link Person → Organization) ──
	linkStep, err := p.CreateStep("step.graph_link", "s82-link", nil)
	if err != nil {
		t.Fatalf("CreateStep graph_link: %v", err)
	}
	result, err = exec(ctx, linkStep, map[string]any{
		"module": neo4jName,
		"from":   map[string]any{"label": "Person", "key": "Alice Smith"},
		"to":     map[string]any{"label": "Organization", "key": "Acme Corp"},
		"type":   "WORKS_FOR",
	})
	if err != nil {
		t.Fatalf("graph_link: %v", err)
	}
	if result.Output == nil {
		t.Error("graph_link: expected non-nil output")
	}

	// ── step.catalog_register (register dataset in DataHub) ──
	regStep, err := p.CreateStep("step.catalog_register", "s82-register", nil)
	if err != nil {
		t.Fatalf("CreateStep catalog_register: %v", err)
	}
	result, err = exec(ctx, regStep, map[string]any{
		"catalog": datahubName,
		"dataset": "cdc-events",
		"owner":   "data-team",
		"tags":    []any{"cdc", "kafka", "realtime"},
	})
	if err != nil {
		t.Fatalf("catalog_register: %v", err)
	}
	if result.Output["status"] != "registered" {
		t.Errorf("catalog_register: expected status=registered, got %v", result.Output["status"])
	}

	// ── step.catalog_search (search DataHub, mirrors catalog_register_dataset) ──
	searchStep, err := p.CreateStep("step.catalog_search", "s82-search", nil)
	if err != nil {
		t.Fatalf("CreateStep catalog_search: %v", err)
	}
	result, err = exec(ctx, searchStep, map[string]any{
		"catalog": datahubName,
		"query":   "cdc-events",
		"limit":   5,
	})
	if err != nil {
		t.Fatalf("catalog_search: %v", err)
	}
	if result.Output["results"] == nil && result.Output["total"] == nil {
		t.Errorf("catalog_search: expected results or total in output, got %v", result.Output)
	}

	// ── step.migrate_plan (mirrors schema_migration pipeline) ──
	planStep, err := p.CreateStep("step.migrate_plan", "s82-plan", nil)
	if err != nil {
		t.Fatalf("CreateStep migrate_plan: %v", err)
	}
	result, err = exec(ctx, planStep, map[string]any{
		"module": migName,
	})
	if err != nil {
		t.Fatalf("migrate_plan: %v", err)
	}
	if result.Output == nil {
		t.Error("migrate_plan: expected non-nil output")
	}
}

// ─── Mock Neo4j driver for scenario 82 ───────────────────────────────────────

type s82MockNeo4jDriver struct{}

func (d *s82MockNeo4jDriver) NewSession(_ context.Context, _ testhelpers.Neo4jSessionConfig) testhelpers.GraphSession {
	return &s82MockSession{}
}
func (d *s82MockNeo4jDriver) VerifyConnectivity(_ context.Context) error { return nil }
func (d *s82MockNeo4jDriver) Close(_ context.Context) error              { return nil }

type s82MockSession struct{}

func (s *s82MockSession) Run(_ context.Context, _ string, _ map[string]any) (testhelpers.GraphResult, error) {
	return &s82MockResult{}, nil
}
func (s *s82MockSession) Close(_ context.Context) error { return nil }

type s82MockResult struct{}

func (r *s82MockResult) Next(_ context.Context) bool              { return false }
func (r *s82MockResult) Record() *testhelpers.Neo4jRecord         { return nil }
func (r *s82MockResult) Err() error                               { return nil }
