package main

import (
	"github.com/GoCodeAlone/workflow/plugin/external/sdk"
	"github.com/GoCodeAlone/workflow-scenarios/samples/orders"
)

func main() {
	sdk.Serve(orders.NewPlugin())
}
