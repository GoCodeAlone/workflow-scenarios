Feature: Agent tests its own API after each iteration
  As an AI agent
  I want to send HTTP requests to the application I'm improving
  So that I can verify my changes work before moving to the next iteration

  Scenario: Agent verifies health endpoint after deployment
    Given the agent has deployed an iteration
    When the agent sends a GET request to http://app:8080/healthz
    Then the response has status 200
    And the agent logs the result as passed

  Scenario: Agent creates a test task via POST /tasks
    Given the agent has deployed an iteration with task CRUD
    When the agent sends a POST request to http://app:8080/tasks
    With body {"title": "agent-created verification task", "description": "automated check"}
    Then the response has status 201
    And the agent verifies the task appears in GET /tasks

  Scenario: Agent tests any new endpoints it added
    Given the agent added a new endpoint in this iteration
    When the agent sends an HTTP request to the new endpoint
    Then the endpoint responds with a non-5xx status code
    And the agent logs what endpoint was tested and whether it passed

  Scenario: Agent generates updated OpenAPI spec after iteration
    Given the agent has deployed a new iteration
    When the agent calls mcp:wfctl:api_extract
    Then the spec is updated to include new endpoints
    And the spec is valid OpenAPI 3.0
    And the agent posts the spec to the blackboard

  Scenario: Agent handles verification failure gracefully
    Given an agent that deployed a change
    And the change caused a 500 error on an endpoint
    When the agent detects the failure via HTTP check
    Then the agent logs the failure
    And the agent proposes a fix in the next sub-iteration
    And the final deployed state is error-free
