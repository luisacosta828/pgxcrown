# Pgxcrown Docker Images (PostgreSQL 14–18)

Official all-in-one container images pairing each PostgreSQL major version (`14`, `15`, `16`, `17`, `18`) with its matching `postgresql-server-dev-<ver>` headers, `gcc`, **Nim 2.4.0 + Nimble**, and **pgxcrown** (`pgxtool`) ready to compile, install, and test native extensions inside the container.

## Option A: Prebuilt Images from GHCR (`v0.28.0`)

Published images live on GitHub Container Registry (`linux/amd64`, matching upstream `nimlang/nim:2.4.0`):

| PostgreSQL | Rolling Major Tag | Pinned Release Tag |
| :--- | :--- | :--- |
| **PostgreSQL 18** | `ghcr.io/luisacosta828/pgxcrown:18` / `:latest` | `ghcr.io/luisacosta828/pgxcrown:18-0.28.0` |
| **PostgreSQL 17** | `ghcr.io/luisacosta828/pgxcrown:17` | `ghcr.io/luisacosta828/pgxcrown:17-0.28.0` |
| **PostgreSQL 16** | `ghcr.io/luisacosta828/pgxcrown:16` | `ghcr.io/luisacosta828/pgxcrown:16-0.28.0` |
| **PostgreSQL 15** | `ghcr.io/luisacosta828/pgxcrown:15` | `ghcr.io/luisacosta828/pgxcrown:15-0.28.0` |
| **PostgreSQL 14** | `ghcr.io/luisacosta828/pgxcrown:14` | `ghcr.io/luisacosta828/pgxcrown:14-0.28.0` |

```bash
# Pull the PostgreSQL 17 image directly
docker pull ghcr.io/luisacosta828/pgxcrown:17

# Or pin explicitly to pgxcrown 0.28.0 on PostgreSQL 16
docker pull ghcr.io/luisacosta828/pgxcrown:16-0.28.0
```

## Option B: Build Images Locally

From the repository root:

```bash
# Build all versions (pgxcrown:14, pgxcrown:15, pgxcrown:16, pgxcrown:17, pgxcrown:18 + latest)
./docker/build.sh

# Build a single PostgreSQL version
./docker/build.sh 18
```

By default, `Dockerfile` installs `pgxcrown` from your local repository source (`PGXCROWN_SOURCE=local`). To install from the remote Nimble registry instead:

```bash
PGXCROWN_SOURCE=nimble ./docker/build.sh 17
```

## Quick Start (Try Pgxcrown in 30 Seconds)

Start a container directly from GHCR (replace with `pgxcrown:17` if you built locally):

```bash
docker run -d --name pgxcrown-17 -e POSTGRES_PASSWORD=postgres -p 5417:5432 ghcr.io/luisacosta828/pgxcrown:17
```

Or with Docker Compose:

```bash
docker compose -f docker/compose.yaml up -d pgxcrown-17
```

Open a shell inside the container, scaffold a native Nim extension, compile it with PostgreSQL 17's native headers, install it, and test it in `psql`:

```bash
docker exec -it pgxcrown-17 bash

# Optional: update pgxcrown anytime inside the container via Nimble
nimble refresh && nimble install -y pgxcrown

# Create, build, and install a sample extension
pgxtool init
pgxtool create-type myint --base-type int
pgxtool build-extension myint
./pgx/myint/src/install.sh

# Test directly in PostgreSQL
psql -U postgres -c 'CREATE EXTENSION myint; SELECT '\''42'\''::myint;'
```

## Developing with Mounted Host Code

Mount an existing `pgxtool` workspace directly to `/workspace/pgx`, or mount an individual extension folder at `/src/my_extension` and initialize + link it inside the container:

```bash
docker run -d --name pgxcrown-17 \
  -e POSTGRES_PASSWORD=postgres \
  -v "$(pwd)/my_extension:/src/my_extension" \
  pgxcrown:17

docker exec -it pgxcrown-17 bash -c '
  pgxtool init
  ln -sfn /src/my_extension /workspace/pgx/my_extension
  pgxtool build-extension my_extension
  /workspace/pgx/my_extension/src/install.sh
'
```

## Automated SQL Regression Tests (`pgxtool test`)

From the host (without needing PostgreSQL headers locally), `pgxtool test` resolves the sandbox image automatically:

- Uses local `pgxcrown:<version>` or already-pulled `ghcr.io/luisacosta828/pgxcrown:<version>` if present.
- In a repository checkout with `docker/Dockerfile`, builds `pgxcrown:<version>` automatically when missing.
- In standalone `nimble install -y pgxcrown` setups (where `docker/` is not packaged), automatically pulls `ghcr.io/luisacosta828/pgxcrown:<version>`.
- Respects `PGXCROWN_IMAGE` to force a custom registry/repository (e.g. `PGXCROWN_IMAGE=ghcr.io/luisacosta828/pgxcrown pgxtool test analytics --pg 17`).

Once running, `pgxtool` copies your project folder inside, compiles & installs natively, and executes `tests/sql/*.sql` (pass `<name>`, `./path`, or run with no project argument inside the extension directory; add `--pg <v>`, `--all`, `--bless`, or `--local` when already inside the container):

```bash
# Test against a specific PostgreSQL version (copies project into pgxcrown:<ver> and compiles inside)
pgxtool test my_ext --pg 16
pgxtool test ./my_ext --pg 17 --bless

# Run directly inside a project directory (detects src/main.nim or tests/sql)
cd my_ext && pgxtool test --pg 14

# Run across PostgreSQL 14, 15, 16, 17, and 18
pgxtool test my_ext --all
```

Inside a running container, `pgxtool test` also works against the container's local PostgreSQL (`--local` or automatic fallback when Docker is unavailable).
