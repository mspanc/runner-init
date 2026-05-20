#!/usr/bin/env bash
# Bootstrap GitHub Actions self-hosted runners on a fresh Ubuntu LTS machine.
#
# Required env vars:
#   GITHUB_TOKEN   – PAT with repo or admin:org scope
#   GITHUB_OWNER   – GitHub org or user
#
# Optional env vars (with defaults):
#   GITHUB_REPO         – repository name; omit for org-level runners
#   RUNNER_COUNT        – number of parallel runner instances (default: 1)
#   RUNNER_LABELS       – extra comma-separated labels (default: "")
#   RUNNER_WORKDIR      – base directory for runner instances (default: /opt/actions-runner)
#   RUNNER_NAME_PREFIX  – prefix for instance names (default: hostname -s)

set -euo pipefail
IFS=$'\n\t'

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
section() { echo -e "\n${BLUE}══ $* ══${NC}"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Configuration ──────────────────────────────────────────────────────────────
: "${GITHUB_TOKEN:?GITHUB_TOKEN env var is required}"
: "${GITHUB_OWNER:?GITHUB_OWNER env var is required}"
GITHUB_REPO="${GITHUB_REPO:-}"
RUNNER_COUNT="${RUNNER_COUNT:-1}"
RUNNER_LABELS="${RUNNER_LABELS:-}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-/opt/actions-runner}"
RUNNER_USER="runner"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-$(hostname -s)}"

# ── Architecture ───────────────────────────────────────────────────────────────
case "$(uname -m)" in
  x86_64)  RUNNER_ARCH="x64"  ; GO_ARCH="amd64" ; DEB_ARCH="amd64" ;;
  aarch64) RUNNER_ARCH="arm64"; GO_ARCH="arm64"  ; DEB_ARCH="arm64" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

# ── apt helpers ────────────────────────────────────────────────────────────────
apt_update()  { sudo apt-get update -q; }
apt_install() { DEBIAN_FRONTEND=noninteractive sudo apt-get install -y --no-install-recommends "$@"; }

# ── GitHub API helper ──────────────────────────────────────────────────────────
gh_api() {
  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

# ══════════════════════════════════════════════════════════════════════════════
# Toolchain
# ══════════════════════════════════════════════════════════════════════════════

install_system_packages() {
  section "System packages"
  apt_update
  apt_install \
    ca-certificates curl wget gnupg lsb-release software-properties-common \
    apt-transport-https \
    git git-lfs \
    build-essential gcc g++ clang cmake make \
    jq unzip zip tar xz-utils bzip2 gzip p7zip-full \
    rsync openssh-client \
    gpg dirmngr \
    python3 python3-pip python3-venv python3-dev \
    ruby ruby-dev ruby-bundler \
    default-jdk \
    libssl-dev libffi-dev libreadline-dev zlib1g-dev \
    acl sudo time \
    netcat-openbsd dnsutils iputils-ping \
    gettext-base

  sudo git lfs install --system
}

install_docker() {
  section "Docker"
  if command -v docker &>/dev/null; then
    info "Already installed: $(docker --version)"; return
  fi

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=${DEB_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt_update
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
  sudo usermod -aG docker "${RUNNER_USER}"
}

install_node() {
  section "Node.js"
  if command -v node &>/dev/null; then
    info "Already installed: $(node --version)"; return
  fi

  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
  apt_install nodejs
  sudo npm install -g yarn pnpm corepack
}

install_go() {
  section "Go"
  if [[ -x /usr/local/go/bin/go ]]; then
    info "Already installed: $(/usr/local/go/bin/go version)"; return
  fi

  local version tarball
  version=$(curl -fsSL "https://go.dev/dl/?mode=json" | jq -r '.[0].version')
  tarball="${version}.linux-${GO_ARCH}.tar.gz"

  curl -fsSL "https://go.dev/dl/${tarball}" -o "/tmp/${tarball}"
  sudo tar -C /usr/local -xzf "/tmp/${tarball}"
  rm "/tmp/${tarball}"
  printf 'export PATH=$PATH:/usr/local/go/bin\n' | sudo tee /etc/profile.d/go.sh > /dev/null
  info "Installed ${version}"
}

install_dotnet() {
  section ".NET SDK"
  if command -v dotnet &>/dev/null; then
    info "Already installed: $(dotnet --version)"; return
  fi

  local install_dir="/usr/share/dotnet"
  sudo mkdir -p "$install_dir"
  curl -fsSL https://dot.net/v1/dotnet-install.sh \
    | sudo bash -s -- --channel 10.0 --install-dir "$install_dir" --no-path
  sudo ln -sf "${install_dir}/dotnet" /usr/local/bin/dotnet
  printf 'export DOTNET_ROOT=%s\n' "$install_dir" | sudo tee /etc/profile.d/dotnet.sh > /dev/null
}

install_rust() {
  section "Rust (runner user)"
  if [[ -x "/home/${RUNNER_USER}/.cargo/bin/cargo" ]]; then
    info "Already installed for ${RUNNER_USER}"; return
  fi

  sudo -u "${RUNNER_USER}" bash -c \
    'curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path'
  printf 'export PATH=$PATH:/home/%s/.cargo/bin\n' "${RUNNER_USER}" \
    | sudo tee /etc/profile.d/rust.sh > /dev/null
}

install_aws_cli() {
  section "AWS CLI"
  if command -v aws &>/dev/null; then
    info "Already installed: $(aws --version 2>&1)"; return
  fi

  local pkg
  case "$RUNNER_ARCH" in
    x64)   pkg="awscli-exe-linux-x86_64.zip" ;;
    arm64) pkg="awscli-exe-linux-aarch64.zip" ;;
  esac

  curl -fsSL "https://awscli.amazonaws.com/${pkg}" -o /tmp/awscli.zip
  unzip -q /tmp/awscli.zip -d /tmp/awscli-src
  sudo /tmp/awscli-src/aws/install --update
  rm -rf /tmp/awscli.zip /tmp/awscli-src
}

install_azure_cli() {
  section "Azure CLI"
  if command -v az &>/dev/null; then
    info "Already installed"; return
  fi

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | sudo gpg --dearmor --yes -o /etc/apt/keyrings/microsoft.gpg

  echo "deb [arch=${DEB_ARCH} signed-by=/etc/apt/keyrings/microsoft.gpg] \
https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/azure-cli.list > /dev/null

  apt_update
  apt_install azure-cli
}

install_gcloud() {
  section "Google Cloud SDK"
  if command -v gcloud &>/dev/null; then
    info "Already installed: $(gcloud --version 2>&1 | head -1)"; return
  fi

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | sudo gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg

  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] \
https://packages.cloud.google.com/apt cloud-sdk main" \
    | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list > /dev/null

  apt_update
  apt_install google-cloud-cli
}

install_kubectl() {
  section "kubectl"
  if command -v kubectl &>/dev/null; then
    info "Already installed"; return
  fi

  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
    | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

  apt_update
  apt_install kubectl
}

install_helm() {
  section "Helm"
  if command -v helm &>/dev/null; then
    info "Already installed: $(helm version --short)"; return
  fi

  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | sudo HELM_INSTALL_DIR=/usr/local/bin bash
}

install_gh_cli() {
  section "GitHub CLI"
  if command -v gh &>/dev/null; then
    info "Already installed: $(gh --version | head -1)"; return
  fi

  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
  sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg

  echo "deb [arch=${DEB_ARCH} signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null

  apt_update
  apt_install gh
}

# ══════════════════════════════════════════════════════════════════════════════
# Runner setup
# ══════════════════════════════════════════════════════════════════════════════

create_runner_user() {
  section "Runner system user"
  if id "${RUNNER_USER}" &>/dev/null; then
    info "User '${RUNNER_USER}' already exists"
  else
    sudo useradd \
      --system \
      --create-home \
      --shell /bin/bash \
      --comment "GitHub Actions runner" \
      "${RUNNER_USER}"
    info "Created user '${RUNNER_USER}'"
  fi
}

download_runner() {
  section "GitHub Actions runner binary"
  local pkg_dir="${RUNNER_WORKDIR}/.pkg"

  if [[ -f "${pkg_dir}/run.sh" ]]; then
    info "Package already present at ${pkg_dir}"; return
  fi

  local version tarball url
  version=$(gh_api "https://api.github.com/repos/actions/runner/releases/latest" \
    | jq -r '.tag_name | ltrimstr("v")')
  tarball="actions-runner-linux-${RUNNER_ARCH}-${version}.tar.gz"
  url="https://github.com/actions/runner/releases/download/v${version}/${tarball}"

  info "Downloading runner v${version} (${RUNNER_ARCH})..."
  sudo mkdir -p "${pkg_dir}"
  sudo chown "${RUNNER_USER}:${RUNNER_USER}" "${pkg_dir}"
  sudo -u "${RUNNER_USER}" curl -fsSL "$url" -o "${pkg_dir}/${tarball}"
  sudo -u "${RUNNER_USER}" tar -xzf "${pkg_dir}/${tarball}" -C "${pkg_dir}"
  sudo rm "${pkg_dir}/${tarball}"

  sudo "${pkg_dir}/bin/installdependencies.sh"
  info "Runner v${version} ready"
}

get_registration_token() {
  local url
  if [[ -n "${GITHUB_REPO}" ]]; then
    url="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners/registration-token"
  else
    url="https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners/registration-token"
  fi
  gh_api -X POST "$url" | jq -r '.token'
}

runner_url() {
  if [[ -n "${GITHUB_REPO}" ]]; then
    echo "https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
  else
    echo "https://github.com/${GITHUB_OWNER}"
  fi
}

setup_runner_instance() {
  local idx=$1
  local instance_dir="${RUNNER_WORKDIR}/${idx}"
  local runner_name="${RUNNER_NAME_PREFIX}-${idx}"
  local pkg_dir="${RUNNER_WORKDIR}/.pkg"

  info "Configuring instance ${idx} → '${runner_name}'"

  # Tear down previous installation cleanly before reconfiguring
  if [[ -f "${instance_dir}/svc.sh" ]]; then
    pushd "${instance_dir}" > /dev/null
    sudo ./svc.sh stop      2>/dev/null || true
    sudo ./svc.sh uninstall 2>/dev/null || true
    popd > /dev/null
  fi

  sudo rm -rf "${instance_dir}"
  sudo mkdir -p "${instance_dir}"
  sudo cp -a "${pkg_dir}/." "${instance_dir}/"
  sudo chown -R "${RUNNER_USER}:${RUNNER_USER}" "${instance_dir}"

  local arch_label
  case "$RUNNER_ARCH" in
    x64)   arch_label="X64"   ;;
    arm64) arch_label="ARM64" ;;
  esac
  local labels="self-hosted,Linux,${arch_label}"
  [[ -n "${RUNNER_LABELS}" ]] && labels="${labels},${RUNNER_LABELS}"

  # Fetch a fresh token per instance; tokens expire after 1 h
  local reg_token
  reg_token=$(get_registration_token)
  local target_url
  target_url=$(runner_url)

  sudo -u "${RUNNER_USER}" bash -c "
    set -e
    cd '${instance_dir}'
    ./config.sh \
      --url '${target_url}' \
      --token '${reg_token}' \
      --name '${runner_name}' \
      --labels '${labels}' \
      --work '_work' \
      --unattended \
      --replace
  "

  pushd "${instance_dir}" > /dev/null
  sudo ./svc.sh install "${RUNNER_USER}"
  sudo ./svc.sh start
  popd > /dev/null

  info "Runner '${runner_name}' started"
}

# ══════════════════════════════════════════════════════════════════════════════
# Entry point
# ══════════════════════════════════════════════════════════════════════════════

main() {
  [[ "$(id -u)" -eq 0 ]] && die "Run as a non-root user with sudo privileges."
  command -v sudo &>/dev/null  || die "sudo not found"
  command -v curl &>/dev/null  || die "curl not found — install it first"

  info "GitHub Actions runner bootstrap"
  info "  Owner    : ${GITHUB_OWNER}"
  info "  Repo     : ${GITHUB_REPO:-<org-level>}"
  info "  Instances: ${RUNNER_COUNT}"
  info "  Workdir  : ${RUNNER_WORKDIR}"
  info "  Arch     : ${RUNNER_ARCH}"

  install_system_packages

  # Runner user must exist before Docker (group membership) and Rust (home dir)
  create_runner_user

  install_docker
  install_node
  install_go
  install_dotnet
  install_rust
  install_aws_cli
  install_azure_cli
  install_gcloud
  install_kubectl
  install_helm
  install_gh_cli

  download_runner

  for ((i = 1; i <= RUNNER_COUNT; i++)); do
    setup_runner_instance "$i"
  done

  section "Done"
  info "All ${RUNNER_COUNT} runner instance(s) configured and running."
  info ""
  info "Check status : sudo systemctl list-units 'actions.runner.*'"
  info "Stream logs  : sudo journalctl -u 'actions.runner.*' -f"
}

main "$@"
