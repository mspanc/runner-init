# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

A shell script for bootstrapping GitHub Actions self-hosted runners on a fresh Ubuntu LTS machine. It installs all required dependencies, registers one or more runners against a GitHub repository or organization, and starts them as systemd services.

## Configuration

All parameters are passed via environment variables — no positional arguments or flags:

| Variable | Description |
|---|---|
| `GITHUB_TOKEN` | PAT or registration token with `repo` (or `admin:org`) scope |
| `GITHUB_OWNER` | GitHub org or user (e.g. `my-org`) |
| `GITHUB_REPO` | Repository name; omit for org-level runners |
| `RUNNER_COUNT` | Number of parallel runner instances to register (default: `1`) |
| `RUNNER_LABELS` | Comma-separated extra labels to attach |
| `RUNNER_WORKDIR` | Base working directory (default: `/opt/actions-runner`) |

## Script Design

- Single entry-point: `setup.sh` — idempotent, safe to re-run.
- Must be run as a non-root user with `sudo` privileges; the script creates a dedicated `runner` system user if absent.
- Registers runners via the GitHub REST API (`/repos/:owner/:repo/actions/runners/registration-token` or org equivalent) before invoking the runner's `config.sh`.
- Each runner instance runs as a systemd service named `github-runner@<N>`.

## Tool Parity with GitHub-Hosted Runners

The script should install the same toolset as the `ubuntu-latest` GitHub-hosted image. Key categories:

- **Runtimes**: Docker, Node.js 24 LTS, Python 3, Ruby, Java (OpenJDK), Go, .NET SDK 10.0
- **Build tools**: make, cmake, gcc, g++, clang
- **Package managers**: apt, pip, npm/yarn/pnpm, gem, cargo (Rust toolchain)
- **CLI utilities**: curl, wget, git, jq, unzip, zip, tar, rsync, gpg, openssh-client
- **Cloud CLIs**: AWS CLI, Azure CLI, Google Cloud SDK, kubectl, Helm
- **GitHub tooling**: gh (GitHub CLI), act (optional local runner)

Reference: [actions/runner-images ubuntu toolset](https://github.com/actions/runner-images/blob/main/images/ubuntu/toolsets/toolset-2204.json)

## Testing

Test locally with `shellcheck setup.sh` for static analysis. For integration testing, spin up an Ubuntu LTS container:

```sh
docker run --rm -it ubuntu:24.04 bash
# then copy and execute setup.sh inside the container
```

There is no automated test suite yet; `shellcheck` is the primary quality gate.
