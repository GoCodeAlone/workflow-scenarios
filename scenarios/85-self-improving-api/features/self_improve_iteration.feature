Feature: Self-improvement iteration and convergence
  As a system operator
  I want the agent to make meaningful progress each iteration
  So that the application continuously improves toward the goal

  Scenario: Agent completes at least one successful iteration
    Given a running self-improvement loop
    And a base task API with no search or pagination
    When the agent runs the self_improvement_loop pipeline
    Then at least one iteration completes without error
    And the improved config is deployed

  Scenario: Each blackboard phase has an artifact
    Given a completed self-improvement iteration
    When we query the blackboard for artifacts
    Then the design phase has a config_proposal artifact
    And the artifact includes the proposed YAML changes

  Scenario: Agent adds FTS5 search within the iteration cap
    Given a self-improvement agent with max_iterations_per_cycle of 5
    And the improvement goal includes FTS5 search
    When the agent runs the full improvement cycle
    Then the deployed config includes an FTS5 search pipeline
    And the improvement was achieved in at most 5 iterations

  Scenario: Agent adds cursor-based pagination
    Given a self-improvement agent targeting list endpoint improvements
    When the agent deploys the improved config
    Then GET /tasks supports a cursor query parameter
    And the response includes a next_cursor field when more results exist

  Scenario: Agent stops gracefully when goal is achieved
    Given a self-improvement agent that has completed its target improvements
    When the agent evaluates the current config against the goal
    Then the agent marks the loop as complete
    And no further improvement iterations are triggered
