from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from html import escape
import json
import os
import secrets
import threading
import time
from urllib.parse import parse_qs, urlparse


started_at = time.time()
authz_provider = os.environ.get("AUTHZ_PROVIDER", "keto")
state_lock = threading.RLock()
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
            "admin:authz.roles:read",
            "admin:authz.roles:update",
            "admin:authz.scopes:read",
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
        {"name": "admin:authz.roles:read", "context": "admin", "resource": "authz.roles", "actions": ["read"], "description": "Inspect role assignments", "owner_plugin": "workflow-plugin-authz", "owner_module": "scope-catalog", "category": "security"},
        {"name": "admin:authz.roles:update", "context": "admin", "resource": "authz.roles", "actions": ["update"], "description": "Create and remove role assignments", "owner_plugin": "workflow-plugin-authz", "owner_module": "scope-catalog", "category": "security"},
        {"name": "admin:authz.scopes:read", "context": "admin", "resource": "authz.scopes", "actions": ["read"], "description": "Inspect declared application scopes", "owner_plugin": "workflow-plugin-authz", "owner_module": "scope-catalog", "category": "security"},
    ],
    "roles": [
        {"user": "app-user@tailnet", "role": "requester", "context": "frontend", "scopes": ["frontend:orders:read", "frontend:requests:create"]},
        {"user": "readonly-admin@tailnet", "role": "authz-viewer", "context": "admin", "scopes": ["admin:dashboard:read", "admin:authz.roles:read", "admin:authz.scopes:read"]},
        {"user": "admin@tailnet", "role": "authz-admin", "context": "admin", "scopes": ["admin:dashboard:read", "admin:app:update", "admin:authz.roles:read", "admin:authz.roles:update", "admin:authz.scopes:read"]},
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
    .scope-option span {{ overflow-wrap:anywhere; }}
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
            with state_lock:
                roles = list(state["roles"])
            role_rows = "".join(f"<tr><td>{escape(r['user'])}</td><td>{escape(r['role'])}</td><td>{escape(r['context'])}</td><td>{', '.join(escape(s) for s in r['scopes'])}</td></tr>" for r in roles)
            scopes = declared_scopes()
            scope_cards = "".join(f"<div class='scope-card'><strong>{escape(s['name'])}</strong><span>{escape(s['context'])} · {escape(s['resource'])} · {', '.join(escape(a) for a in s['actions'])}</span><span>{escape(s['category'])} · {escape(s['owner_plugin'])} · {escape(s['owner_module'])}</span><p>{escape(s['description'])}</p></div>" for s in scopes)
            scope_options = "".join(f"<label class='scope-option'><input type='checkbox' name='scopes' value='{escape(s['name'])}' /><span>{escape(s['name'])}</span></label>" for s in scopes)
            self.send_html(page("Workflow Authz UI", f"""
              <h1>Role and Scope Administration</h1>
              <p>This admin contribution manages shared roles with explicit frontend and admin contexts. Scope declarations come from the application stack catalog.</p>
              <div class="scope-grid">{scope_cards}</div>
              <form method="post" action="/api/authz/roles">
                <input name="user" placeholder="User" required />
                <input name="role" placeholder="Role" required />
                <select name="context"><option value="frontend">frontend</option><option value="admin">admin</option></select>
                <div class="scope-picker">{scope_options}</div>
                <button type="submit">Assign role</button>
              </form>
              <table><thead><tr><th>User</th><th>Role</th><th>Context</th><th>Direct Scopes</th></tr></thead><tbody>{role_rows}</tbody></table>
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
        if path == "/api/admin/contributions":
            if not self.require_scope("admin:dashboard:read"):
                return
            self.send_json({"contributions": [{"id": "authz-roles", "title": "Authorization roles", "category": "security", "path": "/admin/authz", "render_mode": "iframe", "app_context": "tailnet-demo", "permissions": [{"permission": "admin:authz.roles:read", "resource": "authz.roles", "action": "read"}]}]})
            return
        if path == "/api/status":
            with state_lock:
                flag = state["flag"]
                requests = list(state["requests"])
            self.send_json({"app": "workflow-tailnet-admin-demo", "uptimeSeconds": round(time.time() - started_at, 1), "featureFlag": flag, "requests": requests, "admin": {"auth": "workflow-plugin-auth session gate modeled", "authz": {"provider": authz_provider, "mode": "declared scope role checks"}, "views": ["auth", "authz", "application", "audit"], "scopes": declared_scopes()}})
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
            self.redirect("/admin/authz")
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def do_DELETE(self):
        if urlparse(self.path).path == "/api/authz/roles":
            if not self.require_scope("admin:authz.roles:update"):
                return
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
            return {key: value if isinstance(value, list) else [value] for key, value in data.items()}
        return parse_qs(raw_body)

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
        if scope not in self.principal_scopes():
            if html:
                self.send_html(page("Forbidden", "<h1>Forbidden</h1><p>This session does not have the required scope.</p>", principal), HTTPStatus.FORBIDDEN)
            else:
                self.send_json({"error": "forbidden", "required_scope": scope}, HTTPStatus.FORBIDDEN)
            return False
        return True


def declared_scopes():
    with state_lock:
        return sorted((dict(scope) for scope in state["scopes"]), key=lambda s: s["name"])


def validate_assignment_scopes(context, scopes):
    declared = {scope["name"]: scope for scope in declared_scopes()}
    for scope in scopes:
        if scope not in declared:
            return False, f"{scope} is not declared"
        if declared[scope]["context"] != context:
            return False, f"{scope} belongs to {declared[scope]['context']}, not {context}"
    return True, ""


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
