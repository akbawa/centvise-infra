# Centvise Manager Infrastructure

Docker Compose deployment configuration for the `centvise-app` frontend and
backend. MongoDB runs directly on the VPS and is not included in Compose.

## Deployment model

- `stag` deploys the `staging-latest` backend and frontend image tags.
- `prod` deploys the `latest` backend and frontend image tags.
- A deployment always checks GHCR, pulls both tags, and force-recreates both
  containers from the pulled images.
- No release file, version argument, or application source checkout is needed
  on the VPS.

The two environments use independent Compose project names, ports, networks,
configuration files, and persistent file roots.

## VPS layout

```text
/opt/centvise-manager/                 # non-Git manager root
├── data/                              # persistent data; never in Git
│   ├── stag/backend-files/
│   └── prod/backend-files/
└── infra/                             # the only Git repository
    ├── docker/
    ├── environments/
    └── scripts/
```

All commands in this document run from `/opt/centvise-manager/infra`.

`docker.env` contains only values consumed by Docker Compose or the deployment
script; it is not passed into the application container. `backend.env` contains
only values read by the Centvise backend for the enabled production features.
Optional debug flags, migration switches, Firebase migration settings, contact
email overrides, and Google Cloud Storage credentials are intentionally omitted.

The backend resolves runtime-generated files below
`CENTVISE_STORAGE_ROOT=/var/lib/centvise`. MongoDB holds relative logical
paths, so the VPS source directory can move later without rewriting database
records.

## Configure an environment on the VPS

Create the environment files from the example if they are not already present:

```bash
cp -R environments/example environments/stag
# Or, for production:
cp -R environments/example environments/prod
```

Edit `environments/<env>/docker.env`:

- Set `ENV_NAME` to exactly `stag` or `prod`.
- Set `PROJECT_ROOT` to the absolute manager directory on the VPS, such as
  `/opt/centvise-manager`. It points to the parent of `infra/` and `data/`.
- Set unused host ports and a non-conflicting private Docker subnet.
- Set `BACKEND_UID` and `BACKEND_GID` to the numeric identity that owns the
  persistent files. The application containers still run as non-root.
- Set the GHCR username and `GHCR_PULL_TOKEN`.
- Use `staging-latest` tags for `stag` and `latest` tags for `prod`.

`GHCR_PULL_TOKEN` must be a GitHub container-registry token or PAT allowed to
read the private packages (`read:packages`). An SSH deploy key cannot
authenticate `docker login`. Keep this token pull-only and do not grant package
write or delete permissions.

Edit `environments/<env>/backend.env` and replace all sample URLs, MongoDB
credentials, and application secrets. Keep these container values unchanged:

```dotenv
HOST=0.0.0.0
PORT=4000
STORAGE_MODE=local
CENTVISE_STORAGE_ROOT=/var/lib/centvise
```

`STORAGE_MODE=local` is required by the current backend. Its PDF storage code
defaults to Google Cloud Storage when this value is absent, while `local` makes
it read and write through the persistent `/var/lib/centvise` bind mount.

Use `host.docker.internal` in `MONGO_URI`. Compose maps that name to the Docker
host on Linux. MongoDB must listen on an interface reachable from the Docker
network; restrict it with the VPS firewall and a least-privilege MongoDB user.

Protect both files because they contain credentials:

```bash
chmod 600 environments/stag/docker.env environments/stag/backend.env
chmod 600 environments/prod/docker.env environments/prod/backend.env
```

Real environment `.env` files are ignored by the infrastructure repository.
The `data/` directory is outside that repository and must never be initialized
as a Git repository or committed.
The GHCR pull token is used by the deployment script only; it is not injected
into either application container.

## Deploy

Images must already exist in GHCR under the repositories configured in
`docker.env`. From the deployment-manager directory, run one command:

```bash
./scripts/deploy-ghcr.sh --env stag
./scripts/deploy-ghcr.sh --env prod
```

The positional form is also supported:

```bash
./scripts/deploy-ghcr.sh stag
```

For every run, the script:

1. Accepts only `stag` or `prod`.
2. Reads the pull-only GHCR token from that environment's `docker.env`.
3. Validates Compose and prepares the persistent child directories.
4. Runs `docker compose pull --policy always` for both images.
5. Force-recreates the backend, waits for health, then force-recreates the
   frontend and waits for health.
6. Logs out of GHCR when it exits.

Docker may reuse unchanged image layers, which is safe and efficient, but it
always checks the registry tag before deployment. Force recreation ensures the
running containers use the resolved image even when the moving tag name did
not change.

The React API URL is compiled into the frontend image. The staging workflow
must build it with the staging `REACT_APP_BASE_URL`; the production workflow
must build `latest` with the production URL.

## Image publication

The application repository's staging GitHub Actions workflow publishes
separate backend and frontend images with `staging-latest`. Both Dockerfiles
run the application as non-root users.

Production deployment expects the same repositories to contain a `latest`
tag built with production frontend variables. Do not run the production
deployment until those tags are published by a production build workflow.

## Persistent files on the VPS

For a manager installed at `/opt/centvise-manager`, files live at:

```text
/opt/centvise-manager/data/stag/backend-files/
/opt/centvise-manager/data/prod/backend-files/
```

Each environment directory is mounted once at `/var/lib/centvise` inside its
backend container. Its owner must match `BACKEND_UID:BACKEND_GID` from that
environment's `docker.env`. If necessary, prepare it once as an administrator:

```bash
sudo mkdir -p /opt/centvise-manager/data/stag/backend-files
sudo chown -R 10001:10001 /opt/centvise-manager/data/stag/backend-files
sudo chmod 750 /opt/centvise-manager/data/stag/backend-files
```

The first deployment creates all currently used child directories. The
backend container is read-only except for this bind mount and a bounded `/tmp`
tmpfs. Back up `backend-files` together with MongoDB for a consistent restore.

For the first production migration, stop the old backend and copy every
existing runtime directory into the production root without renaming its
children. For example:

```bash
rsync -a /path/to/current/server/uploads/ \
  /opt/centvise-manager/data/prod/backend-files/uploads/
rsync -a /path/to/current/server/local_payroll_pdf/ \
  /opt/centvise-manager/data/prod/backend-files/local_payroll_pdf/
rsync -a /path/to/current/server/local_report_pdf/ \
  /opt/centvise-manager/data/prod/backend-files/local_report_pdf/
rsync -a /path/to/current/server/local_support_chat/ \
  /opt/centvise-manager/data/prod/backend-files/local_support_chat/
```

Repeat for `payrollpdfs`, `remittanceReports`, `combined_pdfs`, and
`temp_pdfs` when they exist. No MongoDB path rewrite is required. Keep the old
directories until file viewing, downloading, generation, and chat attachments
have been verified.

## Restart without pulling images

Use this only to restart the currently deployed images:

```bash
./scripts/restart-services.sh --env stag --backend
./scripts/restart-services.sh --env stag --frontend
./scripts/restart-services.sh --env stag --all
```

After changing Compose or environment settings, recreate the current
containers without pulling:

```bash
./scripts/restart-services.sh --env stag --all --force-recreate
```

To deploy newly published images, use `deploy-ghcr.sh`, not the restart script.

## Useful commands

```bash
docker compose \
  --env-file environments/stag/docker.env \
  -f docker/docker-compose.yml ps

docker compose \
  --env-file environments/stag/docker.env \
  -f docker/docker-compose.yml logs -f
```
