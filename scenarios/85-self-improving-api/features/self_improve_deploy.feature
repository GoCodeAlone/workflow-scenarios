Feature: Self-improving deployment strategies
  As a system operator
  I want the agent to deploy improvements safely
  So that application availability is maintained during improvements

  Scenario: Agent deploys via hot reload strategy
    Given a running workflow application
    And the deploy strategy is set to hot_reload
    When the agent deploys an improved config
    Then the workflow engine reloads without restart
    And existing in-flight requests complete normally

  Scenario: Agent commits each iteration to git
    Given a self-improvement agent running in a local git repo
    When the agent deploys an improvement
    Then a git commit is created with a descriptive message
    And the commit diff shows the config changes

  Scenario: Agent rolls back on deploy failure
    Given a running workflow application
    When the agent deploys a config that fails to start
    Then the deploy step detects the startup failure
    And the previous config is restored
    And the application continues serving requests

  Scenario: Git history tracks multiple improvement iterations
    Given a self-improvement agent that has run 3 iterations
    When we inspect the git log
    Then there are at least 3 commits after the initial commit
    And each commit message describes a functional improvement
    And the diffs show progressive config evolution
