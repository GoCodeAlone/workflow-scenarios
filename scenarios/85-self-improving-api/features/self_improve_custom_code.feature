Feature: Self-improving with custom Yaegi code
  As an AI agent
  I want to write and deploy custom Yaegi modules
  So that the application can have functionality beyond built-in steps

  Scenario: Agent writes a custom FTS5 search ranking module
    Given a running workflow application with SQLite FTS5 enabled
    And an AI agent tasked with improving search relevance
    When the agent writes a custom Yaegi module for BM25 ranking
    And the agent registers the module in the workflow config
    Then the workflow engine loads the custom module successfully

  Scenario: Agent validates Yaegi module syntax before deployment
    Given an AI agent that has written a custom Yaegi module
    When the agent calls mcp:lsp:diagnose on the module source
    Then the agent receives Go syntax diagnostics
    And the module has no compilation errors

  Scenario: Agent deploys custom module and verifies integration
    Given a custom Yaegi ranking module deployed to the workflow
    When the agent calls the search endpoint with a test query
    Then the response includes ranked results
    And the ranking scores reflect relevance to the query

  Scenario: Agent iterates on custom module based on test results
    Given a deployed custom Yaegi ranking module
    And the initial ranking quality is below threshold
    When the agent analyzes test result metrics
    Then the agent rewrites the ranking logic
    And the improved module achieves higher ranking quality
