Feature: Autonomous agile improvement iterations
  As an AI agent with full application control
  I want to iteratively improve the application like an agile team
  So that the application grows in functionality over time

  Scenario: Agent performs at least 3 improvement iterations
    Given a running base application with basic task CRUD
    And an autonomous improvement agent with full tool access
    When the agent completes its improvement cycle
    Then the git history shows at least 3 commits
    And each commit message describes a functional improvement

  Scenario: Agent audits the application before each iteration
    Given a running base application
    And an autonomous improvement agent
    When the agent starts an iteration
    Then the agent calls mcp:wfctl:inspect_config
    And the agent calls mcp:wfctl:detect_project_features
    And the agent posts an audit_report artifact to the blackboard

  Scenario: Each iteration produces a validated, deployed config
    Given the agent is in an improvement iteration
    When the agent proposes config changes
    Then the agent validates the proposal with mcp:wfctl:validate_config
    And validation passes with zero errors
    And the agent deploys via hot_reload
    And the application continues to respond after deployment

  Scenario: Final application has more capabilities than the base
    Given the agent has completed all iterations
    When we compare the final config to the base config
    Then the final config has more pipeline definitions
    And the final config has at least one new module type or step type
    And the final config passes wfctl validate with zero errors

  Scenario: Agent stops after 5 iterations
    Given an autonomous improvement agent
    When the agent reaches iteration 5
    Then the agent completes the final iteration
    And the agent does not start a sixth iteration
    And the blackboard contains artifacts from all 5 iterations
