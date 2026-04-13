Feature: Agent iterates to create additional MCP tools
  As an AI agent
  I want to chain tool creation across iterations
  So that each new tool builds on insights from the previous one

  Scenario: Agent creates task_forecast after analyzing task_analytics
    Given task_analytics is deployed and the agent has analyzed results
    When the agent designs the task_forecast pipeline
    Then the pipeline has trigger type "mcp_tool"
    And the pipeline queries daily task creation counts for the last 30 days
    And the pipeline computes a 7-day moving average
    And the pipeline projects task completion trends for the next 7 days

  Scenario: Agent validates task_forecast config
    Given a task_forecast pipeline proposal
    When the agent calls mcp:wfctl:validate_config
    Then the validation passes with zero errors
    And both task_analytics and task_forecast coexist in the same config

  Scenario: Agent deploys task_forecast and verifies registration
    Given a validated task_forecast proposal
    When the agent deploys the updated config
    Then both mcp_tool triggers are registered in the MCP server
    And calling mcp:app:task_forecast returns a forecast array
    And each forecast entry has a date and projected_count field

  Scenario: Blackboard contains artifacts from both iterations
    Given the agent has completed both tool creation iterations
    When we inspect the blackboard
    Then there is an artifact of type "mcp_tool_proposal" from phase "design"
    And there is an artifact of type "second_tool_proposal" from phase "iterate"
    And both artifacts contain valid YAML config fragments

  Scenario: Git history shows tool creation progression
    Given the agent has deployed both tools
    When we check the git log in /data/repo
    Then there are at least 2 commits
    And the first commit message references "task_analytics"
    And the second commit message references "task_forecast"
