# Safebucket on Railway

One-click template for [Safebucket](https://github.com/safebucket/safebucket) — a secure, self-hosted file sharing platform with buckets, sharing, MFA, and an audit trail.

## What gets deployed

Three services, everything wired together automatically:

| Service | Image | Purpose |
|---|---|---|
| **Safebucket** | `ghcr.io/safebucket/safebucket:latest` | The app — API + bundled web UI on one public domain |
| **Postgres** | `ghcr.io/railwayapp-templates/postgres-ssl:17` | The database (volume + daily backups) |
| **MinIO** | `ghcr.io/hmseeb/safebucket-railway-minio:latest` | File storage (volume + daily backups) |

The only things a deployer types are the **admin email** and **admin password**. Every secret (session signing key, MFA encryption key, database and storage passwords) is generated fresh per deployment.

The MinIO service is a thin wrapper over upstream MinIO that starts unattended and creates the `safebucket` bucket on first boot — Safebucket refuses to start if the bucket is missing, and Railway has no clean one-shot init containers, so the bucket creation is baked into the image instead. The MinIO service has its own public domain because the browser uploads and downloads files directly against it with presigned URLs (verified working, including CORS preflights, by `test/minio_test.sh`).

## Design choices (and how to upgrade past them)

This is the **lean** deployment: Safebucket's optional infrastructure is replaced by its built-in single-instance modes. Upstream ships these modes officially (their "lite" deployment), so nothing here is off the beaten path.

| Concern | This template | Upgrade path |
|---|---|---|
| Cache / rate limits | In-memory (`CACHE__TYPE=memory`) | Add a Valkey service, set `CACHE__TYPE=valkey` + `CACHE__VALKEY__HOSTS`/`__PASSWORD` |
| Background job queue | In-memory (`EVENTS__TYPE=memory`) | Add a NATS JetStream service, set `EVENTS__TYPE=jetstream` + `EVENTS__JETSTREAM__HOST`/`__PORT` |
| Invite / share emails | Written to files in the container, **not sent** | Set `NOTIFIER__TYPE=smtp` and add `NOTIFIER__SMTP__HOST`, `__PORT`, `__USERNAME`, `__PASSWORD`, `__SENDER`, `__TLS_MODE` |
| Audit trail storage | Files in the container — **resets on redeploy** | Add a Loki service, set `ACTIVITY__TYPE=loki` + `ACTIVITY__LOKI__ENDPOINT` |
| Replicas | Single instance only | Do the Valkey + JetStream upgrades first; memory modes don't share state across replicas |

Uploads still work correctly with the in-memory queue: Safebucket detects this mode and switches to explicit upload confirmation instead of storage event notifications.

## Creating the template on Railway

Railway templates are assembled in the dashboard composer ([docs](https://docs.railway.com/templates/create)); `railway.template.json` in this folder is the source of truth to copy from.

1. Go to [your templates page](https://railway.com/workspace/templates) → **New Template**.
2. Add the three services with the Docker image sources from the table above.
3. Copy each service's variables, domains, healthchecks, and volumes from `railway.template.json`. Variables using `${{secret(...)}}` and `${{Service.VAR}}` references paste in as-is.
4. Leave `APP__ADMIN_EMAIL` and `APP__ADMIN_PASSWORD` without defaults so deployers are prompted for them.
5. Create, deploy it once yourself to verify, then publish.

## Repo layout

- `railway.template.json` — the full template definition (services, variables, volumes, canvas layout)
- `Dockerfile.minio` + `minio-boot` — the storage image: upstream MinIO + unattended start + bucket creation
- `test/minio_test.sh` — contract test for the storage image: boots with no start command, creates the bucket, answers path-style requests, allows browser CORS preflights
- `.github/workflows/publish.yml` — builds the storage image, runs the contract test, pushes to `ghcr.io/<owner>/safebucket-railway-minio` on every push to `main`

To publish the storage image, push this folder to a GitHub repo (e.g. `hmseeb/safebucket-railway`) — the workflow handles the rest. Run the contract test locally with:

```sh
docker build -f Dockerfile.minio -t safebucket-railway-minio:test .
./test/minio_test.sh safebucket-railway-minio:test
```

## Verified vs. not

- ✅ Storage image contract-tested in CI: unattended boot, bucket creation, path-style addressing, CORS preflight for presigned browser uploads.
- ✅ The published template itself was click-deployed and verified end to end: `${{secret()}}` generation, cross-service references, admin login, bucket creation, presigned upload through the MinIO public domain, and a byte-identical presigned download — all on first boot with no manual steps beyond the two admin fields.

The template is live: https://railway.com/deploy/safebucket-template

Two things learned the hard way, already baked in:

- `PGDATA` must point at a **subdirectory** of the volume mount — Railway volumes ship with a `lost+found` directory at the root and Postgres refuses to initialize into a non-empty directory.
- On first deploy the app may restart a few times while Postgres runs its initial setup; the `ON_FAILURE` restart policy rides through it.
