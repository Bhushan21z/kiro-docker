# kiro-docker

Run [Kiro CLI](https://kiro.dev) **headless and autonomously inside an isolated
Docker container**. Bring your own Kiro API key, give it a prompt, point it at a
project directory, and let it do the work: run tests, fix bugs, review code,
write docs, automate chores. The agent installs whatever tools it needs inside
the container, not on your machine.

```bash
./run.sh "Install dependencies, run the tests, and fix anything that fails"
```

## Why a container?

Kiro runs with `--trust-all-tools`, meaning it executes shell commands and edits
files without asking. That is what makes unattended automation possible, and
it is also why you want it sandboxed. In the container, Kiro:

- runs as root in a throwaway Ubuntu 24.04 environment (`--rm`, nothing persists)
- can `apt`/`pip`/`npm` install anything without touching your host
- can only see the single directory you mount at `/workspace`

## Requirements

- Docker (Desktop or Engine), running
- A Kiro API key (starts with `ksk_`), from your Kiro account
- bash (macOS, Linux, or WSL)

## Quick start

```bash
# 1. Clone
git clone https://github.com/<your-user>/kiro-docker.git
cd kiro-docker

# 2. Add your API key
cp .env.example .env
$EDITOR .env            # set KIRO_API_KEY=ksk_...

# 3. Run a task against a project (the image is built automatically on first run)
./run.sh -d /path/to/your/project "Run the tests and summarize the results"
```

You can also export the key instead of using a `.env` file:

```bash
export KIRO_API_KEY=ksk_...
```

## Usage

```
./run.sh [options] "<prompt>"
./run.sh [options] -f PROMPT_FILE
```

| Option | Description |
| --- | --- |
| `-d DIR` | Project directory to mount at `/workspace` (default: current dir) |
| `-f FILE` | Read the prompt from a file |
| `-m MODEL` | Model id to use (default: Kiro's default) |
| `-r` | Mount the project **read-only**, so the agent cannot change your files |
| `-n NET` | Docker network mode (Kiro needs network access to reach its API) |
| `-R` | Raw mode: send your prompt as-is, without the autonomy preamble |
| `-h` | Help |

Examples:

```bash
# Work on the current directory
./run.sh "Add unit tests for the auth module"

# Work on another project
./run.sh -d ~/code/my-api "Upgrade dependencies and make sure the build passes"

# Long prompt from a file
./run.sh -f examples/fix-failing-tests.md

# Safe analysis: agent can read the project but not modify it
./run.sh -r "Review this codebase for security issues and describe them"

# Choose a model
./run.sh -m claude-sonnet-4.5 "Refactor src/ for readability"
```

Ready-made prompts live in [`examples/`](examples/).

### Using `make`

```bash
make build
make run PROMPT="Run the tests" DIR=~/code/my-api
```

### Using Docker Compose

```bash
PROJECT_DIR=~/code/my-api PROMPT="Run the tests" docker compose run --rm kiro
```

### Using plain `docker`

```bash
docker build -t kiro-docker:latest .

docker run --rm \
  -e KIRO_API_KEY \
  -v "$PWD:/workspace" \
  -w /workspace \
  kiro-docker:latest \
  "Analyze this project and fix the failing tests"
```

### Use in CI / scheduled automation

Because the run is non-interactive, it works in cron jobs and CI. For example, a
nightly dependency audit:

```bash
0 2 * * * cd /srv/kiro-docker && KIRO_API_KEY=ksk_... ./run.sh -d /srv/app -r "Audit dependencies for known vulnerabilities and write findings to stdout"
```

## Configuration

| Variable | Purpose |
| --- | --- |
| `KIRO_API_KEY` | **Required.** Your Kiro API key. Read from the environment or a `.env` file (current dir, then the repo dir). |
| `KIRO_MODEL` | Default model id (same as `-m`). |
| `KIRO_IMAGE` | Image to run (default `kiro-docker:latest`). |
| `KIRO_RAW` | Set to `1` to skip the autonomy preamble (same as `-R`). |

## How it works

- `Dockerfile` builds Ubuntu 24.04 with common tooling (git, build-essential,
  Python 3, Node.js 22, jq, ripgrep, sqlite3) and installs Kiro CLI. **No key is
  baked into the image.**
- `entrypoint.sh` validates the key, refreshes apt metadata, wraps your prompt
  with an autonomy preamble (inspect the project, install what's missing, retry
  on failure, give a final report), and runs
  `kiro-cli chat --no-interactive --trust-all-tools`.
- `run.sh` mounts your project at `/workspace` and mounts named Docker volumes
  (`kiro-cache-apt`, `kiro-cache-npm`, `kiro-cache-pip`) so repeat runs don't
  re-download everything. Remove them with `make clean-cache`.

## Security notes

Read these before using it on anything important.

- **The agent can do anything inside the container and to the mounted
  directory**, including deleting or rewriting files in it. Use `-r` for
  analysis-only tasks, and keep your project under version control so you can
  review or revert changes.
- Only mount the directory the task needs. Never mount `$HOME` or `/`.
- Your API key is passed to the container as an environment variable, so the
  agent can read it. Use a key you can revoke, and don't run prompts or
  projects you don't trust (a malicious file in the project could try to
  instruct the agent to exfiltrate it).
- The container has outbound network access (required for the Kiro API and
  package installs). It is isolated from your host, not from the internet.
- Don't commit `.env`. It is git-ignored and excluded from the Docker build
  context.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `KIRO_API_KEY is not set` | Export it or create `.env` (see Quick start). |
| `Docker daemon is not running` | Start Docker Desktop / the docker service. |
| Files created by the agent are owned by root (Linux) | The container runs as root. Run `sudo chown -R "$USER" <dir>` afterwards. |
| Slow first run | The image builds and toolchains download once; later runs reuse caches. |
| Rebuild after updating | `docker build --no-cache -t kiro-docker:latest .` to pull the latest Kiro CLI. |

## Contributing

Issues and PRs are welcome. CI runs ShellCheck, Hadolint, and a build smoke test.

## License

[MIT](LICENSE)
