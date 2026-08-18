# Decision log

## Main trade-offs

- **Python / FastAPI** — fast to write, `psycopg` + `boto3` are the obvious choices, no
  build step.
- **Postgres, in-cluster, not managed.** No cloud spend/signup in the time budget. Costs:
  no HA, no automated backups, no patching — would use RDS/Cloud SQL for real.
- **MinIO, in-cluster** — S3-API-compatible, so `boto3` code is identical to real S3.
- **Secrets: Vault (dev mode) + Agent Injector, not K8s `Secret`s, not encrypted-in-git.**
  Considered and rejected SOPS/age — encrypted secrets in git are still secrets in git,
  plus a key-management problem. Every workload gets its own ServiceAccount → Vault role
  → policy scoped to only its own KV path. `kubectl get secrets` shows zero app
  credentials, verified.
- **Vault dev mode is a real gap, not a footnote.** Verified live: the root token
  (`root`, a public default) grants any pod full access over the network — no
  `kubectl exec` into `vault-0` needed. A `NetworkPolicy` wouldn't stop this even if one
  existed (also verified: `kind`'s default CNI, `kindnet`, enforces none at all) because
  all three workloads legitimately need network access to Vault — the token is the
  problem, not the network path. Standard fix regardless of dev/prod mode: retire the
  root token after setup. We don't — it stays live through every script here.
- **The app gets its own scoped credentials, not root/superuser copies.** First pass
  reused Postgres's password and MinIO's root key directly for the app — Vault's
  policies looked correct (app's identity genuinely denied on the other paths) but were
  pointless, since the app's own secret already held full copies of both. Fixed: a
  dedicated `app_user` Postgres role, DML only (Postgres 15+ revokes schema `CREATE`
  from non-owners by default, so table creation moved to the superuser-run `initdb`
  script instead of app startup); a dedicated MinIO IAM user scoped to one bucket, no
  admin/create rights. Both confirmed live via denied actions on the restricted ops.
- **Credential files, not env vars, at the K8s level** — `kubectl exec -- env` shows
  none of the app's three secrets (confirmed; `exec` uses the pod's declared spec env,
  not a running process's own). They do end up in the app's own process environment via
  its startup `source` (confirmed via `/proc/1/environ`) — "not in `kubectl exec env`"
  is accurate, "never an env var" would be overstating it.
- **MinIO's access key is a stable, non-secret identifier** (like `DB_USER`), not
  regenerated per run — only the secret rotates. Confirmed `mc admin user add`/`policy
  attach` are idempotent upserts, so this doesn't orphan old IAM users on re-runs.
- **Static KV secrets, not Vault's dynamic DB-secrets engine** — deferred, see design
  position.
- **MinIO's official image ships no shell** (`ubi9-micro` base) — runs the binary
  directly via `command:`, using its native `MINIO_ROOT_USER_FILE`/`_PASSWORD_FILE`
  convention instead of a shell wrapper.
- **Single namespace, single-node kind cluster** — fewer moving parts; identity/policy
  boundaries live in Vault, not namespace isolation.

## What I deliberately did not do in the two hours

- No `NetworkPolicies` (and confirmed they wouldn't be enforced on this CNI anyway).
- No RBAC restricting `kubectl exec`/log access — moot on a single-user local cluster,
  the real blast-radius boundary on a shared one.
- No resource limits, Pod Security Standards, or HPA.
- No Ingress/TLS — `kubectl port-forward` only.
- No real migration tool — one `CREATE TABLE` in the `initdb` script.
- No connection pooling — a new `psycopg` connection per request.
- Vault audit logging not enabled.
- Root Vault token never retired after setup.
- MinIO IAM provisioning is an imperative script (`mc` via `kubectl exec`), not
  declarative (e.g. Terraform) — but confirmed idempotent and safe to re-run.

## The part I knew least about, how I used AI, and where I overrode it

- **Least dove into: the Python app itself** (`main.py`/`db.py`/`storage.py`). I steered
  the Kubernetes/Vault/secrets side closely, but let AI write the FastAPI service
  largely on its own from just the API shape, and reviewed it at a summary level rather
  than line-by-line.
- **Where that showed**: a review pass caught the app committing the Postgres row
  before writing to MinIO with no rollback (a MinIO outage would leave a permanent
  orphaned row), and MinIO error handling that treated any error — including a real
  permissions failure — as "not found." I didn't catch either myself; I directed the
  fix and then insisted on live proof before accepting it — forced a MinIO outage and
  confirmed the row was actually rolled back.
- **Where I overrode AI at the architecture level**: its first pass at git-safe secrets
  was SOPS/age — encrypt the values, commit the ciphertext. I rejected that; encrypted
  secrets in git are still secrets in git with a key-management problem bolted on, and
  I pushed for a real secret store (Vault) instead, even though it was more work.

## Design position

If this had to run for real — multiple teams, production traffic, a serious security bar
— the first three things I'd change:

1. **Replace Vault dev mode with a production-grade secret store** — HA Vault or a
   managed cloud secret manager, paired with real workload identity federation
   (IRSA/Workload Identity), and the root token retired after bootstrap either way.
2. **Move Postgres to a managed service** for HA/backups/patching, and adopt dynamic,
   short-lived database credentials instead of the static ones used here.
3. **Harden the delivery boundary**: NetworkPolicies (on a CNI that enforces them),
   RBAC restricting `exec`/log access on pods holding secrets, and CI/CD-driven deploys
   instead of manual `kubectl apply`.

What I'd deliberately **not** change: the core pattern — a workload's own identity
authenticates to a policy-scoped secret store, and the app never touches a static
credential file, manifest, or git repo. That scales as-is; it needs a hardened, managed
version, not a different architecture.
