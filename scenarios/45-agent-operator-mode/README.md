# Scenario 45: Agent Operator Mode

Manual QA scenario for testing the workflow-plugin-agent with a live Claude operator.

## Overview

This scenario uses the `test` provider in `http` mode. Instead of scripted or mock
responses, every agent turn is forwarded to an external HTTP endpoint. This lets you
run a Claude agent process outside the workflow server that responds to each LLM call
in real-time — functioning as the "operator" driving the agent loop.

## Prerequisites

1. Build a custom `workflow-server:agent-local` image with `workflow-plugin-agent` registered.
2. A Claude agent process (or any HTTP server) listening at `http://localhost:9090/respond`.
3. minikube with kubectl configured.

## Setup

### 1. Build the custom server image

In the `workflow` repo, add the agent plugin to the server binary:

```go
// cmd/server/main.go — in defaultEnginePlugins()
import agent "github.com/GoCodeAlone/workflow-plugin-agent"

// ...
agent.New(),
```

Then build and load:

```bash
cd /path/to/workflow
go build -o workflow-server ./cmd/server
docker build -t workflow-server:agent-local -f deploy/Dockerfile .
minikube image load workflow-server:agent-local
```

### 2. Start the operator HTTP server

The operator receives POST requests with an `Interaction` JSON body:

```json
{
  "id": "uuid",
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "Task for agent ..."},
    {"role": "tool", "content": "...", "tool_call_id": "..."}
  ],
  "tools": [
    {"name": "k8s_get_pods", "description": "...", "parameters": {...}}
  ],
  "created_at": "2026-03-04T..."
}
```

It must respond with an `InteractionResponse` JSON body:

```json
{
  "content": "I'll check the pods now.",
  "tool_calls": [
    {
      "id": "call-1",
      "name": "k8s_get_pods",
      "arguments": {"namespace": "production"}
    }
  ]
}
```

A minimal Go operator server is available in the `workflow-plugin-agent` repo at
`provider/test_provider_http.go` — see `HTTPSource` and `NewHTTPSource`.

### 3. Deploy the scenario

```bash
cd /path/to/workflow-scenarios
make deploy SCENARIO=45-agent-operator-mode
```

### 4. Port-forward and trigger

```bash
kubectl port-forward -n wf-scenario-45 svc/workflow-server 18045:8080 &

curl -X POST http://localhost:18045/api/v1/agent/operate \
  -H "Content-Type: application/json" \
  -d '{
    "task": "Check the health of all pods in the production namespace and restart any that are CrashLoopBackOff.",
    "agent_id": "operator-agent",
    "system_prompt": "You are an expert infrastructure operator. Use the available tools safely."
  }'
```

### 5. Observe the conversation

Watch the agent loop call your operator HTTP server, receive tool calls, execute them
(or return mock results), and iterate until the task is complete.

## Protocol Reference

The HTTP source endpoint receives:
- `POST /respond` — `Interaction` body, returns `InteractionResponse`

See `provider/test_provider_http.go` in `workflow-plugin-agent` for the full Go types.

## Notes

- Set `max_iterations: 20` in `app.yaml` for complex tasks.
- The `timeout: 5m` provider config allows up to 5 minutes per turn.
- No automated tests exist for this scenario. It is purely for exploratory QA.
- To exit the loop early, return an `InteractionResponse` with no `tool_calls` and
  a final content message.
