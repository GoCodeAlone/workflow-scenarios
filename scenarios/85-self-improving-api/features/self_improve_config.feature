Feature: Self-improving config modification
  As an AI agent
  I want to modify the workflow config to add new functionality
  So that the application evolves autonomously

  Scenario: Agent validates current config via MCP
    Given a running workflow application with base config
    And an AI agent with MCP tool access
    When the agent calls mcp:wfctl:inspect_config
    Then the agent receives a structured config summary
    And the summary includes module types and pipeline names

  Scenario: Agent proposes valid config changes
    Given a running workflow application with base config
    And an AI agent tasked with adding FTS5 search
    When the agent designs config changes
    And the agent calls mcp:wfctl:validate_config on the proposal
    Then the validation passes with zero errors

  Scenario: Agent uses LSP to check syntax
    Given an AI agent with LSP tool access
    When the agent calls mcp:lsp:diagnose on proposed YAML
    Then the agent receives diagnostic results
    And there are no error-level diagnostics

  Scenario: Agent iterates on validation failure
    Given an AI agent that proposed invalid config
    When validation returns errors
    Then the agent reads the error messages
    And the agent modifies the proposal to fix the errors
    And revalidation passes

  Scenario: Agent uses schema tools before proposing modules
    Given an AI agent designing config improvements
    When the agent calls mcp:wfctl:get_module_schema for a new module type
    Then the agent receives the schema definition
    And the agent uses the schema to populate required fields correctly
