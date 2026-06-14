# Testing Avalanche with OpenBench

OpenBench is a distributed SPRT testing framework used to validate engine changes. This document covers setting up and running an OpenBench instance for Avalanche.

## Overview

OpenBench replaces manual fastchess SPRT runs. Workers (machines with the engine) connect to a central server, pull test workloads, run games, and report results back. The server aggregates LLR and stops the test when the SPRT bound is reached.

## Server Setup

### Prerequisites

- Python 3.13+ via `uv`
- The `OpenBench/` directory (clone it from https://github.com/AndyGrant/OpenBench)

### First-time installation

```bash
cd OpenBench

# Create venv with latest Python and install dependencies
uv venv --python 3.13 .venv
uv pip install -r requirements.txt

# Initialize the SQLite database
uv run python manage.py migrate

# Create the admin superuser (set your own password)
DJANGO_SUPERUSER_PASSWORD=<password> uv run python manage.py createsuperuser \
    --noinput --username admin --email admin@localhost

# Enable the account (required before first login)
uv run python manage.py shell << 'EOF'
from django.contrib.auth.models import User
from OpenBench.models import Profile
user = User.objects.get(username='admin')
profile, _ = Profile.objects.get_or_create(user=user)
profile.enabled = profile.approver = True
profile.save()
EOF
```

### Running the server

```bash
cd OpenBench
uv run python manage.py runserver
# → http://localhost:8000/
```

For persistent/production use, run behind gunicorn instead:

```bash
uv pip install gunicorn
uv run gunicorn OpenSite.wsgi:application --bind 127.0.0.1:8000 --workers 3
```

Stop gracefully with `pkill -TERM gunicorn` (never SIGKILL — corrupts PGN archives).

### Creating additional user accounts

1. Go to `http://localhost:8000/register/` and create an account.
2. Log into the [Admin panel](http://localhost:8000/admin/) with superuser credentials.
3. Click **Users**, open the new account, check **Staff status** and **Superuser status**, save.
4. Enable via the shell (same as above, substituting the new username).

## Engine Configuration

The Avalanche engine config lives at `OpenBench/Engines/Avalanche.json`. Key fields:

| Field | Value | Notes |
|-------|-------|-------|
| `nps` | 2,000,000 | Reference NPS on a Ryzen 3700x-class CPU — recalibrate after testing |
| `source` | `https://github.com/SnowballSH/Avalanche` | Used for sidebar links |
| `build.path` | `""` | Makefile is at repo root |
| `build.compilers` | `["zig"]` | Worker must have `zig` in `PATH`; the Makefile calls `zig build` directly |
| `build.cpuflags` | `[]` | No minimum CPU requirement — all instruction sets accepted |
| `build.systems` | `["Linux", "Windows", "Darwin"]` | All platforms supported |

### Preset time controls

| Preset | Options | Time control |
|--------|---------|--------------|
| STC | `Threads=1 Hash=8` | `10.0+0.1` |
| LTC | `Threads=1 Hash=64` | `60.0+0.6` |
| SMP STC | `Threads=4 Hash=32` | `10.0+0.1` |
| SMP LTC | `Threads=4 Hash=128` | `60.0+0.6` |

Simplification presets use bounds `[-3.00, 0.50]` instead of the default `[0.00, 3.00]`.

## Running a Worker

Workers are separate machines that connect to the server and run games.

```bash
cd OpenBench/Client

# Install client dependencies (same venv works)
uv pip install -r ../requirements.txt
uv pip install py-cpuinfo   # required by worker.py, not in requirements.txt

# Connect to the server (--nsockets is number of physical CPU sockets, usually 1)
uv run python worker.py \
    --server http://localhost:8000 \
    --username admin \
    --password <password> \
    --threads 8 \
    --nsockets 1
```

The worker will:
1. Pull its NPS by running `./engine bench`
2. Download the test's source, compile with `make EXE=...`
3. Run games via fastchess and report results back

### Worker requirements

- `zig` must be in `PATH` (needed to compile Avalanche)
- Any CPU is accepted (`cpuflags` is empty); Zig compiles natively on each worker
- `fastchess` is auto-downloaded by the client

## Creating a Test

1. Log in at `http://localhost:8000/`
2. Click **Create Test** in the sidebar
3. Select **Avalanche** as the engine
4. Click a preset button (**STC** or **LTC**) to auto-fill fields
5. Set **Dev Branch** to the branch/commit to test
6. Set **Base Branch** to the reference (usually `master`)
7. Set **Dev Bench** and **Base Bench** to the expected node counts
8. Submit

SPRT bounds default to `[0.00, 3.00]` at 95% confidence. A test passes when LLR > 2.94; fails when LLR < -2.94.

## genfens Interface

For **Datagen workloads** on OpenBench, the engine implements the `genfens` UCI command:

```
./Avalanche "genfens <N> seed <S> book <None|path>" "quit"
```

This prints `N` opening FENs to stdout in the format:
```
info string genfens <fen>
```

OpenBench uses these FENs as starting positions for self-play data generation. The seed `S` is a 64-bit value (upper 32 bits = workload ID, lower 32 bits = book offset) and should be used to seed the engine's PRNG for reproducibility.

## Calibrating NPS

The `nps` value in `Engines/Avalanche.json` should match the bench NPS on the reference machine (Ryzen 3700x or equivalent). To measure:

```bash
./zig-out/bin/Avalanche bench
# Output: 35032097 nodes 2490136 nps
```

Update `"nps"` in `Engines/Avalanche.json` accordingly, then restart the server. Workers scale their time controls proportionally to this value.

## Recurrent Maintenance

```bash
# Backup the database
cd OpenBench && uv run python manage.py dumpdata > backup_$(date +%Y%m%d).json

# Clean up result/machine/log objects (safe to delete anytime)
uv run python manage.py shell << 'EOF'
from OpenBench.models import Result, Machine, LogEvent, PGN
Result.objects.all().delete()
Machine.objects.all().delete()
LogEvent.objects.all().delete()
PGN.objects.all().delete()
EOF
# Then delete Media/event* files
```
