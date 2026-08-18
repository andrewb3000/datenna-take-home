# Datenna Take-Home — small service on Kubernetes

A FastAPI service that reads/writes a row in Postgres and puts/gets an object in MinIO
(S3-compatible blob storage), running on a local `kind` cluster. Every credential —
Postgres's own admin password, MinIO's root credentials, and the app's own DB/MinIO
credentials — is fetched from HashiCorp Vault at pod startup via the Vault Agent
Injector, authenticated by each workload's own Kubernetes ServiceAccount. No credential
is ever a Kubernetes `Secret` object, a manifest value, or anything committed to git.

The app never receives a copy of Postgres's superuser password or MinIO's root
credential. It connects to Postgres as `app_user`, a role with only
`SELECT/INSERT/UPDATE/DELETE` on the `items` table (created by Postgres's own `initdb`
bootstrap, running as the superuser — verified live to be denied `CREATE TABLE`). It
talks to MinIO with a dedicated IAM access key, provisioned once via `mc` and scoped to
`GetObject`/`PutObject`/`ListBucket` on the `items` bucket only (verified live to be
denied both admin actions and bucket creation).

See `DECISIONS.md` for the trade-offs, deliberate omissions, and design position.

## Prerequisites

`kind`, `kubectl`, `helm`, `docker` (a running daemon), `openssl`. All confirmed working
locally; nothing here requires a cloud account or spends money.

## Run it

```bash
./scripts/01-cluster.sh      # create the kind cluster, install Vault (server + Agent Injector)
./scripts/02-vault-setup.sh  # configure k8s auth, 3 least-privilege policies/roles, write 3 KV secrets
./scripts/03-deploy.sh       # deploy Postgres, MinIO, build+load the app image, deploy the app
./scripts/demo.sh            # prove the credential story + a full POST/GET round trip
```

`demo.sh` walks through, in order:
1. `kubectl get secrets` — no application credentials exist as native Secrets (the one
   `sh.helm.release.v1.vault.v1` entry you'll see is Helm's own internal release
   bookkeeping, not a credential).
2. `cat`-ing the Vault-rendered credential file from inside the app's and Postgres's own
   pods — it only exists on that pod's filesystem.
3. A least-privilege check: the app's Vault identity can read `secret/app` but is denied
   on `secret/minio`.
4. A functional round trip: `POST /items` writes to Postgres and MinIO, `GET
   /items/{id}` reads both back.

Tear down with `./scripts/teardown.sh` (deletes the kind cluster).

## API

- `POST /items {"value": "..."}` → inserts a row into Postgres, uploads a matching JSON
  blob to MinIO, returns `{id, db, storage}`.
- `GET /items/{id}` → returns the Postgres row and the MinIO object together.
- `GET /healthz` → checks DB and MinIO connectivity.

## Layout

```
app/       FastAPI service (main.py, db.py, storage.py) + Dockerfile
k8s/       Namespace, ConfigMap, and per-workload manifests (ServiceAccount + Deployment
           + Service, with Vault Agent Injector annotations)
vault/     Least-privilege Vault HCL policies (one per workload) and the MinIO IAM
           bucket policy used to provision the app's scoped MinIO user
scripts/   Ordered setup/deploy/demo/teardown scripts
```
