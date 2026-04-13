Feature: Git history shows meaningful improvement progression
  As a developer reviewing the agent's work
  I want the git history to tell the story of the application's evolution
  So that each commit represents a distinct, verifiable improvement

  Scenario: Each iteration produces a distinct git commit
    Given the agent has completed N iterations
    When we run git log in /data/repo
    Then there are N commits (excluding the initial commit)
    And each commit has a unique, non-empty message

  Scenario: Commit messages describe functional improvements
    Given the agent has committed at least 3 iterations
    When we read the commit messages
    Then no commit message is generic (e.g. "update", "fix", "changes")
    And each message names the feature or improvement added
    And at least one message references an endpoint or module type

  Scenario: Each commit has a non-trivial diff
    Given the git history has at least 3 iteration commits
    When we inspect the diff for each commit
    Then each diff modifies at least one pipeline or module definition
    And no commit is an empty diff

  Scenario: Final commit results in a larger config than the initial
    Given the initial commit contains the base-app.yaml
    And the agent has completed all iterations
    When we compare the initial and final app.yaml
    Then the final file has more lines than the initial
    And the final file has more pipeline definitions

  Scenario: Commit timestamps are sequential
    Given the git history
    When we check commit timestamps
    Then each commit is later than the previous one
    And all commits occurred during the agent's runtime window
