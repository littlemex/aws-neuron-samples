# Neuron Explorer — operator runbook

`--enable-explorer` opts the single-node stack into installing Neuron
Explorer as a long-running systemd service fronted by an additional
`/explorer/` location on the existing nginx site.  Same auth path,
same SSM port-forward, same CloudFront distribution as code-server.

## What gets installed

| Path | Purpose |
|---|---|
| `/etc/systemd/system/neuron-explorer.service` | Long-running `neuron-explorer view` process owned by `coder` |
| `/etc/systemd/system/neuron-explorer-rewrite.service` | One-shot post-start unit that rewrites the SPA bundle for same-origin URLs |
| `/etc/nginx/snippets/explorer-location.conf` | nginx fragment included from the code-server site |
| `/etc/nginx/conf.d/cf-user-map.conf` | http{}-scope `cf_user` cookie -> `$cf_user` map |
| `/opt/neuron-explorer/rewrite-explorer-bundle.py` | Bundle rewriter (Python 3, stdlib only) |
| `/opt/neuron-explorer/capture-and-upload.sh` | One-command capture + push helper for end users |
| `/var/lib/neuron-explorer/data/` | Internal state owned by the unit |
| `/var/lib/neuron-explorer/seed/` | Pre-loaded profile dir consumed by `view -d` |
| `/var/lib/neuron-explorer/assets/` | Rewritten SPA bundle, served by nginx |
| `/var/lib/neuron-explorer/rewriter.status` | Plain-text rewriter state, exposed at `/explorer/health` |
| `/var/lib/neuron-explorer/bundle.sha256` | sha256 of the upstream bundle the rewriter last processed (idempotency key) |
| `/var/lib/neuron-explorer/logs/explorer.log` | Stdout/stderr capture of the `view` daemon |

## Two routing surfaces

The service binds two TCP ports under a single PID:

| Port | Surface |
|---|---|
| `127.0.0.1:8081` | UI shell + static assets (`-p` flag) |
| `127.0.0.1:3002` | REST API at `/api/v1/*` (fixed by the binary as of 2.30) |

The nginx fragment exposes them through three routes:

| Public path | nginx target | Notes |
|---|---|---|
| `/explorer/*` | `http://127.0.0.1:8081/` | UI shell.  `sub_filter` rewrites the inlined API URL literal so the SPA fetches `/explorer/api/v1/*` and asset hrefs use `/explorer/assets/*` |
| `/explorer/assets/*` | `alias /var/lib/neuron-explorer/assets/` with `try_files` | Rewritten bundle served as a static file; falls back to the upstream bundle if the rewriter has not finished yet |
| `/explorer/api/*` | `http://127.0.0.1:3002/api/` | REST API.  `X-User-Id` header is filled from the `cf_user` cookie, falling back to the Explorer display name for direct SSM users |
| `/explorer/health` | `alias /var/lib/neuron-explorer/rewriter.status` | Plain-text status; first line is `OK <sha>` or `DEGRADED <reason>` |

## Why the bundle rewriter exists

The Explorer SPA bundle ships URL-construction code that branches on
whether `window.NEURON_API_URL` contains the substring `localhost`.
When the SPA is served from a non-localhost origin (e.g. behind nginx
+ CloudFront), the production branch builds absolute URLs against a
bare hostname `explorer` with a `/prod/api/...` prefix, neither of
which resolves on a same-origin sub-path deployment.  The browser
emits `https://explorer/prod/api/v1/...` and the request fails with
`ERR_NAME_NOT_RESOLVED`.

`scripts/rewrite-explorer-bundle.py` runs once per (re-)deploy via
`neuron-explorer-rewrite.service`.  It fetches every chunk the SPA
shell references (`/assets/*.js`), applies a regex substitution table
(see comments at the top of the script), writes the rewritten chunks
to `/var/lib/neuron-explorer/assets/`, and stamps a status file.
nginx then serves the rewritten chunks via `alias` + `try_files`.

The rewriter is idempotent on the upstream bundle's aggregate sha256:
re-running on the same bundle is a no-op.  When the upstream bundle
changes (Neuron SDK upgrade), the sha256 marker miss triggers a fresh
rewrite, asserts every required substitution still hits, and falls
back to the unmodified bundle (`DEGRADED` state) if any pattern fails
— the SPA still loads, but profile detail may emit broken URLs.
`/explorer/health` exposes the state for smoke tests and monitoring.

## Routing through CloudFront + ALB

`alb-backend-stack.ts` adds two `AlbAppRoute` entries pointing at the
nginx port (`80`).  Splitting UI and API into separate listener rules
keeps WAF / cache policies independent in the future.

`cloudfront-frontend-stack.ts` registers `/explorer/*` as an additional
cache behavior with `CACHING_DISABLED` and the same HMAC viewer-request
function as the rest of the surface.  A user with a valid `cf_session`
cookie reaches Explorer with the same Cognito identity that code-server
uses.

## Deploy

```bash
bash scripts/deploy.sh \
    --stack-name neuron-ws \
    -r sa-east-1 \
    --enable-explorer
```

The flag is idempotent.  Re-running on an existing stack only re-applies
`scripts/setup-explorer.sh`; the systemd unit is `Restart=on-failure`,
nginx is reloaded (not restarted), and the include directive in
`/etc/nginx/sites-enabled/code-server` is patched only if missing.

To override the human-friendly name shown in the UI:

```bash
bash scripts/deploy.sh ... --explorer-display-name nki-bootcamp
```

## Re-apply on a running instance

```bash
AWS_REGION=sa-east-1 bash scripts/setup-explorer-wrapper.sh \
    -i i-0123456789abcdef0 \
    --explorer-display-name nki-bootcamp \
    --clean-state
```

`--clean-state` discards `/tmp/task-state-*.json` so every step re-runs.
Drop the flag for normal idempotent re-application.

## Capture + upload from the trn2 host

```bash
# On the trn2 host:
sudo -u coder /opt/neuron-explorer/capture-and-upload.sh \
    --entry /home/coder/your-kernel-driver.py \
    --name kernel-v1 \
    --uploader $USER

# Or, reuse a pre-captured profile directory:
sudo -u coder /opt/neuron-explorer/capture-and-upload.sh \
    --skip-capture \
    --profile-dir /work/profile-out \
    --name baseline-v1
```

The wrapper sets `NEURON_RT_INSPECT_*` before the entry script runs,
auto-discovers the `<host>_pid_<pid>/<run-id>/` directory the runtime
emits, and calls `neuron-explorer upload --profile-directory ...`
against `localhost:3002`.

## Pre-seed a sample profile (optional)

The systemd unit starts `view -d /var/lib/neuron-explorer/seed`.  An
empty seed directory makes the binary loop with `no device or system
profiles found` (it still answers HTTP, but the UI surfaces only
profiles that were uploaded later).

To pre-seed at deploy time, drop a captured profile bundle on EFS and
copy it into the seed directory before the unit starts:

```bash
sudo cp -r /work/explorer-seed/. /var/lib/neuron-explorer/seed/
sudo chown -R coder:coder /var/lib/neuron-explorer/seed
sudo systemctl restart neuron-explorer
```

A captured bundle contains at minimum `*.ntff`, `*.neff`, and
`trace_info.pb`.

## Smoke check from the laptop

```bash
# Open an SSM port-forward to the nginx host port.
aws ssm start-session \
    --region sa-east-1 \
    --target i-0123456789abcdef0 \
    --document-name AWS-StartPortForwardingSession \
    --parameters '{"portNumber":["80"],"localPortNumber":["18080"]}'

# In another terminal:
curl -sI http://localhost:18080/explorer/                         # 200
curl -s    http://localhost:18080/explorer/health | head -1       # OK <sha>
curl -s -o /dev/null -w '%{http_code}\n' \
    http://localhost:18080/explorer/api/v1/profiles/search        # 200

# Then point your browser at http://localhost:18080/explorer/
```

The same paths are reachable through the CloudFront distribution
once Cognito login is complete.

## Cognito session lifetime

Default is **86400 seconds (1 day)**.  Override at deploy time:

```bash
bash scripts/deploy.sh ... --session-ttl 28800   # 8 hours
bash scripts/deploy.sh ... --session-ttl 3600    # 1 hour
bash scripts/deploy.sh ... --session-ttl 604800  # 1 week
```

The TTL is mirrored on both the HMAC payload (`exp` claim) and the
Set-Cookie `Max-Age`, so they always agree.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `502 Bad Gateway` on `/explorer/` | systemd unit failed to start | `journalctl -u neuron-explorer -n 60` and `tail /var/lib/neuron-explorer/logs/explorer.log`; the most common reason is an empty seed dir |
| `/explorer/health` shows `DEGRADED` | A regex substitution matched zero times in the new upstream bundle | The rewriter falls back to the unmodified bundle (fail-open).  Inspect status, identify the new URL-build shape, add a substitution to `SUBSTITUTIONS` in `rewrite-explorer-bundle.py`, redeploy |
| API returns `400 x-user-id header is missing` | `cf_user` cookie not set and the map default is empty | Confirm `/etc/nginx/conf.d/cf-user-map.conf` exists and `default <display-name>` is set |
| `/explorer/assets/*` returns 403 | Rewritten files were written 600 instead of 644 | The script forces 644 on `os.chmod` after `mkstemp`; re-run with `--force` to regenerate |
| ALB target unhealthy on `/explorer/api/v1/profiles/search` | seed dir missing or lost on Spot stop | Move seed under EFS (e.g. `/mnt/efs/.../explorer-seed/`) and symlink it into `/var/lib/neuron-explorer/seed` so it survives `instance stop / start` |
| CloudFront returns 504 on slow profile loads | ALB idle timeout too short for very large profiles | Bump `idleTimeout` on the ALB construct (default 60s); 300s is safe |

## E2E coverage

`e2e/tests/explorer.spec.ts` is part of the Playwright suite:

```bash
cd e2e
CF_BASE_URL=https://dXXXX.cloudfront.net \
TEST_USER_EMAIL=... \
TEST_USER_PASSWORD=... \
npx playwright test --grep '@screenshots'
```

The `@screenshots` tag captures full-page PNGs under
`e2e/artifacts/explorer-screenshots/` for the operator runbook.
