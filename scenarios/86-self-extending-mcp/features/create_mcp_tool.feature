Feature: Agent creates a new MCP tool as a workflow pipeline
  As an AI agent with MCP creation permissions
  I want to create new MCP-exposed tools as workflow pipelines
  So that the application's capabilities grow dynamically

  Scenario: Agent inspects current config before proposing a tool
    Given a running workflow application with base task API
    And an AI agent with mcp:wfctl:* and mcp:self_improve:* permissions
    When the agent calls mcp:wfctl:inspect_config
    Then the agent receives a structured config summary
    And the summary lists the db and server modules
    And the summary lists the task CRUD pipelines

  Scenario: Agent designs task_analytics with mcp_tool trigger
    Given a running workflow application with base task API
    And an AI agent with tool creation permissions
    When the agent designs a new pipeline named "task_analytics"
    Then the pipeline has trigger type "mcp_tool"
    And the pipeline steps query the tasks table for completion metrics
    And the proposal includes fields: completion_rate, avg_time_to_completion, bottleneck_status

  Scenario: Agent validates the proposed mcp_tool pipeline
    Given an agent with a task_analytics pipeline proposal
    When the agent calls mcp:wfctl:validate_config on the updated config
    Then the validation returns zero errors
    And the trigger type "mcp_tool" is recognized as valid
    And all referenced step types exist

  Scenario: Agent deploys task_analytics via hot reload
    Given a validated task_analytics pipeline proposal
    When the agent deploys the updated config
    Then the workflow application hot-reloads without restart
    And the mcp_tool "task_analytics" is now registered in the MCP server
    And calling mcp:app:task_analytics returns a valid response
