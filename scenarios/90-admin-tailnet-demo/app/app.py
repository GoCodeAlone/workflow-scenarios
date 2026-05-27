from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from html import escape
import json
import os
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from urllib.parse import parse_qs, urlparse


started_at = time.time()
authz_provider = os.environ.get("AUTHZ_PROVIDER", "keto")
keto_read_url = os.environ.get("KETO_READ_URL", "http://keto:4466")
keto_write_url = os.environ.get("KETO_WRITE_URL", "http://keto:4467")
state_lock = threading.RLock()
keto_seeded = False
sessions = {}
users = {
    "app-user@tailnet": {
        "password": "user",
        "scopes": ["frontend:orders:read", "frontend:requests:create"],
    },
    "readonly-admin@tailnet": {
        "password": "readonly",
        "scopes": ["admin:dashboard:read", "admin:authz.roles:read", "admin:authz.scopes:read"],
    },
    "admin@tailnet": {
        "password": "admin",
        "scopes": [
            "frontend:orders:read",
            "frontend:requests:create",
            "admin:dashboard:read",
            "admin:app:update",
            "admin:auth.settings:read",
            "admin:auth.settings:update",
            "admin:authz.roles:read",
            "admin:authz.roles:update",
            "admin:authz.scopes:read",
            "admin:authz.policies:read",
            "admin:authz.policies:update",
            "admin:authz.relations:read",
            "admin:authz.relations:update",
        ],
    },
}

state = {
    "flag": True,
    "scopes": [
        {"name": "frontend:orders:read", "context": "frontend", "resource": "orders", "actions": ["read"], "description": "Read order data in the primary app", "owner_plugin": "workflow-scenarios", "owner_module": "tailnet-demo", "category": "application"},
        {"name": "frontend:requests:create", "context": "frontend", "resource": "requests", "actions": ["create"], "description": "Create work requests in the primary app", "owner_plugin": "workflow-scenarios", "owner_module": "tailnet-demo", "category": "application"},
        {"name": "frontend:requests:resolve", "context": "frontend", "resource": "app.requests", "actions": ["resolve"], "description": "Resolve application requests", "owner_plugin": "workflow-scenarios", "owner_module": "tailnet-demo", "category": "application"},
        {"name": "admin:dashboard:read", "context": "admin", "resource": "dashboard", "actions": ["read"], "description": "Open the administration portal", "owner_plugin": "workflow-plugin-admin", "owner_module": "admin", "category": "admin"},
        {"name": "admin:app:update", "context": "admin", "resource": "app", "actions": ["update"], "description": "Update application operations from admin", "owner_plugin": "workflow-plugin-admin", "owner_module": "admin", "category": "admin"},
        {"name": "admin:auth.settings:read", "context": "admin", "resource": "auth.settings", "actions": ["read"], "description": "Inspect authentication plugin settings", "owner_plugin": "workflow-plugin-auth", "owner_module": "admin-config", "category": "security"},
        {"name": "admin:auth.settings:update", "context": "admin", "resource": "auth.settings", "actions": ["update"], "description": "Validate and update authentication plugin settings", "owner_plugin": "workflow-plugin-auth", "owner_module": "admin-config", "category": "security"},
        {"name": "admin:authz.roles:read", "context": "admin", "resource": "authz.roles", "actions": ["read"], "description": "Inspect role assignments", "owner_plugin": "workflow-plugin-authz", "owner_module": "scope-catalog", "category": "security"},
        {"name": "admin:authz.roles:update", "context": "admin", "resource": "authz.roles", "actions": ["update"], "description": "Create and remove role assignments", "owner_plugin": "workflow-plugin-authz", "owner_module": "scope-catalog", "category": "security"},
        {"name": "admin:authz.scopes:read", "context": "admin", "resource": "authz.scopes", "actions": ["read"], "description": "Inspect declared application scopes", "owner_plugin": "workflow-plugin-authz", "owner_module": "scope-catalog", "category": "security"},
        {"name": "admin:authz.policies:read", "context": "admin", "resource": "authz.policies", "actions": ["read"], "description": "Inspect ABAC policy rules", "owner_plugin": "workflow-plugin-authz", "owner_module": "attribute-policy", "category": "security"},
        {"name": "admin:authz.policies:update", "context": "admin", "resource": "authz.policies", "actions": ["update"], "description": "Create and remove ABAC policy rules", "owner_plugin": "workflow-plugin-authz", "owner_module": "attribute-policy", "category": "security"},
        {"name": "admin:authz.relations:read", "context": "admin", "resource": "authz.relations", "actions": ["read"], "description": "Inspect ReBAC relationship tuples", "owner_plugin": "workflow-plugin-authz", "owner_module": "relationship-policy", "category": "security"},
        {"name": "admin:authz.relations:update", "context": "admin", "resource": "authz.relations", "actions": ["update"], "description": "Create and remove ReBAC relationship tuples", "owner_plugin": "workflow-plugin-authz", "owner_module": "relationship-policy", "category": "security"},
    ],
    "roles": [
        {"user": "app-user@tailnet", "role": "requester", "context": "frontend", "scopes": ["frontend:orders:read", "frontend:requests:create"]},
        {"user": "readonly-admin@tailnet", "role": "authz-viewer", "context": "admin", "scopes": ["admin:dashboard:read", "admin:authz.roles:read", "admin:authz.scopes:read"]},
        {"user": "admin@tailnet", "role": "authz-admin", "context": "admin", "scopes": ["admin:dashboard:read", "admin:app:update", "admin:auth.settings:read", "admin:auth.settings:update", "admin:authz.roles:read", "admin:authz.roles:update", "admin:authz.scopes:read", "admin:authz.policies:read", "admin:authz.policies:update", "admin:authz.relations:read", "admin:authz.relations:update"]},
    ],
    "auth_config": {
        "environment": "development",
        "password_auth_enabled": False,
        "webauthn_rp_id": "tailnet-demo.local",
        "webauthn_origin": "http://127.0.0.1:18080",
        "smtp_host": "smtp.tailnet.test",
        "smtp_from": "login@tailnet.test",
        "auth_routes_enabled": True,
        "google_oauth_client_id": "google-client-demo",
        "google_oauth_client_secret": "configured-secret",
        "google_oauth_redirect_url": "https://tailnet-demo.local/auth/google/callback",
        "totp_auth_enabled": True,
        "jwt_secret": "configured-secret",
    },
    "attribute_policies": [
        {
            "id": "support-can-read-support-requests",
            "context": "frontend",
            "resource": "requests",
            "action": "read",
            "effect": "allow",
            "conditions": [
                {"target": "subject", "attribute": "department", "operator": "equals", "values": ["support"]},
                {"target": "resource", "attribute": "visibility", "operator": "in", "values": ["support", "public"]},
            ],
            "description": "Support staff can read support-visible requests.",
        },
    ],
    "relation_tuples": [
        {"subject": "admin@tailnet", "relation": "owner", "object": "request:1", "context": "frontend"},
        {"subject": "app-user@tailnet", "relation": "viewer", "object": "request:2", "context": "frontend"},
    ],
    "objects": [
        {"id": "request:1", "context": "frontend", "type": "request", "label": "Request 1"},
        {"id": "request:2", "context": "frontend", "type": "request", "label": "Request 2"},
        {"id": "admin-section:authz", "context": "admin", "type": "admin-section", "label": "Authorization admin section"},
    ],
    "requests": [
        {"id": 1, "title": "Invite beta testers", "status": "open"},
        {"id": 2, "title": "Approve workflow-admin rollout", "status": "open"},
    ],
    "audit": [
        {"event": "scenario.boot", "actor": "system"},
        {"event": "authz.scope_catalog.loaded", "actor": "workflow-plugin-authz"},
    ],
}


def page(title, body, principal=None):
    session_nav = f"<span>{escape(principal)}</span><a href='/logout'>Logout</a>" if principal else "<a href='/login'>Login</a>"
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>{title}</title>
  <style>
    :root {{ color-scheme: light; --ink:#17202a; --muted:#657483; --line:#d8e0e8; --brand:#0f766e; --warn:#b45309; }}
    * {{ box-sizing: border-box; }}
    html, body {{ max-width:100%; overflow-x:hidden; }}
    body {{ margin:0; font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color:var(--ink); background:#f7f9fb; }}
    header {{ background:#101827; color:white; padding:18px 24px; display:flex; justify-content:space-between; gap:16px; align-items:center; flex-wrap:wrap; }}
    header a, header span {{ color:#9ee7df; text-decoration:none; margin-left:16px; }}
    main {{ max-width:1040px; margin:0 auto; padding:28px 20px 44px; }}
    h1 {{ margin:0 0 8px; font-size:28px; }}
    h2 {{ margin:0 0 12px; font-size:18px; }}
    p {{ color:var(--muted); line-height:1.5; }}
    .grid {{ display:grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap:14px; }}
    .card {{ background:white; border:1px solid var(--line); border-radius:8px; padding:16px; box-shadow:0 1px 2px rgba(16,24,39,.04); }}
    .metric {{ font-size:26px; font-weight:700; margin-top:6px; }}
    .pill {{ display:inline-flex; border-radius:999px; padding:4px 10px; font-size:12px; background:#e6f6f4; color:#0f766e; font-weight:700; }}
    .warn {{ background:#fff7ed; color:var(--warn); }}
    table {{ width:100%; border-collapse:collapse; background:white; border:1px solid var(--line); border-radius:8px; overflow-x:auto; display:block; }}
    thead, tbody {{ display:table; width:100%; min-width:640px; }}
    th, td {{ text-align:left; padding:12px; border-bottom:1px solid var(--line); vertical-align:top; }}
    th {{ background:#eef3f7; font-size:13px; color:#334155; }}
    button, input, select {{ font:inherit; }}
    button {{ border:0; border-radius:7px; background:var(--brand); color:white; padding:9px 12px; cursor:pointer; }}
    button.secondary {{ background:#334155; }}
    form {{ display:flex; gap:8px; flex-wrap:wrap; margin:14px 0 20px; }}
    input, select {{ min-width:180px; flex:1; padding:9px 10px; border:1px solid var(--line); border-radius:7px; }}
    .scope-grid {{ display:grid; grid-template-columns:repeat(auto-fit, minmax(220px, 1fr)); gap:10px; margin:16px 0 22px; }}
    .scope-card {{ background:white; border:1px solid var(--line); border-radius:8px; padding:12px; }}
    .scope-card strong, .scope-card span {{ display:block; }}
    .scope-card span {{ color:var(--muted); font-size:12px; margin-top:4px; }}
    .scope-picker {{ display:grid; grid-template-columns:repeat(auto-fit, minmax(220px, 1fr)); gap:8px; flex-basis:100%; }}
    .scope-option {{ display:grid; grid-template-columns:18px minmax(0, 1fr); gap:8px; align-items:start; background:white; border:1px solid var(--line); border-radius:7px; padding:8px; }}
    .scope-option input {{ min-width:0; width:18px; height:18px; flex:0 0 auto; margin:1px 0 0; padding:0; }}
    .scope-option span {{ overflow-wrap:anywhere; }}
    .mode-tabs {{ display:flex; gap:6px; border-bottom:1px solid var(--line); margin:18px 0; overflow-x:auto; }}
    .mode-tabs a {{ color:#334155; text-decoration:none; padding:10px 14px; border:1px solid transparent; border-bottom:0; border-radius:7px 7px 0 0; white-space:nowrap; }}
    .mode-tabs a[aria-selected="true"] {{ color:var(--brand); background:white; border-color:var(--line); font-weight:700; margin-bottom:-1px; }}
    .tab-panel {{ display:block; }}
    code {{ background:#edf2f7; padding:2px 5px; border-radius:5px; }}
    .login-shell {{ max-width:440px; margin:48px auto; }}
    .error {{ color:#991b1b; background:#fef2f2; border:1px solid #fecaca; border-radius:7px; padding:10px 12px; }}
    @media (max-width: 620px) {{
      header {{ align-items:flex-start; }}
      header nav {{ display:flex; flex-wrap:wrap; gap:8px 14px; }}
      header a, header span {{ margin-left:0; }}
      form {{ display:grid; grid-template-columns:1fr; }}
      input, select, button {{ min-width:0; width:100%; }}
    }}
  </style>
</head>
<body>
  <header>
    <strong>Workflow Tailnet Demo</strong>
    <nav><a href="/">App</a><a href="/admin">Admin</a><a href="/admin/authz">Authz</a><a href="/api/status">Status JSON</a>{session_nav}</nav>
  </header>
  <main>{body}</main>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def send_json(self, payload, status=HTTPStatus.OK):
        data = json.dumps(payload, indent=2).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_html(self, html, status=HTTPStatus.OK):
        data = html.encode()
        self.send_response(status)
        self.send_header("content-type", "text/html; charset=utf-8")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path
        principal = self.current_principal()
        if path == "/favicon.ico":
            self.send_response(HTTPStatus.NO_CONTENT)
            self.end_headers()
            return
        if path == "/":
            with state_lock:
                requests = list(state["requests"])
                flag = state["flag"]
            rows = "".join(f"<tr><td>{item['id']}</td><td>{escape(item['title'])}</td><td><span class='pill'>{escape(item['status'])}</span></td></tr>" for item in requests)
            self.send_html(page("Workflow Tailnet Demo", f"""
              <h1>Application Workspace</h1>
              <p>The primary app surface uses frontend scopes. Creating requests requires <code>frontend:requests:create</code>.</p>
              <div class="grid">
                <section class="card"><h2>Feature Flag</h2><span class="pill {'warn' if not flag else ''}">{'enabled' if flag else 'disabled'}</span></section>
                <section class="card"><h2>Open Requests</h2><div class="metric">{sum(1 for i in requests if i['status'] == 'open')}</div></section>
                <section class="card"><h2>Reachability</h2><p>Local Docker port <code>18080</code>, published to tailnet by Tailscale.</p></section>
              </div>
              <form method="post" action="/request"><input name="title" placeholder="New work request" required /><button type="submit">Create request</button></form>
              <table><thead><tr><th>ID</th><th>Request</th><th>Status</th></tr></thead><tbody>{rows}</tbody></table>
            """, principal))
            return
        if path == "/login":
            query = parse_qs(urlparse(self.path).query)
            next_path = query.get("next", ["/admin"])[0]
            self.send_html(page("Workflow Tailnet Demo Login", f"""
              <section class="card login-shell">
                <h1>Sign in</h1>
                <p>Use <code>admin@tailnet</code>/<code>admin</code>, <code>readonly-admin@tailnet</code>/<code>readonly</code>, or <code>app-user@tailnet</code>/<code>user</code>.</p>
                <form method="post" action="/login">
                  <input type="hidden" name="next" value="{escape(next_path)}" />
                  <input name="email" type="email" placeholder="Email" required />
                  <input name="password" type="password" placeholder="Password" required />
                  <button type="submit">Sign in</button>
                </form>
              </section>
            """, principal))
            return
        if path == "/logout":
            token = self.session_token()
            if token:
                with state_lock:
                    sessions.pop(token, None)
            self.send_response(HTTPStatus.SEE_OTHER)
            self.send_header("location", "/")
            self.send_header("set-cookie", "wf_demo_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax")
            self.end_headers()
            return
        if path == "/admin":
            if not self.require_scope("admin:dashboard:read", html=True):
                return
            with state_lock:
                audit = list(state["audit"][-8:])
            audit_rows = "".join(f"<tr><td>{escape(a['event'])}</td><td>{escape(a['actor'])}</td></tr>" for a in reversed(audit))
            self.send_html(page("Workflow Tailnet Demo Admin", f"""
              <h1>Administration Portal</h1>
              <p>The embedded admin mini-app uses authenticated sessions plus admin scopes.</p>
              <div class="grid">
                <section class="card"><h2>Auth Plugin</h2><span class="pill">session accepted</span><p>Demo principal: <code>{escape(principal)}</code></p></section>
                <section class="card"><h2>Authz Plugin</h2><span class="pill">{escape(authz_provider)}</span><p>{', '.join(escape(s) for s in self.principal_scopes())}</p></section>
                <section class="card"><h2>Registered Views</h2><div class="metric">4</div><p>auth, authz, app, audit</p></section>
              </div>
              <section class="card"><h2>Authorization roles</h2><p>workflow-plugin-authz-ui is registered as an admin contribution at <code>/admin/authz</code>.</p><p><a href="/admin/authz">Open role and scope administration</a></p></section>
              <form method="post" action="/admin/toggle"><button type="submit">Toggle feature flag</button></form>
              <form method="post" action="/admin/resolve"><input name="id" placeholder="Request ID to resolve" required /><button class="secondary" type="submit">Resolve request</button></form>
              <table><thead><tr><th>Audit Event</th><th>Actor</th></tr></thead><tbody>{audit_rows}</tbody></table>
            """, principal))
            return
        if path == "/admin/authz":
            if not self.require_scope("admin:authz.roles:read", html=True):
                return
            query = parse_qs(urlparse(self.path).query)
            active_tab = query.get("tab", ["rbac"])[0]
            if active_tab not in {"rbac", "abac", "rebac"}:
                active_tab = "rbac"
            with state_lock:
                roles = list(state["roles"])
                policies = list(state["attribute_policies"])
                tuples = list(state["relation_tuples"])
                objects = list(state["objects"])
            role_rows = "".join(f"<tr><td>{escape(r['user'])}</td><td>{escape(r['role'])}</td><td>{escape(r['context'])}</td><td>{', '.join(escape(s) for s in r['scopes'])}</td></tr>" for r in roles)
            policy_rows = "".join(f"<tr><td>{escape(p['id'])}</td><td>{escape(p['context'])}</td><td>{escape(p['resource'])}</td><td>{escape(p['action'])}</td><td>{escape(p['effect'])}</td><td>{len(p.get('conditions', []))}</td><td><form method='post' action='/admin/authz/abac/delete'><input type='hidden' name='id' value='{escape(p['id'])}' /><button class='secondary' type='submit'>Delete</button></form></td></tr>" for p in policies)
            tuple_rows = "".join(f"<tr><td>{escape(t['subject'])}</td><td>{escape(t['relation'])}</td><td>{escape(t['object'])}</td><td>{escape(t['context'])}</td><td><form method='post' action='/admin/authz/rebac/delete'><input type='hidden' name='subject' value='{escape(t['subject'])}' /><input type='hidden' name='relation' value='{escape(t['relation'])}' /><input type='hidden' name='object' value='{escape(t['object'])}' /><input type='hidden' name='context' value='{escape(t['context'])}' /><button class='secondary' type='submit'>Delete</button></form></td></tr>" for t in tuples)
            scopes = declared_scopes()
            scope_cards = "".join(f"<div class='scope-card'><strong>{escape(s['name'])}</strong><span>{escape(s['context'])} · {escape(s['resource'])} · {', '.join(escape(a) for a in s['actions'])}</span><span>{escape(s['category'])} · {escape(s['owner_plugin'])} · {escape(s['owner_module'])}</span><p>{escape(s['description'])}</p></div>" for s in scopes)
            scope_options = "".join(f"<label class='scope-option'><input type='checkbox' name='scopes' value='{escape(s['name'])}' /><span>{escape(s['name'])}</span></label>" for s in scopes)
            declarations = authz_declarations()
            context_options = "".join(f"<option value=\"{escape(context)}\">{escape(context)}</option>" for context in sorted({scope["context"] for scope in scopes}))
            resource_options = "".join(f"<option value=\"{escape(resource['name'])}\">{escape(resource.get('display_name') or resource['name'])}</option>" for resource in declarations["resources"])
            action_options = "".join(f"<option value=\"{escape(action['name'])}\">{escape(action['resource'])} · {escape(action['name'])}</option>" for action in declarations["actions"])
            department = next(attr for attr in declarations["attributes"] if attr["name"] == "department")
            visibility = next(attr for attr in declarations["attributes"] if attr["name"] == "visibility")
            department_options = "".join(f"<option value=\"{escape(item['value'])}\">{escape(item.get('label') or item['value'])}</option>" for item in department["allowed_values"])
            visibility_options = "".join(f"<option value=\"{escape(item['value'])}\">{escape(item.get('label') or item['value'])}</option>" for item in visibility["allowed_values"])
            subject_options = "".join(f"<option value=\"{escape(subject)}\">{escape(subject)}</option>" for subject in sorted(users.keys()))
            relation_options = "".join(f"<option value=\"{escape(relation['name'])}\">{escape(relation['context'])} · {escape(relation['name'])}</option>" for relation in declarations["relations"])
            object_options = "".join(f"<option value=\"{escape(obj['id'])}\">{escape(obj['label'])}</option>" for obj in objects)
            capability_cards = "".join(
                f"<section class='card'><h2>{escape(cap['mode'].upper())}</h2><span class='pill'>{escape(cap['health'])}</span><p>{escape(', '.join(cap['operations']))}</p></section>"
                for cap in provider_capabilities()["capability_descriptors"]
            )
            tab_nav = "".join(
                f"<a role=\"tab\" href=\"/admin/authz?tab={tab}\" aria-selected=\"{'true' if active_tab == tab else 'false'}\">{label}</a>"
                for tab, label in [("rbac", "RBAC"), ("abac", "ABAC"), ("rebac", "ReBAC")]
            )
            rbac_panel = f"""
              <section class="tab-panel" role="tabpanel" aria-label="RBAC">
                <div class="scope-grid">{scope_cards}</div>
                <form method="post" action="/api/authz/roles">
                  <input name="user" placeholder="User" required />
                  <input name="role" placeholder="Role" required />
                  <select name="context"><option value="frontend">frontend</option><option value="admin">admin</option></select>
                  <div class="scope-picker">{scope_options}</div>
                  <button type="submit">Assign role</button>
                </form>
                <table><thead><tr><th>User</th><th>Role</th><th>Context</th><th>Direct Scopes</th></tr></thead><tbody>{role_rows}</tbody></table>
              </section>
            """
            abac_panel = f"""
              <section class="tab-panel" role="tabpanel" aria-label="ABAC">
                <section class="card"><h2>ABAC Policies</h2><p>Policies bind declared resources, actions, and attributes. Unknown resources, actions, attributes, and values are rejected by the API.</p></section>
                <form method="post" action="/admin/authz/abac/upsert">
                  <input name="id" placeholder="Policy ID" required />
                  <select name="context">{context_options}</select>
                  <select name="resource">{resource_options}</select>
                  <select name="action">{action_options}</select>
                  <select name="effect"><option value="allow">allow</option><option value="deny">deny</option></select>
                  <select name="department">{department_options}</select>
                  <select name="visibility">{visibility_options}</select>
                  <button type="submit">Save ABAC policy</button>
                </form>
                <table><thead><tr><th>ID</th><th>Context</th><th>Resource</th><th>Action</th><th>Effect</th><th>Conditions</th><th></th></tr></thead><tbody>{policy_rows}</tbody></table>
              </section>
            """
            rebac_panel = f"""
              <section class="tab-panel" role="tabpanel" aria-label="ReBAC">
                <section class="card"><h2>ReBAC Tuples</h2><p>Relationship tuples are evaluated independently from RBAC scopes.</p></section>
                <form method="post" action="/admin/authz/rebac/upsert">
                  <select name="subject">{subject_options}</select>
                  <select name="relation">{relation_options}</select>
                  <select name="object">{object_options}</select>
                  <select name="context">{context_options}</select>
                  <button type="submit">Save relationship</button>
                </form>
                <table><thead><tr><th>Subject</th><th>Relation</th><th>Object</th><th>Context</th><th></th></tr></thead><tbody>{tuple_rows}</tbody></table>
              </section>
            """
            panel = {"rbac": rbac_panel, "abac": abac_panel, "rebac": rebac_panel}[active_tab]
            self.send_html(page("Workflow Authz UI", f"""
              <h1>Role and Scope Administration</h1>
              <p>This admin contribution manages shared roles, attribute policies, and relationship tuples with explicit frontend and admin contexts. All selectable values come from the application declaration catalog.</p>
              <div class="grid">{capability_cards}</div>
              <nav class="mode-tabs" role="tablist">{tab_nav}</nav>
              {panel}
            """, principal))
            return
        if path == "/api/authz/roles":
            if not self.require_scope("admin:authz.roles:read"):
                return
            with state_lock:
                roles = list(state["roles"])
            self.send_json(roles)
            return
        if path == "/api/authz/scopes":
            if not self.require_scope("admin:authz.scopes:read"):
                return
            self.send_json(declared_scopes())
            return
        if path == "/api/authz/capabilities":
            if not self.require_scope("admin:authz.scopes:read"):
                return
            self.send_json(provider_capabilities())
            return
        if path == "/api/authz/declarations":
            if not self.require_scope("admin:authz.scopes:read"):
                return
            self.send_json(authz_declarations())
            return
        if path == "/api/authz/projection-inputs":
            if not self.require_scope("admin:authz.scopes:read"):
                return
            self.send_json(projection_inputs())
            return
        if path == "/api/authz/abac/policies":
            if not self.require_scope("admin:authz.policies:read"):
                return
            with state_lock:
                policies = list(state["attribute_policies"])
            self.send_json(policies)
            return
        if path == "/api/authz/rebac/tuples":
            if not self.require_scope("admin:authz.relations:read"):
                return
            with state_lock:
                tuples = list(state["relation_tuples"])
            self.send_json(tuples)
            return
        if path == "/api/authz/model":
            if not self.require_scope("admin:authz.scopes:read"):
                return
            self.send_json({"model": "workflow-demo rbac+abac+rebac declarations"})
            return
        if path == "/api/authz/policies":
            if not self.require_scope("admin:authz.roles:read"):
                return
            with state_lock:
                roles = list(state["roles"])
            rules = [{"subject": role["user"], "object": scope, "action": "granted"} for role in roles for scope in role.get("scopes", [])]
            self.send_json(rules)
            return
        if path == "/api/admin/auth/config":
            if not self.require_scope("admin:auth.settings:read"):
                return
            self.send_json(auth_admin_describe_output())
            return
        if path == "/api/admin/contributions":
            if not self.require_scope("admin:dashboard:read"):
                return
            self.send_json({"contributions": [
                {"id": "auth-console", "title": "Authentication", "category": "security", "path": "/admin/auth", "render_mode": "native", "app_context": "tailnet-demo", "permissions": [{"permission": "admin:auth.settings:read", "resource": "auth.settings", "action": "read"}, {"permission": "admin:auth.settings:update", "resource": "auth.settings", "action": "update"}]},
                {"id": "authz-console", "title": "Authorization", "category": "security", "path": "/admin/authz", "render_mode": "iframe", "app_context": "tailnet-demo", "permissions": [{"permission": "admin:authz.roles:read", "resource": "authz.roles", "action": "read"}, {"permission": "admin:authz.policies:read", "resource": "authz.policies", "action": "read"}, {"permission": "admin:authz.relations:read", "resource": "authz.relations", "action": "read"}]},
            ]})
            return
        if path == "/api/status":
            with state_lock:
                flag = state["flag"]
                requests = list(state["requests"])
            self.send_json({"app": "workflow-tailnet-admin-demo", "uptimeSeconds": round(time.time() - started_at, 1), "featureFlag": flag, "requests": requests, "admin": {"auth": auth_admin_capabilities(), "authz": provider_capabilities(), "views": ["auth", "authz", "application", "audit"], "declarations": authz_declarations()}})
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        form = self.parse_body(self.rfile.read(length).decode())
        path = urlparse(self.path).path
        principal = self.current_principal()
        if path == "/login":
            email = str(form.get("email", [""])[0]).strip()
            password = str(form.get("password", [""])[0])
            next_path = str(form.get("next", ["/admin"])[0]) or "/admin"
            user = users.get(email)
            if user and secrets.compare_digest(user["password"], password):
                token = secrets.token_urlsafe(24)
                with state_lock:
                    sessions[token] = email
                self.send_response(HTTPStatus.SEE_OTHER)
                self.send_header("location", next_path if next_path.startswith("/") else "/admin")
                self.send_header("set-cookie", f"wf_demo_session={token}; Path=/; HttpOnly; SameSite=Lax")
                self.end_headers()
                return
            self.send_html(page("Workflow Tailnet Demo Login", "<section class='card login-shell'><h1>Sign in</h1><p class='error'>Invalid credentials.</p><p><a href='/login'>Try again</a></p></section>"), HTTPStatus.UNAUTHORIZED)
            return
        if path == "/request":
            if not self.require_scope("frontend:requests:create", html=True):
                return
            title = str(form.get("title", [""])[0]).strip()
            if title:
                with state_lock:
                    state["requests"].append({"id": max(i["id"] for i in state["requests"]) + 1, "title": title, "status": "open"})
                    state["audit"].append({"event": "request.created", "actor": principal})
            self.redirect("/")
            return
        if path == "/admin/toggle":
            if not self.require_scope("admin:app:update", html=True):
                return
            with state_lock:
                state["flag"] = not state["flag"]
                state["audit"].append({"event": "feature_flag.toggled", "actor": principal})
            self.redirect("/admin")
            return
        if path == "/admin/resolve":
            if not self.require_scope("admin:app:update", html=True):
                return
            raw_id = str(form.get("id", [""])[0])
            with state_lock:
                for item in state["requests"]:
                    if str(item["id"]) == raw_id:
                        item["status"] = "resolved"
                        state["audit"].append({"event": f"request.{raw_id}.resolved", "actor": principal})
                        break
            self.redirect("/admin")
            return
        if path == "/api/admin/auth/config/validate":
            if not self.require_scope("admin:auth.settings:update"):
                return
            payload = self.json_payload(form)
            desired = payload.get("desired_config", payload)
            if not isinstance(desired, dict):
                self.send_json({"error": "invalid_config", "reason": "desired_config must be an object"}, HTTPStatus.BAD_REQUEST)
                return
            result = auth_admin_validate_output(desired, bool(payload.get("require_primary_method", True)))
            if result["valid"]:
                with state_lock:
                    state["auth_config"].update(result["accepted_config"])
                    for field in result["secret_fields"]:
                        state["auth_config"][field] = "configured-secret"
                    state["audit"].append({"event": "auth.admin_config.validated", "actor": principal})
            self.send_json(result, HTTPStatus.OK if result["valid"] else HTTPStatus.BAD_REQUEST)
            return
        if path == "/admin/authz/abac/upsert":
            if not self.require_scope("admin:authz.policies:update", html=True):
                return
            payload = attribute_policy_from_form(form)
            valid, reason = validate_attribute_policy(payload)
            if not valid:
                self.send_html(page("Invalid ABAC Policy", f"<h1>Invalid ABAC Policy</h1><p class='error'>{escape(reason)}</p><p><a href='/admin/authz'>Back to authorization</a></p>", principal), HTTPStatus.BAD_REQUEST)
                return
            with state_lock:
                state["attribute_policies"] = [p for p in state["attribute_policies"] if p.get("id") != payload["id"]]
                state["attribute_policies"].append(payload)
                state["audit"].append({"event": "authz.abac_policy.upserted", "actor": principal})
            self.redirect("/admin/authz")
            return
        if path == "/admin/authz/abac/delete":
            if not self.require_scope("admin:authz.policies:update", html=True):
                return
            policy_id = str(form.get("id", [""])[0]).strip()
            with state_lock:
                state["attribute_policies"] = [p for p in state["attribute_policies"] if p.get("id") != policy_id]
                state["audit"].append({"event": "authz.abac_policy.deleted", "actor": principal})
            self.redirect("/admin/authz")
            return
        if path == "/admin/authz/rebac/upsert":
            if not self.require_scope("admin:authz.relations:update", html=True):
                return
            payload = relation_tuple_from_form(form)
            valid, reason = validate_relation_tuple(payload)
            if not valid:
                self.send_html(page("Invalid ReBAC Tuple", f"<h1>Invalid ReBAC Tuple</h1><p class='error'>{escape(reason)}</p><p><a href='/admin/authz'>Back to authorization</a></p>", principal), HTTPStatus.BAD_REQUEST)
                return
            with state_lock:
                if payload not in state["relation_tuples"]:
                    state["relation_tuples"].append(payload)
                    state["audit"].append({"event": "authz.relation_tuple.upserted", "actor": principal})
            if authz_provider == "keto":
                keto_put_relation_tuple(payload)
            self.redirect("/admin/authz")
            return
        if path == "/admin/authz/rebac/delete":
            if not self.require_scope("admin:authz.relations:update", html=True):
                return
            payload = relation_tuple_from_form(form)
            with state_lock:
                state["relation_tuples"] = [t for t in state["relation_tuples"] if not same_relation_tuple(t, payload)]
                state["audit"].append({"event": "authz.relation_tuple.deleted", "actor": principal})
            if authz_provider == "keto":
                keto_delete_relation_tuple(payload)
            self.redirect("/admin/authz")
            return
        if path == "/api/authz/roles":
            if not self.require_scope("admin:authz.roles:update"):
                return
            user = str(form.get("user", [""])[0]).strip()
            role = str(form.get("role", [""])[0]).strip()
            context = str(form.get("context", ["frontend"])[0]).strip() or "frontend"
            scopes = form.get("scopes", [])
            if len(scopes) == 1 and isinstance(scopes[0], str):
                scopes = [s.strip() for s in scopes[0].split(",") if s.strip()]
            valid, reason = validate_assignment_scopes(context, scopes)
            if not valid:
                self.send_json({"error": "invalid_scope", "reason": reason}, HTTPStatus.BAD_REQUEST)
                return
            if user and role:
                with state_lock:
                    state["roles"].append({"user": user, "role": role, "context": context, "scopes": scopes})
                    state["audit"].append({"event": "authz.role.assigned", "actor": principal})
                seed_subject_scopes(user, scopes)
            if self.is_json_request():
                self.send_json({"ok": True})
            else:
                self.redirect("/admin/authz")
            return
        if path == "/api/authz/abac/policies":
            if not self.require_scope("admin:authz.policies:update"):
                return
            payload = self.json_payload(form)
            valid, reason = validate_attribute_policy(payload)
            if not valid:
                self.send_json({"error": "invalid_policy", "reason": reason}, HTTPStatus.BAD_REQUEST)
                return
            with state_lock:
                state["attribute_policies"] = [p for p in state["attribute_policies"] if p.get("id") != payload["id"]]
                state["attribute_policies"].append(payload)
                state["audit"].append({"event": "authz.abac_policy.upserted", "actor": principal})
            self.send_json({"ok": True})
            return
        if path == "/api/authz/rebac/tuples":
            if not self.require_scope("admin:authz.relations:update"):
                return
            payload = self.json_payload(form)
            valid, reason = validate_relation_tuple(payload)
            if not valid:
                self.send_json({"error": "invalid_relation_tuple", "reason": reason}, HTTPStatus.BAD_REQUEST)
                return
            with state_lock:
                if payload not in state["relation_tuples"]:
                    state["relation_tuples"].append(payload)
                    state["audit"].append({"event": "authz.relation_tuple.upserted", "actor": principal})
            if authz_provider == "keto":
                keto_put_relation_tuple(payload)
            self.send_json({"ok": True})
            return
        if path == "/api/authz/rebac/check":
            if not self.require_scope("admin:authz.relations:read"):
                return
            payload = self.json_payload(form)
            allowed = relation_allowed(payload.get("subject", ""), payload.get("relation", ""), payload.get("object", ""), payload.get("context", "frontend"))
            self.send_json({**payload, "allowed": allowed, "reason": "tuple matched" if allowed else "no matching tuple"})
            return
        if path == "/api/authz/enforce":
            if not self.require_scope("admin:authz.scopes:read"):
                return
            payload = self.json_payload(form)
            self.send_json({"allowed": authorization_allowed(payload)})
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def do_DELETE(self):
        length = int(self.headers.get("content-length", "0"))
        form = self.parse_body(self.rfile.read(length).decode())
        payload = self.json_payload(form)
        path = urlparse(self.path).path
        principal = self.current_principal()
        if path == "/api/authz/roles":
            if not self.require_scope("admin:authz.roles:update"):
                return
            user = str(payload.get("user", "")).strip()
            role = str(payload.get("role", "")).strip()
            scopes = payload.get("scopes", [])
            if isinstance(scopes, str):
                scopes = [scopes]
            removed_scopes = []
            with state_lock:
                next_roles = []
                for assignment in state["roles"]:
                    if assignment.get("user") != user or assignment.get("role") != role:
                        next_roles.append(assignment)
                        continue
                    if scopes:
                        remaining = [scope for scope in assignment.get("scopes", []) if scope not in scopes]
                        removed_scopes.extend(scope for scope in assignment.get("scopes", []) if scope in scopes)
                        if remaining:
                            updated = dict(assignment)
                            updated["scopes"] = remaining
                            next_roles.append(updated)
                    else:
                        removed_scopes.extend(assignment.get("scopes", []))
                state["roles"] = next_roles
                state["audit"].append({"event": "authz.role.removed", "actor": principal})
            if authz_provider == "keto":
                for scope in removed_scopes:
                    keto_delete_tuple(user, scope)
            self.send_json({"ok": True})
            return
        if path == "/api/authz/abac/policies":
            if not self.require_scope("admin:authz.policies:update"):
                return
            policy_id = str(payload.get("id", "")).strip()
            with state_lock:
                state["attribute_policies"] = [p for p in state["attribute_policies"] if p.get("id") != policy_id]
                state["audit"].append({"event": "authz.abac_policy.deleted", "actor": principal})
            self.send_json({"ok": True})
            return
        if path == "/api/authz/rebac/tuples":
            if not self.require_scope("admin:authz.relations:update"):
                return
            with state_lock:
                state["relation_tuples"] = [t for t in state["relation_tuples"] if not same_relation_tuple(t, payload)]
                state["audit"].append({"event": "authz.relation_tuple.deleted", "actor": principal})
            if authz_provider == "keto":
                keto_delete_relation_tuple(payload)
            self.send_json({"ok": True})
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def redirect(self, location):
        self.send_response(HTTPStatus.SEE_OTHER)
        self.send_header("location", location)
        self.end_headers()

    def parse_body(self, raw_body):
        if self.headers.get("content-type", "").split(";")[0] == "application/json":
            try:
                data = json.loads(raw_body or "{}")
            except json.JSONDecodeError:
                return {}
            wrapped = {key: value if isinstance(value, list) else [value] for key, value in data.items()}
            wrapped["__json__"] = [data]
            return wrapped
        return parse_qs(raw_body)

    def is_json_request(self):
        return self.headers.get("content-type", "").split(";")[0] == "application/json"

    def json_payload(self, form):
        if "__json__" in form:
            return form["__json__"][0]
        if not self.is_json_request():
            return {key: value[0] if len(value) == 1 else value for key, value in form.items()}
        return {key: value[0] if isinstance(value, list) and len(value) == 1 else value for key, value in form.items()}

    def session_token(self):
        for part in self.headers.get("cookie", "").split(";"):
            key, _, value = part.strip().partition("=")
            if key == "wf_demo_session":
                return value
        return ""

    def current_principal(self):
        token = self.session_token()
        if not token:
            return None
        with state_lock:
            return sessions.get(token)

    def principal_scopes(self):
        principal = self.current_principal()
        if not principal:
            return []
        scopes = set(users.get(principal, {}).get("scopes", []))
        with state_lock:
            for assignment in state["roles"]:
                if assignment.get("user") == principal:
                    scopes.update(assignment.get("scopes", []))
        return sorted(scopes)

    def require_scope(self, scope, html=False):
        principal = self.current_principal()
        if not principal:
            if html:
                self.redirect(f"/login?next={urlparse(self.path).path}")
            else:
                self.send_json({"error": "unauthenticated"}, HTTPStatus.UNAUTHORIZED)
            return False
        if not principal_has_scope(principal, scope):
            if html:
                self.send_html(page("Forbidden", "<h1>Forbidden</h1><p>This session does not have the required scope.</p>", principal), HTTPStatus.FORBIDDEN)
            else:
                self.send_json({"error": "forbidden", "required_scope": scope}, HTTPStatus.FORBIDDEN)
            return False
        return True


def declared_scopes():
    with state_lock:
        return sorted((dict(scope) for scope in state["scopes"]), key=lambda s: s["name"])


def auth_admin_capabilities():
    return {
        "module": "workflow-plugin-auth",
        "provider": "workflow-plugin-auth admin-config-contract",
        "capabilities": ["describe_config", "validate_config_patch", "secret_redaction"],
        "health": "ok",
    }


def auth_admin_describe_output():
    with state_lock:
        config = dict(state["auth_config"])
    policy = auth_admin_methods_policy(config)
    return {
        "groups": auth_admin_groups(config),
        "effective_config": auth_admin_sanitize_config(config),
        "methods_policy": policy,
        "warnings": auth_admin_warnings(config, policy),
        "secret_fields": auth_admin_secret_fields(config),
    }


def auth_admin_validate_output(desired_config, require_primary_method=True):
    with state_lock:
        merged = dict(state["auth_config"])
    merged.update(desired_config)
    policy = auth_admin_methods_policy(merged)
    errors = []
    warnings = auth_admin_warnings(merged, policy)

    if auth_admin_is_production(merged.get("environment")) and auth_admin_bool(merged.get("password_auth_enabled")):
        errors.append(auth_admin_diagnostic("password_auth_enabled", "error", "password auth cannot be enabled in production"))
    if require_primary_method and int(policy.get("primary_method_count", 0)) == 0:
        errors.append(auth_admin_diagnostic("primary_methods", "error", "at least one primary authentication method must be configured"))
    errors.extend(auth_admin_validate_passkey(merged))
    errors.extend(auth_admin_validate_oauth(merged))

    return {
        "valid": not errors,
        "accepted_config": auth_admin_sanitize_config(desired_config),
        "methods_policy": policy,
        "errors": errors,
        "warnings": warnings,
        "secret_fields": auth_admin_secret_fields(desired_config),
    }


def auth_admin_groups(config):
    groups = [
        {
            "key": "primary_methods",
            "label": "Primary methods",
            "description": "Login methods that can establish a user session.",
            "controls": [
                auth_admin_control(config, "webauthn_rp_id", "Passkey relying party ID", "text", "Domain used by browsers to scope passkey credentials.", "Use the effective application host."),
                auth_admin_control(config, "webauthn_origin", "Passkey origin", "url", "Origin that WebAuthn challenges must be created for.", "Use the full application origin."),
                auth_admin_control(config, "password_auth_enabled", "Password login", "toggle", "Allows password sign-in outside production.", "Production policy blocks password login even when enabled.", disabled_reason="password auth cannot be enabled in production" if auth_admin_is_production(config.get("environment")) else ""),
            ],
        },
        {
            "key": "second_factors",
            "label": "Second factors",
            "description": "Additional verification methods used after primary login.",
            "controls": [
                auth_admin_control(config, "totp_auth_enabled", "Authenticator app codes", "toggle", "Enables TOTP enrollment and verification.", "Use recovery codes alongside authenticator app enrollment."),
            ],
        },
        {
            "key": "delivery_methods",
            "label": "Delivery methods",
            "description": "Email and SMS configuration used by passwordless login challenges.",
            "controls": [
                auth_admin_control(config, "smtp_host", "SMTP host", "text", "SMTP server used for email codes and magic links.", "Set with SMTP sender to enable email-code login."),
                auth_admin_control(config, "smtp_from", "SMTP sender", "text", "From address used for auth emails.", "Use a verified sender address from the configured mail provider."),
                auth_admin_control(config, "sms_auth_enabled", "SMS login", "toggle", "Allows SMS verification challenges when Twilio is configured.", "Requires auth routes, Twilio Verify service SID, and Twilio credentials."),
                auth_admin_control(config, "jwt_secret", "Challenge signing secret", "secret", "Secret used to sign email and challenge tokens.", "Write-only. Leave blank to keep an existing configured value."),
            ],
        },
        {
            "key": "oauth_providers",
            "label": "OAuth providers",
            "description": "External identity providers available to auth routes.",
            "controls": auth_admin_oauth_controls(config),
        },
    ]
    for group in groups:
        for control in group["controls"]:
            control["group_key"] = group["key"]
    return groups


def auth_admin_oauth_controls(config):
    controls = [
        auth_admin_control(config, "auth_routes_enabled", "Auth routes", "toggle", "Enables HTTP auth routes used by OAuth callback flows.", "OAuth login requires auth routes before any provider can become login-ready."),
    ]
    for provider, label in [("google", "Google"), ("facebook", "Facebook"), ("instagram", "Instagram"), ("x", "X")]:
        disabled = auth_admin_provider_disabled_reason(provider)
        controls.append(auth_admin_control(config, f"{provider}_oauth_client_id", f"{label} client ID", "text", f"OAuth client identifier issued by {label}.", "Pair with the matching client secret and redirect URL.", disabled_reason=disabled))
        controls.append(auth_admin_control(config, f"{provider}_oauth_client_secret", f"{label} client secret", "secret", f"OAuth client secret issued by {label}.", "Write-only. Leave blank to keep an existing configured value.", disabled_reason=disabled))
        if provider in {"google", "facebook"}:
            controls.append(auth_admin_control(config, f"{provider}_oauth_redirect_url", f"{label} redirect URL", "url", f"Callback URL registered with {label}.", "Must be HTTPS and match the provider application settings.", disabled_reason=disabled))
    return controls


def auth_admin_control(config, key, label, input_type, description, help_text, disabled_reason=""):
    return {
        "key": key,
        "group_key": "",
        "label": label,
        "description": description,
        "help_text": help_text,
        "input_type": input_type,
        "config_key": key,
        "secret": auth_admin_secret_key(key),
        "configured": auth_admin_present(config, key),
        "required": False,
        "enabled": not disabled_reason,
        "disabled_reason": disabled_reason,
        "options": [],
    }


def auth_admin_methods_policy(config):
    passkey = auth_admin_present(config, "webauthn_rp_id") and auth_admin_present(config, "webauthn_origin")
    email = auth_admin_present(config, "smtp_host") and auth_admin_present(config, "smtp_from")
    sms = auth_admin_bool(config.get("sms_auth_enabled")) and auth_admin_present(config, "twilio_verify_service_sid")
    password = auth_admin_bool(config.get("password_auth_enabled")) and not auth_admin_is_production(config.get("environment"))
    totp = auth_admin_bool(config.get("totp_auth_enabled"))
    oauth = []
    if auth_admin_bool(config.get("auth_routes_enabled")) and all(auth_admin_present(config, key) for key in ["google_oauth_client_id", "google_oauth_client_secret", "google_oauth_redirect_url"]):
        oauth.append("google")
    primary_count = sum(1 for item in [passkey, email, sms, password] if item) + len(oauth)
    return {
        "passkey_enabled": passkey,
        "email_code_enabled": email,
        "sms_code_enabled": sms,
        "password_enabled": password,
        "password_auth_enabled": password,
        "totp_enabled": totp,
        "oauth_providers": oauth,
        "primary_method_count": primary_count,
    }


def auth_admin_warnings(config, policy):
    warnings = []
    if auth_admin_bool(config.get("password_auth_enabled")) and not policy.get("password_enabled"):
        warnings.append(auth_admin_diagnostic("password_auth_enabled", "warning", "password login was requested but is not available in this environment"))
    return warnings


def auth_admin_validate_passkey(config):
    rp_id = str(config.get("webauthn_rp_id", "") or "").strip()
    origin = str(config.get("webauthn_origin", "") or "").strip()
    if not rp_id and not origin:
        return []
    errors = []
    if not rp_id:
        errors.append(auth_admin_diagnostic("webauthn_rp_id", "error", "passkey login requires a relying party ID"))
    if not origin:
        errors.append(auth_admin_diagnostic("webauthn_origin", "error", "passkey login requires an origin"))
    elif not auth_admin_secure_origin(origin):
        errors.append(auth_admin_diagnostic("webauthn_origin", "error", "passkey origin must use https except for localhost development"))
    return errors


def auth_admin_validate_oauth(config):
    errors = []
    for provider in ["google", "facebook", "instagram", "x"]:
        if not auth_admin_oauth_requested(config, provider):
            continue
        disabled = auth_admin_provider_disabled_reason(provider)
        if disabled:
            errors.append(auth_admin_diagnostic(f"{provider}_oauth", "error", disabled))
            continue
        if not auth_admin_bool(config.get("auth_routes_enabled")):
            errors.append(auth_admin_diagnostic("auth_routes_enabled", "error", f"{provider} oauth requires auth routes to be enabled"))
        for key in [f"{provider}_oauth_client_id", f"{provider}_oauth_client_secret", f"{provider}_oauth_redirect_url"]:
            if not auth_admin_present(config, key):
                errors.append(auth_admin_diagnostic(key, "error", f"{provider} oauth requires {key}"))
    return errors


def auth_admin_oauth_requested(config, provider):
    if str(config.get("oauth_provider", "")).strip().lower() == provider:
        return True
    client_id = auth_admin_present(config, f"{provider}_oauth_client_id")
    client_secret = auth_admin_present(config, f"{provider}_oauth_client_secret")
    redirect = auth_admin_present(config, f"{provider}_oauth_redirect_url")
    return client_id or (client_secret and redirect) or (client_id and client_secret)


def auth_admin_sanitize_config(config):
    return {key: value for key, value in config.items() if not auth_admin_secret_key(key) and key not in {"desired_config", "config", "require_primary_method"}}


def auth_admin_secret_fields(config):
    return sorted(key for key, value in config.items() if auth_admin_secret_key(key) and value not in {"", None})


def auth_admin_secret_key(key):
    key = str(key).strip().lower()
    return "secret" in key or key in {"twilio_auth_token", "smtp_pass", "jwt_secret"}


def auth_admin_present(config, key):
    value = config.get(key)
    if value is None:
        return False
    if isinstance(value, str):
        value = value.strip()
        return bool(value) and "{{" not in value
    return value is not False


def auth_admin_bool(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() == "true"
    return False


def auth_admin_is_production(environment):
    return str(environment or "").strip().lower() in {"prod", "production"}


def auth_admin_provider_disabled_reason(provider):
    if provider in {"instagram", "x"}:
        return f"{provider} oauth provider is disabled in this release"
    return ""


def auth_admin_secure_origin(origin):
    parsed = urlparse(str(origin).strip())
    if parsed.scheme == "https" and parsed.netloc:
        return True
    return parsed.scheme == "http" and parsed.hostname in {"localhost", "127.0.0.1", "::1"}


def auth_admin_diagnostic(field, severity, message):
    return {"field": field, "severity": severity, "message": message}


def provider_capabilities():
    return {
        "module": "workflow-plugin-authz",
        "provider": f"{authz_provider}+demo-attribute-policy",
        "capabilities": ["rbac", "abac", "rebac"],
        "capability_descriptors": [
            {"mode": "rbac", "operations": ["check", "manage_roles", "list"], "configured": True, "source": "provider", "health": "ok"},
            {"mode": "abac", "operations": ["check", "manage_policies", "list"], "configured": True, "source": "application-demo", "health": "ok"},
            {"mode": "rebac", "operations": ["check", "manage_relations", "list"], "configured": True, "source": "provider", "health": "ok"},
        ],
        "health": "ok",
        "missing_requirements": [],
    }


def authz_declarations():
    scopes = declared_scopes()
    resources = {}
    actions = []
    for scope in scopes:
        resource_key = (scope["context"], scope["resource"])
        resources[resource_key] = {
            "name": scope["resource"],
            "context": scope["context"],
            "display_name": scope["resource"].replace(".", " ").replace("_", " ").title(),
            "description": f"Resource declared by {scope['owner_plugin']}/{scope['owner_module']}",
            "owner_plugin": scope["owner_plugin"],
            "owner_module": scope["owner_module"],
            "category": scope["category"],
            "lookup_source_id": f"{scope['context']}:{scope['resource']}",
        }
        for action in scope["actions"]:
            actions.append({
                "name": action,
                "context": scope["context"],
                "resource": scope["resource"],
                "description": scope["description"],
                "owner_plugin": scope["owner_plugin"],
                "owner_module": scope["owner_module"],
                "category": scope["category"],
            })
    actions.append({
        "name": "read",
        "context": "frontend",
        "resource": "requests",
        "description": "Read requests when ABAC attributes allow access",
        "owner_plugin": "workflow-plugin-authz",
        "owner_module": "attribute-policy",
        "category": "application",
    })
    return {
        "scopes": scopes,
        "resources": sorted(resources.values(), key=lambda r: (r["context"], r["name"])),
        "actions": sorted(actions, key=lambda a: (a["context"], a["resource"], a["name"])),
        "attributes": [
            {"name": "department", "context": "frontend", "target": "subject", "data_type": "string", "allowed_values": [{"value": "support", "label": "Support"}, {"value": "security", "label": "Security"}, {"value": "finance", "label": "Finance"}], "lookup_source_id": "directory.departments", "description": "Department from the authenticated principal profile", "owner_plugin": "workflow-plugin-auth", "owner_module": "profiles", "category": "identity"},
            {"name": "visibility", "context": "frontend", "target": "resource", "data_type": "string", "allowed_values": [{"value": "public", "label": "Public"}, {"value": "support", "label": "Support"}, {"value": "private", "label": "Private"}], "lookup_source_id": "requests.visibility", "description": "Request visibility classification", "owner_plugin": "workflow-scenarios", "owner_module": "tailnet-demo", "category": "application"},
            {"name": "risk", "context": "admin", "target": "resource", "data_type": "string", "allowed_values": [{"value": "low", "label": "Low"}, {"value": "high", "label": "High"}], "lookup_source_id": "admin.risk", "description": "Administrative operation risk level", "owner_plugin": "workflow-plugin-admin", "owner_module": "admin", "category": "security"},
        ],
        "relations": [
            {"name": "owner", "context": "frontend", "subject_type": "user", "object_type": "request", "description": "Subject owns the request", "owner_plugin": "workflow-plugin-authz", "owner_module": "relationship-policy", "category": "application"},
            {"name": "viewer", "context": "frontend", "subject_type": "user", "object_type": "request", "description": "Subject can view the request", "owner_plugin": "workflow-plugin-authz", "owner_module": "relationship-policy", "category": "application"},
            {"name": "delegated-admin", "context": "admin", "subject_type": "user", "object_type": "admin-section", "description": "Subject can administer the named admin section", "owner_plugin": "workflow-plugin-admin", "owner_module": "navigation", "category": "security"},
        ],
        "ui_actions": [
            {"id": "frontend.create_request", "context": "frontend", "label": "Create request", "route": "/", "required_scopes": ["frontend:requests:create"], "description": "Show the create request form", "owner_plugin": "workflow-scenarios", "owner_module": "tailnet-demo", "category": "application"},
            {"id": "admin.open_authz", "context": "admin", "label": "Open authorization", "route": "/admin/authz", "required_scopes": ["admin:authz.roles:read"], "description": "Show the authz admin contribution", "owner_plugin": "workflow-plugin-admin", "owner_module": "navigation", "category": "security"},
            {"id": "admin.manage_abac", "context": "admin", "label": "Manage ABAC", "route": "/admin/authz", "required_scopes": ["admin:authz.policies:update"], "description": "Show ABAC policy editing controls", "owner_plugin": "workflow-plugin-authz-ui", "owner_module": "abac", "category": "security"},
        ],
    }


def projection_inputs():
    declarations = authz_declarations()
    return {
        "scope_names": sorted(scope["name"] for scope in declarations["scopes"]),
        "resource_names": sorted({resource["name"] for resource in declarations["resources"]}),
        "action_names": sorted({action["name"] for action in declarations["actions"]}),
        "attribute_names": sorted({attribute["name"] for attribute in declarations["attributes"]}),
        "relation_names": sorted({relation["name"] for relation in declarations["relations"]}),
        "ui_action_ids": sorted(action["id"] for action in declarations["ui_actions"]),
        "lookup_source_ids": sorted({item["lookup_source_id"] for item in declarations["resources"] + declarations["attributes"] if item.get("lookup_source_id")}),
    }


def validate_assignment_scopes(context, scopes):
    declared = {scope["name"]: scope for scope in declared_scopes()}
    for scope in scopes:
        if scope not in declared:
            return False, f"{scope} is not declared"
        if declared[scope]["context"] != context:
            return False, f"{scope} belongs to {declared[scope]['context']}, not {context}"
    return True, ""


def attribute_policy_from_form(form):
    return {
        "id": str(form.get("id", [""])[0]).strip(),
        "context": str(form.get("context", ["frontend"])[0]).strip() or "frontend",
        "resource": str(form.get("resource", [""])[0]).strip(),
        "action": str(form.get("action", [""])[0]).strip(),
        "effect": str(form.get("effect", ["allow"])[0]).strip() or "allow",
        "conditions": [
            {"target": "subject", "attribute": "department", "operator": "equals", "values": [str(form.get("department", [""])[0]).strip()]},
            {"target": "resource", "attribute": "visibility", "operator": "equals", "values": [str(form.get("visibility", [""])[0]).strip()]},
        ],
        "description": "Policy created from the admin demo UI.",
    }


def relation_tuple_from_form(form):
    return {
        "subject": str(form.get("subject", [""])[0]).strip(),
        "relation": str(form.get("relation", [""])[0]).strip(),
        "object": str(form.get("object", [""])[0]).strip(),
        "context": str(form.get("context", ["frontend"])[0]).strip() or "frontend",
    }


def validate_attribute_policy(policy):
    if not isinstance(policy, dict):
        return False, "policy must be an object"
    required = ["id", "context", "resource", "action", "effect", "conditions"]
    if any(not policy.get(key) for key in required):
        return False, "policy requires id, context, resource, action, effect, and conditions"
    if policy["effect"] not in {"allow", "deny"}:
        return False, "effect must be allow or deny"
    declarations = authz_declarations()
    actions = {(action["context"], action["resource"], action["name"]) for action in declarations["actions"]}
    if (policy["context"], policy["resource"], policy["action"]) not in actions:
        return False, f"{policy['context']} {policy['resource']} {policy['action']} is not declared"
    attributes = {(attribute["context"], attribute["target"], attribute["name"]): attribute for attribute in declarations["attributes"]}
    for condition in policy.get("conditions", []):
        key = (policy["context"], condition.get("target"), condition.get("attribute"))
        declaration = attributes.get(key)
        if not declaration:
            return False, f"{condition.get('target')}.{condition.get('attribute')} is not declared"
        if condition.get("operator") not in {"equals", "in"}:
            return False, "condition operator must be equals or in"
        allowed = {item["value"] for item in declaration.get("allowed_values", [])}
        values = condition.get("values", [])
        if not isinstance(values, list) or not values:
            return False, "condition values must be a non-empty list"
        if allowed and any(value not in allowed for value in values):
            return False, f"{condition.get('attribute')} contains an undeclared value"
    return True, ""


def validate_relation_tuple(tuple_data):
    if not isinstance(tuple_data, dict):
        return False, "tuple must be an object"
    required = ["subject", "relation", "object", "context"]
    if any(not tuple_data.get(key) for key in required):
        return False, "tuple requires subject, relation, object, and context"
    declarations = authz_declarations()
    declared = {(relation["context"], relation["name"]) for relation in declarations["relations"]}
    if (tuple_data["context"], tuple_data["relation"]) not in declared:
        return False, f"{tuple_data['context']} {tuple_data['relation']} is not declared"
    return True, ""


def authorization_allowed(request):
    subject = str(request.get("subject", ""))
    obj = str(request.get("object", ""))
    action = str(request.get("action", ""))
    if obj in {scope["name"] for scope in declared_scopes()} and action in {"granted", "read", "check"}:
        return principal_has_scope(subject, obj)
    for scope in declared_scopes():
        if scope["resource"] == obj and action in scope["actions"] and principal_has_scope(subject, scope["name"]):
            return True
    if attribute_policy_allows(subject, obj, action, request):
        return True
    relation = request.get("relation")
    if relation and relation_allowed(subject, relation, obj, request.get("context", "frontend")):
        return True
    return False


def attribute_policy_allows(subject, resource, action, request):
    subject_attrs = default_subject_attributes(subject)
    subject_attrs.update(request.get("subject_attributes", {}))
    resource_attrs = default_resource_attributes(resource)
    resource_attrs.update(request.get("resource_attributes", {}))
    with state_lock:
        policies = [p for p in state["attribute_policies"] if p.get("resource") == resource and p.get("action") == action]
    denied = False
    allowed = False
    for policy in policies:
        if all(condition_matches(condition, subject_attrs, resource_attrs) for condition in policy.get("conditions", [])):
            if policy.get("effect") == "deny":
                denied = True
            if policy.get("effect") == "allow":
                allowed = True
    return allowed and not denied


def condition_matches(condition, subject_attrs, resource_attrs):
    attrs = subject_attrs if condition.get("target") == "subject" else resource_attrs
    actual = attrs.get(condition.get("attribute"))
    values = condition.get("values", [])
    if condition.get("operator") == "equals":
        return actual in values
    if condition.get("operator") == "in":
        if isinstance(actual, list):
            return any(value in values for value in actual)
        return actual in values
    return False


def default_subject_attributes(subject):
    if subject == "app-user@tailnet":
        return {"department": "support"}
    if subject == "admin@tailnet":
        return {"department": "security"}
    return {"department": "finance"}


def default_resource_attributes(resource):
    if resource in {"requests", "request:2"}:
        return {"visibility": "support"}
    if resource == "request:1":
        return {"visibility": "private"}
    return {"visibility": "public", "risk": "low"}


def relation_allowed(subject, relation, obj, context):
    if authz_provider == "keto" and keto_relation_check(subject, relation, obj):
        return True
    with state_lock:
        return any(
            tuple_data.get("subject") == subject
            and tuple_data.get("relation") == relation
            and tuple_data.get("object") == obj
            and tuple_data.get("context") == context
            for tuple_data in state["relation_tuples"]
        )


def same_relation_tuple(left, right):
    return all(left.get(key) == right.get(key) for key in ["subject", "relation", "object", "context"])


def principal_has_scope(principal, scope):
    if not principal:
        return False
    if not state_principal_has_scope(principal, scope):
        return False
    if authz_provider == "keto":
        return keto_scope_check(principal, scope)
    return True


def state_principal_has_scope(principal, scope):
    if scope in users.get(principal, {}).get("scopes", []):
        return True
    with state_lock:
        return any(principal == assignment.get("user") and scope in assignment.get("scopes", []) for assignment in state["roles"])


def ensure_keto_seeded():
    global keto_seeded
    if authz_provider != "keto" or keto_seeded:
        return True
    with state_lock:
        seed_pairs = [(user, scope) for user, data in users.items() for scope in data.get("scopes", [])]
        seed_pairs.extend((assignment["user"], scope) for assignment in state["roles"] for scope in assignment.get("scopes", []))
        relation_tuples = list(state["relation_tuples"])
    for _ in range(20):
        try:
            for subject, scope in seed_pairs:
                keto_put_tuple(subject, scope)
            for tuple_data in relation_tuples:
                keto_put_relation_tuple(tuple_data)
            keto_seeded = True
            return True
        except urllib.error.URLError:
            time.sleep(0.2)
    return False


def seed_subject_scopes(subject, scopes):
    if authz_provider != "keto":
        return
    for scope in scopes:
        try:
            keto_put_tuple(subject, scope)
        except urllib.error.URLError:
            return


def keto_put_tuple(subject, scope):
    payload = json.dumps({
        "namespace": "scope",
        "object": scope,
        "relation": "granted",
        "subject_id": subject,
    }).encode()
    request = urllib.request.Request(f"{keto_write_url}/admin/relation-tuples", data=payload, method="PUT", headers={"content-type": "application/json"})
    try:
        urllib.request.urlopen(request, timeout=2).read()
    except urllib.error.HTTPError as exc:
        if exc.code != 409:
            raise


def keto_delete_tuple(subject, scope):
    payload = json.dumps({
        "namespace": "scope",
        "object": scope,
        "relation": "granted",
        "subject_id": subject,
    }).encode()
    request = urllib.request.Request(f"{keto_write_url}/admin/relation-tuples", data=payload, method="DELETE", headers={"content-type": "application/json"})
    try:
        urllib.request.urlopen(request, timeout=2).read()
    except urllib.error.HTTPError as exc:
        if exc.code not in {400, 404, 409}:
            raise
    except urllib.error.URLError:
        return


def keto_put_relation_tuple(tuple_data):
    payload = json.dumps({
        "namespace": "resource",
        "object": tuple_data["object"],
        "relation": tuple_data["relation"],
        "subject_id": tuple_data["subject"],
    }).encode()
    request = urllib.request.Request(f"{keto_write_url}/admin/relation-tuples", data=payload, method="PUT", headers={"content-type": "application/json"})
    try:
        urllib.request.urlopen(request, timeout=2).read()
    except urllib.error.HTTPError as exc:
        if exc.code != 409:
            raise
    except urllib.error.URLError:
        return


def keto_delete_relation_tuple(tuple_data):
    payload = json.dumps({
        "namespace": "resource",
        "object": tuple_data.get("object", ""),
        "relation": tuple_data.get("relation", ""),
        "subject_id": tuple_data.get("subject", ""),
    }).encode()
    request = urllib.request.Request(f"{keto_write_url}/admin/relation-tuples", data=payload, method="DELETE", headers={"content-type": "application/json"})
    try:
        urllib.request.urlopen(request, timeout=2).read()
    except urllib.error.HTTPError as exc:
        if exc.code not in {400, 404, 409}:
            raise
    except urllib.error.URLError:
        return


def keto_scope_check(subject, scope):
    if not ensure_keto_seeded():
        return False
    query = urllib.parse.urlencode({
        "namespace": "scope",
        "object": scope,
        "relation": "granted",
        "subject_id": subject,
        "max-depth": "32",
    })
    try:
        with urllib.request.urlopen(f"{keto_read_url}/relation-tuples/check/openapi?{query}", timeout=2) as response:
            data = json.loads(response.read().decode() or "{}")
            return bool(data.get("allowed"))
    except urllib.error.HTTPError as exc:
        if exc.code == 403:
            return False
        return False
    except urllib.error.URLError:
        return False


def keto_relation_check(subject, relation, obj):
    if not ensure_keto_seeded():
        return False
    query = urllib.parse.urlencode({
        "namespace": "resource",
        "object": obj,
        "relation": relation,
        "subject_id": subject,
        "max-depth": "32",
    })
    try:
        with urllib.request.urlopen(f"{keto_read_url}/relation-tuples/check/openapi?{query}", timeout=2) as response:
            data = json.loads(response.read().decode() or "{}")
            return bool(data.get("allowed"))
    except urllib.error.HTTPError as exc:
        if exc.code == 403:
            return False
        return False
    except urllib.error.URLError:
        return False


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
