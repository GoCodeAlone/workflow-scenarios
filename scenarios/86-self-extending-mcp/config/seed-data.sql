-- Scenario 86: Seed Data — 52 realistic task records
-- Varied statuses, priorities, and timestamps for meaningful analytics.
-- Completion rates, bottlenecks, and time-to-completion all non-trivial.

CREATE TABLE IF NOT EXISTS tasks (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    title        TEXT NOT NULL,
    description  TEXT DEFAULT '',
    status       TEXT NOT NULL DEFAULT 'pending',  -- pending, in_progress, blocked, review, done
    priority     TEXT NOT NULL DEFAULT 'medium',   -- low, medium, high, critical
    created_at   DATETIME NOT NULL,
    updated_at   DATETIME NOT NULL,
    completed_at DATETIME
);

-- Done tasks (21 records) — completed within 1-72 hours
INSERT INTO tasks (title, description, status, priority, created_at, updated_at, completed_at) VALUES
  ('Set up CI pipeline', 'Configure GitHub Actions for build and test', 'done', 'high', datetime('now', '-30 days'), datetime('now', '-29 days'), datetime('now', '-29 days')),
  ('Write API spec', 'OpenAPI 3.0 specification for task service', 'done', 'high', datetime('now', '-28 days'), datetime('now', '-27 days'), datetime('now', '-27 days')),
  ('Design database schema', 'Tasks table with indexes', 'done', 'high', datetime('now', '-27 days'), datetime('now', '-26 days'), datetime('now', '-26 days')),
  ('Implement health endpoint', 'GET /healthz returns 200', 'done', 'medium', datetime('now', '-26 days'), datetime('now', '-25 days'), datetime('now', '-25 days')),
  ('Add request logging', 'Structured JSON logs for all requests', 'done', 'medium', datetime('now', '-25 days'), datetime('now', '-24 days'), datetime('now', '-24 days')),
  ('Create task CRUD', 'Basic create/read/update/delete for tasks', 'done', 'high', datetime('now', '-24 days'), datetime('now', '-22 days'), datetime('now', '-22 days')),
  ('Add pagination', 'Cursor-based pagination for list endpoint', 'done', 'medium', datetime('now', '-22 days'), datetime('now', '-20 days'), datetime('now', '-20 days')),
  ('Implement priority field', 'Add priority (low/medium/high/critical)', 'done', 'low', datetime('now', '-20 days'), datetime('now', '-19 days'), datetime('now', '-19 days')),
  ('Add input validation', 'Validate required fields on create', 'done', 'medium', datetime('now', '-19 days'), datetime('now', '-18 days'), datetime('now', '-18 days')),
  ('Write unit tests', 'Cover CRUD endpoints', 'done', 'high', datetime('now', '-18 days'), datetime('now', '-16 days'), datetime('now', '-16 days')),
  ('Fix null description bug', 'NULL description causes 500 on GET', 'done', 'critical', datetime('now', '-16 days'), datetime('now', '-16 days'), datetime('now', '-16 days')),
  ('Add status filter', 'GET /tasks?status=pending', 'done', 'medium', datetime('now', '-15 days'), datetime('now', '-14 days'), datetime('now', '-14 days')),
  ('Add created_at index', 'Index on created_at for sorted queries', 'done', 'low', datetime('now', '-14 days'), datetime('now', '-13 days'), datetime('now', '-13 days')),
  ('Document API endpoints', 'Add curl examples to README', 'done', 'low', datetime('now', '-13 days'), datetime('now', '-12 days'), datetime('now', '-12 days')),
  ('Deploy to staging', 'Docker compose up on staging VM', 'done', 'high', datetime('now', '-12 days'), datetime('now', '-11 days'), datetime('now', '-11 days')),
  ('Load test with k6', '500 VU ramp test for 5 minutes', 'done', 'medium', datetime('now', '-11 days'), datetime('now', '-10 days'), datetime('now', '-10 days')),
  ('Fix memory leak', 'DB connection not closed on cancel', 'done', 'critical', datetime('now', '-10 days'), datetime('now', '-9 days'), datetime('now', '-9 days')),
  ('Add completed_at field', 'Set when status changes to done', 'done', 'medium', datetime('now', '-9 days'), datetime('now', '-8 days'), datetime('now', '-8 days')),
  ('Implement soft delete', 'Add deleted_at, filter from list', 'done', 'low', datetime('now', '-8 days'), datetime('now', '-7 days'), datetime('now', '-7 days')),
  ('Add rate limiting', 'Max 100 req/min per IP', 'done', 'medium', datetime('now', '-7 days'), datetime('now', '-6 days'), datetime('now', '-6 days')),
  ('Write integration tests', 'Full CRUD + edge cases against live DB', 'done', 'high', datetime('now', '-6 days'), datetime('now', '-5 days'), datetime('now', '-5 days'));

-- In-progress tasks (10 records) — started 1-5 days ago, not done
INSERT INTO tasks (title, description, status, priority, created_at, updated_at) VALUES
  ('Add full-text search', 'SQLite FTS5 for task title + description', 'in_progress', 'high', datetime('now', '-5 days'), datetime('now', '-1 days')),
  ('Implement webhooks', 'POST callback on status change', 'in_progress', 'high', datetime('now', '-5 days'), datetime('now', '-2 days')),
  ('Add task tags', 'Many-to-many tags for filtering', 'in_progress', 'medium', datetime('now', '-4 days'), datetime('now', '-1 days')),
  ('Build analytics dashboard', 'Grafana + SQLite datasource', 'in_progress', 'medium', datetime('now', '-4 days'), datetime('now', '-1 days')),
  ('Add due_date field', 'Optional due date with overdue flag', 'in_progress', 'medium', datetime('now', '-3 days'), datetime('now', '-1 hours')),
  ('Implement task comments', 'Threaded comments per task', 'in_progress', 'low', datetime('now', '-3 days'), datetime('now', '-2 hours')),
  ('Add audit log', 'Record every state transition', 'in_progress', 'high', datetime('now', '-2 days'), datetime('now', '-30 minutes')),
  ('Optimize list query', 'Add covering index for status+created_at', 'in_progress', 'medium', datetime('now', '-2 days'), datetime('now', '-1 hours')),
  ('Add task assignments', 'Assign tasks to user IDs', 'in_progress', 'medium', datetime('now', '-1 days'), datetime('now', '-3 hours')),
  ('Write e2e tests', 'Playwright tests for task workflows', 'in_progress', 'high', datetime('now', '-1 days'), datetime('now', '-30 minutes'));

-- Blocked tasks (8 records) — the bottleneck status
INSERT INTO tasks (title, description, status, priority, created_at, updated_at) VALUES
  ('Integrate with Slack', 'Webhook blocked pending security review', 'blocked', 'high', datetime('now', '-14 days'), datetime('now', '-5 days')),
  ('Add SSO support', 'Blocked on identity provider contract', 'blocked', 'critical', datetime('now', '-12 days'), datetime('now', '-8 days')),
  ('Enable encryption at rest', 'Waiting for key management decision', 'blocked', 'critical', datetime('now', '-10 days'), datetime('now', '-6 days')),
  ('Multi-region deployment', 'Blocked on networking team capacity', 'blocked', 'high', datetime('now', '-9 days'), datetime('now', '-5 days')),
  ('Add RBAC', 'Blocked on permission model design review', 'blocked', 'high', datetime('now', '-7 days'), datetime('now', '-3 days')),
  ('Migrate to PostgreSQL', 'Blocked on DBA approval for schema changes', 'blocked', 'medium', datetime('now', '-6 days'), datetime('now', '-2 days')),
  ('Enable CORS headers', 'Blocked pending security policy decision', 'blocked', 'medium', datetime('now', '-4 days'), datetime('now', '-1 days')),
  ('Add SLA alerts', 'Blocked on alert routing setup with DevOps', 'blocked', 'high', datetime('now', '-3 days'), datetime('now', '-12 hours'));

-- Review tasks (8 records) — in review, waiting for approval
INSERT INTO tasks (title, description, status, priority, created_at, updated_at) VALUES
  ('Refactor step handlers', 'Code review in progress', 'review', 'medium', datetime('now', '-5 days'), datetime('now', '-1 days')),
  ('Add OpenAPI docs', 'PR open, awaiting approval', 'review', 'low', datetime('now', '-4 days'), datetime('now', '-2 days')),
  ('Improve error messages', 'PR review: add context to 400/404 bodies', 'review', 'low', datetime('now', '-4 days'), datetime('now', '-1 days')),
  ('Add request ID header', 'X-Request-ID propagation review', 'review', 'medium', datetime('now', '-3 days'), datetime('now', '-1 days')),
  ('Update dependencies', 'go mod tidy + security patches', 'review', 'high', datetime('now', '-2 days'), datetime('now', '-6 hours')),
  ('Add swagger UI', 'Serve swagger UI at /docs', 'review', 'low', datetime('now', '-2 days'), datetime('now', '-8 hours')),
  ('Increase test coverage', 'Add edge case tests, PR in review', 'review', 'medium', datetime('now', '-1 days'), datetime('now', '-4 hours')),
  ('Add metrics endpoint', 'GET /metrics in Prometheus format', 'review', 'medium', datetime('now', '-1 days'), datetime('now', '-2 hours'));

-- Pending tasks (5 records) — not started
INSERT INTO tasks (title, description, status, priority, created_at, updated_at) VALUES
  ('Add GraphQL API', 'Optional GraphQL layer over REST', 'pending', 'low', datetime('now', '-2 days'), datetime('now', '-2 days')),
  ('Implement caching', 'Redis cache for list queries', 'pending', 'medium', datetime('now', '-1 days'), datetime('now', '-1 days')),
  ('Add export to CSV', 'GET /tasks/export?format=csv', 'pending', 'low', datetime('now', '-12 hours'), datetime('now', '-12 hours')),
  ('Set up alerting', 'PagerDuty integration for error spikes', 'pending', 'high', datetime('now', '-8 hours'), datetime('now', '-8 hours')),
  ('Write runbook', 'Incident response runbook for on-call', 'pending', 'medium', datetime('now', '-2 hours'), datetime('now', '-2 hours'));
