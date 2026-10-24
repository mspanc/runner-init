# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

A shell script for bootstrapping GitHub Actions self-hosted runners on a fresh Ubuntu LTS machine. It installs all required dependencies, registers one or more runners against a GitHub repository or organization, and starts them as systemd services.

## Configuration

Registration settings are passed via environment variables. `--force` re-registers
runners; `--os-only` updates host tools and OS configuration without registration:

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

## Android native E2E runners

On Linux x64, provisioning installs OpenJDK 17, Android command-line tools 22.0,
platforms 35/36, build tools 36.0.0/37.0.0, NDK 27.1.12297006, CMake 3.22.1/3.30.5,
and the API 35 Google APIs x86_64 emulator image under `/opt/android-sdk`.
Build tools 37.0.0 also satisfy the current `android-emulator-runner@v2` installer.
SDK packages and licenses persist between jobs; Gradle dependencies are populated
by real builds and retained by the workflow's Gradle cache.

The host must expose Intel VT-x/AMD-V and `/dev/kvm` (enable nested virtualization
when the runner is a VM). Setup adds `runner` to `kvm`, installs a group-restricted
udev rule, and verifies emulator acceleration as that user. ARM64 provisioning
continues without the Android emulator toolchain.

Each runner gets a pre-created `petsy-api35-<N>` AVD and a distinct even emulator
port starting at 5554. The runner's `.env` exposes `ANDROID_HOME`,
`ANDROID_SDK_ROOT`, `JAVA_HOME`, `JAVA_HOME_17_X64`, `PETSY_ANDROID_AVD_NAME`, and
`PETSY_ANDROID_EMULATOR_PORT`; `.path` includes the SDK executables. These files
are needed because systemd runner services do not source shell login profiles.
Android SDK files are writable by `runner`, so SDK actions can check packages
without sudo or permission failures.

Run `bash setup.sh --os-only` to update an existing host without supplying a
GitHub token, owner, repository, runner count, or labels. It skips all registration
prompts, token checks, runner downloads, and re-registration. Installed numbered
instances under `/opt/actions-runner` are discovered automatically; set
`RUNNER_WORKDIR` if the original installation used a different base directory.
Existing active services restart only if their Android environment changed;
stopped services remain stopped. A fresh host can also be provisioned in this mode
without registering runners. Run provisioning while runners are idle: SDK updates
and service restarts must not interrupt active jobs. No setup is executed merely
by editing the script.
