// Command stub-iac-provider is a scenario-92 fixture that serves the typed
// IaC gRPC contract (IaCProviderRequired + IaCProviderRegionLister +
// IaCProviderDriftDetector) with deterministic, credential-free data.
//
// It is compiled separately from the scenario server and loaded as an external
// plugin via the workflow engine's external plugin manager. The plugin.json
// sibling file tells the engine which gRPC services this binary advertises.
//
// Per ADR-0010: test fixtures live in the scenario repo, NOT in the workflow
// engine binary. This binary is never shipped to production.
//
// Usage (the engine invokes it automatically via go-plugin):
//
//	./stub-iac-provider
package main

import (
	_ "embed"

	sdk "github.com/GoCodeAlone/workflow/plugin/external/sdk"

	"github.com/GoCodeAlone/workflow-scenarios/scenarios/92-infra-admin-demo/fixtures/stub-iac-provider/internal"
)

//go:embed plugin.json
var pluginJSON []byte

func main() {
	sdk.ServeIaCPlugin(&internal.StubIaCServer{}, sdk.IaCServeOptions{
		ManifestProvider: sdk.MustEmbedManifest(pluginJSON),
	})
}
