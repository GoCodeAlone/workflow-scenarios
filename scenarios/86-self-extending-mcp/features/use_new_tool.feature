Feature: Agent uses the newly created MCP tool
  As an AI agent
  I want to call the tools I created
  So that I can act on real data and make informed decisions

  Scenario: Agent calls task_analytics and receives completion metrics
    Given task_analytics has been deployed as an MCP tool
    And the database contains 52 seeded task records
    When the agent calls mcp:app:task_analytics
    Then the response includes "completion_rate"
    And completion_rate is approximately 40 percent (21 of 52 tasks done)
    And the response includes "avg_time_to_completion" in hours
    And the response includes "bottleneck_status" identifying "blocked"

  Scenario: Agent interprets analytics results
    Given the agent has called task_analytics
    And the results show 8 tasks in "blocked" status
    When the agent analyzes the bottleneck
    Then the agent identifies "blocked" as the bottleneck status
    And the agent logs a finding to the blackboard

  Scenario: Agent uses analytics to inform next tool design
    Given the agent has analyzed task_analytics results
    When the agent designs the task_forecast tool
    Then the forecast is based on the 7-day moving average of task creation
    And the forecast pipeline includes a step.db_query for daily task counts
    And the proposal covers the next 7 days

  Scenario: Agent verifies tool response schema
    Given task_analytics is deployed
    When the agent calls the tool
    Then the response is valid JSON
    And completion_rate is a number between 0 and 100
    And avg_time_to_completion is a non-negative number
    And bottleneck_status is a non-empty string
