// Command dns-stub-plugin is a file-backed in-memory IaCProvider plugin
// used by workflow-scenarios 89/91/93 to drive DNS orchestration tests
// without provider credentials.
//
// State lives on disk (JSON) so it survives across the multiple
// wfctl-spawned plugin processes a single scenario run produces. Each
// stub instance gets its own state path so multi-provider scenarios
// (e.g. delegation) can route to separate stores.
//
// Per docs/plans/2026-05-26-dns-provider-contract.md PR 9 (Task 30).
package main

import (
	sdk "github.com/GoCodeAlone/workflow/plugin/external/sdk"
)

func main() {
	sdk.ServeIaCPlugin(NewIaCServer(), sdk.IaCServeOptions{
		BuildVersion: Version,
	})
}
