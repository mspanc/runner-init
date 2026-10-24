#!/usr/bin/env bash
# Bootstrap GitHub Actions self-hosted runners on a fresh Ubuntu LTS machine.
#
# Usage: bash setup.sh [--force | --os-only]
# --os-only updates host tools/configuration without GitHub credentials or registration.
#
# Required env vars (registration mode only):
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
# Optional vars are intentionally NOT defaulted here so that validate_env can
# distinguish "user set this" from "never set" and prompt accordingly.
RUNNER_USER="runner"
FORCE=false
OS_ONLY=false
ANDROID_SDK_DIR="/opt/android-sdk"
ANDROID_CMDLINE_TOOLS_VERSION="15859902"
ANDROID_CMDLINE_TOOLS_SHORT_VERSION="22.0"
ANDROID_JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"

# ── Env var validation + interactive prompting ─────────────────────────────────
validate_env() {
  local interactive=false
  [[ -t 0 ]] && interactive=true

  # ── Required ────────────────────────────────────────────────────────────────
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    $interactive || true
    if $interactive; then
      read -rsp "  GitHub token (PAT, input hidden): " GITHUB_TOKEN; echo >&2
      export GITHUB_TOKEN
    fi
  fi

  if [[ -z "${GITHUB_OWNER:-}" ]]; then
    if $interactive; then
      read -rp  "  GitHub owner (org or user): " GITHUB_OWNER; export GITHUB_OWNER
    fi
  fi

  # ── Optional: only prompt if the variable was never set in the environment ──
  if ! [[ -v GITHUB_REPO ]]; then
    if $interactive; then
      read -rp "  Repository name (blank = org-level runners): " GITHUB_REPO
    else
      GITHUB_REPO=""
    fi
    export GITHUB_REPO
  fi

  if ! [[ -v RUNNER_COUNT ]]; then
    if $interactive; then
      read -rp "  Runner instances [1]: " RUNNER_COUNT
    fi
    RUNNER_COUNT="${RUNNER_COUNT:-1}"
    export RUNNER_COUNT
  fi

  if ! [[ -v RUNNER_LABELS ]]; then
    if $interactive; then
      read -rp "  Extra labels, comma-separated (blank = none): " RUNNER_LABELS
    else
      RUNNER_LABELS=""
    fi
    export RUNNER_LABELS
  fi

  if ! [[ -v RUNNER_WORKDIR ]]; then
    if $interactive; then
      read -rp "  Work directory [/opt/actions-runner]: " RUNNER_WORKDIR
    fi
    RUNNER_WORKDIR="${RUNNER_WORKDIR:-/opt/actions-runner}"
    export RUNNER_WORKDIR
  fi

  if ! [[ -v RUNNER_NAME_PREFIX ]]; then
    local default_prefix
    default_prefix=$(hostname -s)
    if $interactive; then
      read -rp "  Runner name prefix [${default_prefix}]: " RUNNER_NAME_PREFIX
    fi
    RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-${default_prefix}}"
    export RUNNER_NAME_PREFIX
  fi

  # ── Fail if required vars are still empty ───────────────────────────────────
  local missing=()
  [[ -z "${GITHUB_TOKEN:-}" ]] && missing+=("GITHUB_TOKEN  – PAT with repo or admin:org scope")
  [[ -z "${GITHUB_OWNER:-}" ]] && missing+=("GITHUB_OWNER  – GitHub org or user name")

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED}[ERROR]${NC} Missing required variables:\n" >&2
    for var in "${missing[@]}"; do
      echo -e "  ${YELLOW}•${NC} ${var}" >&2
    done
    echo >&2
    echo -e "  Run interactively to be prompted, or pass via environment:" >&2
    echo -e "  GITHUB_TOKEN=ghp_… GITHUB_OWNER=my-org bash setup.sh" >&2
    exit 1
  fi

  if ! [[ "${RUNNER_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
    die "RUNNER_COUNT must be a positive integer (got: '${RUNNER_COUNT}')"
  fi
}

# ── GitHub token preflight ─────────────────────────────────────────────────────
check_github_permissions() {
  section "Checking GitHub token permissions"

  local url scope_hint
  if [[ -n "${GITHUB_REPO}" ]]; then
    url="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners/registration-token"
    scope_hint="Classic PAT : 'repo' scope\n  Fine-grained: Administration → Read and write"
  else
    url="https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners/registration-token"
    scope_hint="Classic PAT : 'admin:org' scope\n  Fine-grained: Self-hosted runners → Read and write  (org owner required)"
  fi

  local body http_code
  body=$(curl -sS -w '\n%{http_code}' -X POST \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$url")
  http_code=$(tail -1 <<< "$body")
  body=$(sed '$d' <<< "$body")

  case "$http_code" in
    201)
      info "Token OK — runner registration permitted"
      ;;
    401)
      die "Token is invalid or expired (401).\n\n  Generate a new token and set GITHUB_TOKEN."
      ;;
    403)
      die "Token lacks runner registration permission (403).\n\n  Required:\n  ${scope_hint}"
      ;;
    404)
      local target="${GITHUB_OWNER}${GITHUB_REPO:+/${GITHUB_REPO}}"
      die "'${target}' not found or token has no visibility (404).\n\n  Check GITHUB_OWNER / GITHUB_REPO and that the token has:\n  ${scope_hint}"
      ;;
    *)
      local message
      message=$(jq -r '.message // empty' <<< "$body" 2>/dev/null || true)
      die "GitHub API error (HTTP ${http_code})${message:+: ${message}}"
      ;;
  esac
}

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

# Android versions match the Petsy Expo/React Native build and API 35 smoke test.
install_android() {
  section "Android SDK and emulator"
  if [[ "$RUNNER_ARCH" != "x64" ]]; then
    info "Skipping Android emulator toolchain: this suite requires Linux x64"
    return
  fi

  apt_install openjdk-17-jdk-headless ninja-build qemu-kvm cpu-checker \
    libgl1 libegl1 libnss3 libpulse0 libasound2-dev libx11-6 libxcb1 \
    libxcomposite1 libxcursor1 libxi6 libxrandr2 libxrender1 libxtst6 \
    libxkbcommon0 libxkbcommon-x11-0 libxcb-cursor0 libvulkan1 mesa-vulkan-drivers

  if ! sudo modprobe kvm; then
    die "Cannot load KVM. Enable virtualization on the host (nested virtualization for a VM)."
  fi
  if grep -q GenuineIntel /proc/cpuinfo; then
    sudo modprobe kvm_intel || die "Cannot load kvm_intel. Enable Intel VT-x on the host."
  elif grep -q AuthenticAMD /proc/cpuinfo; then
    sudo modprobe kvm_amd || die "Cannot load kvm_amd. Enable AMD-V on the host."
  fi
  [[ -c /dev/kvm ]] || die "/dev/kvm is missing. Enable Intel VT-x/AMD-V on the host."
  sudo groupadd -f kvm
  sudo usermod -aG kvm "${RUNNER_USER}"
  echo 'KERNEL=="kvm", GROUP="kvm", MODE="0660"' \
    | sudo tee /etc/udev/rules.d/99-github-runner-kvm.rules > /dev/null
  sudo udevadm control --reload-rules
  sudo udevadm trigger --name-match=kvm
  sudo chgrp kvm /dev/kvm
  sudo chmod 0660 /dev/kvm

  sudo install -d -o "${RUNNER_USER}" -g "${RUNNER_USER}" "${ANDROID_SDK_DIR}/cmdline-tools"
  sudo chown -R "${RUNNER_USER}:${RUNNER_USER}" "${ANDROID_SDK_DIR}"
  local tools_dir="${ANDROID_SDK_DIR}/cmdline-tools/${ANDROID_CMDLINE_TOOLS_SHORT_VERSION}"
  local temp_dir
  temp_dir=$(mktemp -d)
  if [[ ! -x "${tools_dir}/bin/sdkmanager" ]]; then
    curl -fsSL --retry 3 \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_VERSION}_latest.zip" \
      -o "${temp_dir}/commandlinetools.zip"
    unzip -q "${temp_dir}/commandlinetools.zip" -d "${temp_dir}/tools"
    sudo mv "${temp_dir}/tools/cmdline-tools" "${tools_dir}"
    sudo chown -R "${RUNNER_USER}:${RUNNER_USER}" "${tools_dir}"
  fi
  sudo ln -sfn "${tools_dir}" "${ANDROID_SDK_DIR}/cmdline-tools/latest"

  # Finite stdin avoids the SIGPIPE failure of `yes | sdkmanager` with pipefail.
  printf 'y\n%.0s' {1..100} > "${temp_dir}/licenses"
  # The bootstrap user owns the temporary license input.
  # shellcheck disable=SC2024
  sudo -u "${RUNNER_USER}" env JAVA_HOME="${ANDROID_JAVA_HOME}" \
    "${tools_dir}/bin/sdkmanager" --sdk_root="${ANDROID_SDK_DIR}" --licenses \
    < "${temp_dir}/licenses" > /dev/null
  sudo -u "${RUNNER_USER}" env JAVA_HOME="${ANDROID_JAVA_HOME}" \
    "${tools_dir}/bin/sdkmanager" --sdk_root="${ANDROID_SDK_DIR}" --install \
    platform-tools emulator \
    'platforms;android-35' 'platforms;android-36' \
    'build-tools;36.0.0' 'build-tools;37.0.0' \
    'ndk;27.1.12297006' 'cmake;3.22.1' 'cmake;3.30.5' \
    'system-images;android-35;google_apis;x86_64'
  rm -rf "${temp_dir}"

  sudo -u "${RUNNER_USER}" "${ANDROID_SDK_DIR}/emulator/emulator" -accel-check \
    || die "KVM acceleration is unavailable to ${RUNNER_USER}. Check host virtualization support."

  sudo tee /etc/profile.d/android.sh > /dev/null << EOF
export ANDROID_HOME=${ANDROID_SDK_DIR}
export ANDROID_SDK_ROOT=${ANDROID_SDK_DIR}
export JAVA_HOME_17_X64=${ANDROID_JAVA_HOME}
export PATH=${ANDROID_SDK_DIR}/cmdline-tools/latest/bin:${ANDROID_SDK_DIR}/platform-tools:${ANDROID_SDK_DIR}/emulator:\$PATH
EOF
  info "Android SDK, API 35 image, build tools, NDK, CMake, and KVM are ready"
}

# Apply this even when an existing runner skips GitHub re-registration.
configure_runner_android() {
  local idx=$1
  [[ "$RUNNER_ARCH" == "x64" ]] || return 0
  local instance_dir="${RUNNER_WORKDIR}/${idx}"
  local avd_name="petsy-api35-${idx}"
  local emulator_port=$((5554 + (idx - 1) * 2))
  [[ "$emulator_port" -le 5682 ]] || die "Too many Android emulator instances (maximum 65)."

  local env_file="${instance_dir}/.env" path_file="${instance_dir}/.path"
  local temp_env temp_path current_path
  temp_env=$(mktemp)
  temp_path=$(mktemp)
  if [[ -f "$env_file" ]]; then
    # The bootstrap user owns the temporary output.
    # shellcheck disable=SC2024
    sudo sed -E '/^(ANDROID_HOME|ANDROID_SDK_ROOT|JAVA_HOME|JAVA_HOME_17_X64|PETSY_ANDROID_AVD_NAME|PETSY_ANDROID_EMULATOR_PORT)=/d' \
      "$env_file" > "$temp_env"
  fi
  cat >> "$temp_env" << EOF
ANDROID_HOME=${ANDROID_SDK_DIR}
ANDROID_SDK_ROOT=${ANDROID_SDK_DIR}
JAVA_HOME=${ANDROID_JAVA_HOME}
JAVA_HOME_17_X64=${ANDROID_JAVA_HOME}
PETSY_ANDROID_AVD_NAME=${avd_name}
PETSY_ANDROID_EMULATOR_PORT=${emulator_port}
EOF
  current_path="${PATH}"
  if [[ -f "$path_file" ]]; then
    current_path=$(sudo cat "$path_file")
  fi
  local android_path="${ANDROID_SDK_DIR}/cmdline-tools/latest/bin:${ANDROID_SDK_DIR}/platform-tools:${ANDROID_SDK_DIR}/emulator"
  # Keep reruns from repeatedly prepending the same SDK paths.
  current_path="${current_path#"${android_path}:"}"
  printf '%s:%s\n' "$android_path" "$current_path" > "$temp_path"
  ANDROID_RUNNER_ENV_CHANGED=false
  if ! sudo cmp -s "$temp_env" "$env_file" || ! sudo cmp -s "$temp_path" "$path_file"; then
    ANDROID_RUNNER_ENV_CHANGED=true
    sudo install -o "${RUNNER_USER}" -g "${RUNNER_USER}" -m 0600 "$temp_env" "$env_file"
    sudo install -o "${RUNNER_USER}" -g "${RUNNER_USER}" -m 0644 "$temp_path" "$path_file"
  fi
  rm "$temp_env" "$temp_path"

  # SDK downloads are shared; writable AVD state is separate for each runner.
  if ! sudo -u "${RUNNER_USER}" test -d "/home/${RUNNER_USER}/.android/avd/${avd_name}.avd"; then
    sudo -u "${RUNNER_USER}" env JAVA_HOME="${ANDROID_JAVA_HOME}" \
      ANDROID_HOME="${ANDROID_SDK_DIR}" ANDROID_SDK_ROOT="${ANDROID_SDK_DIR}" \
      "${ANDROID_SDK_DIR}/cmdline-tools/latest/bin/avdmanager" create avd \
      --name "$avd_name" --package 'system-images;android-35;google_apis;x86_64' \
      --device pixel_6 <<< no
  fi
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

install_postgres_client() {
  section "PostgreSQL client"
  if dpkg -s postgresql-client-18 &>/dev/null 2>&1; then
    info "Already installed: $(psql --version)"; return
  fi

  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | sudo gpg --dearmor --yes -o /usr/share/keyrings/postgresql.gpg

  echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    | sudo tee /etc/apt/sources.list.d/pgdg.list > /dev/null

  apt_update
  apt_install postgresql-client-18
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

install_cleanup_cron() {
  section "Cleanup cron"

  local script_path="/usr/local/bin/runner-cleanup.sh"
  local cron_path="/etc/cron.d/runner-cleanup"
  local logrotate_path="/etc/logrotate.d/runner-cleanup"

  sudo tee "$script_path" > /dev/null << SCRIPT
#!/usr/bin/env bash
# Periodic cleanup of Docker cache and GitHub Actions runner artifacts.
set -euo pipefail

LOG=/var/log/runner-cleanup.log
RUNNER_WORKDIR="${RUNNER_WORKDIR}"

{
  echo "=== \$(date -Iseconds) ==="
  echo "Disk before : \$(df -h / | awk 'NR==2{print \$4}') free"

  echo "-- stopped containers --"
  docker container prune -f

  echo "-- images unused for 24 h+ --"
  docker image prune -af --filter "until=24h"

  echo "-- build cache older than 24 h --"
  docker builder prune -af --filter "until=24h"

  echo "-- unused volumes --"
  docker volume prune -f

  echo "-- runner workspaces not touched in 24 h+ --"
  find "\${RUNNER_WORKDIR}"/*/._work -mindepth 1 -maxdepth 1 \
    -type d -mtime +1 -exec rm -rf {} + 2>/dev/null || true

  echo "-- /tmp entries older than 1 day --"
  find /tmp -mindepth 1 -maxdepth 1 -mtime +1 ! -name '.X*' \
    -exec rm -rf {} + 2>/dev/null || true

  echo "Disk after  : \$(df -h / | awk 'NR==2{print \$4}') free"
  echo "==="
} >> "\$LOG" 2>&1
SCRIPT

  sudo chmod 0755 "$script_path"

  # Run daily at 03:00 as root (needs docker socket + write access to workdir)
  echo "0 3 * * * root ${script_path}" | sudo tee "$cron_path" > /dev/null
  sudo chmod 0644 "$cron_path"

  # Rotate the log weekly, keep 4 weeks
  sudo tee "$logrotate_path" > /dev/null << 'EOF'
/var/log/runner-cleanup.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF

  info "Cleanup cron installed → daily at 03:00 (${script_path})"
  info "Logs          → /var/log/runner-cleanup.log (weekly rotation, 4 weeks)"
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

# Returns 0 if the instance is already configured, registered, and its service is active.
runner_instance_ok() {
  local idx=$1
  local instance_dir="${RUNNER_WORKDIR}/${idx}"
  local expected_name="${RUNNER_NAME_PREFIX}-${idx}"

  [[ -f "${instance_dir}/.runner" ]]   || return 1
  [[ -f "${instance_dir}/.service" ]]  || return 1

  local name url svc
  name=$(jq -r '.agentName // empty' "${instance_dir}/.runner" 2>/dev/null)
  url=$(jq  -r '.gitHubUrl // empty' "${instance_dir}/.runner" 2>/dev/null)
  svc=$(cat "${instance_dir}/.service")

  [[ "$name" == "$expected_name" ]]  || return 1
  [[ "$url"  == "$(runner_url)" ]]   || return 1
  systemctl is-active --quiet "$svc" 2>/dev/null || return 1

  return 0
}

setup_runner_instance() {
  local idx=$1
  local instance_dir="${RUNNER_WORKDIR}/${idx}"
  local runner_name="${RUNNER_NAME_PREFIX}-${idx}"
  local pkg_dir="${RUNNER_WORKDIR}/.pkg"

  if [[ "${FORCE}" == "false" ]] && runner_instance_ok "$idx"; then
    configure_runner_android "$idx"
    if [[ "${ANDROID_RUNNER_ENV_CHANGED:-false}" == "true" ]]; then
      sudo systemctl restart "$(cat "${instance_dir}/.service")"
      info "Restarted '${runner_name}' to load Android environment and KVM group"
    fi
    info "Runner '${runner_name}' already configured and running — skipping registration"
    return
  fi

  info "Configuring instance ${idx} → '${runner_name}'"

  # Tear down previous installation cleanly before reconfiguring
  if [[ -f "${instance_dir}/svc.sh" ]]; then
    ( cd "${instance_dir}" && sudo ./svc.sh stop 2>/dev/null || true )
    ( cd "${instance_dir}" && sudo ./svc.sh uninstall 2>/dev/null || true )
  fi

  sudo rm -rf "${instance_dir}"
  sudo mkdir -p "${instance_dir}"
  sudo cp -a "${pkg_dir}/." "${instance_dir}/"
  sudo chown -R "${RUNNER_USER}:${RUNNER_USER}" "${instance_dir}"

  # Give each instance its own Docker config dir so concurrent jobs cannot
  # invalidate each other's registry credentials (docker/login-action logs out
  # as a post-step, which would wipe the shared ~/.docker/config.json).
  sudo -u "${RUNNER_USER}" mkdir -p "${instance_dir}/.docker"
  echo "DOCKER_CONFIG=${instance_dir}/.docker" \
    | sudo tee "${instance_dir}/.env" > /dev/null

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

  configure_runner_android "$idx"

  ( cd "${instance_dir}" && sudo ./svc.sh install "${RUNNER_USER}" && sudo ./svc.sh start )

  info "Runner '${runner_name}' started"
}

# ══════════════════════════════════════════════════════════════════════════════
# Entry point
# ══════════════════════════════════════════════════════════════════════════════

print_plan() {
  local target arch_label labels instance_range
  target="${GITHUB_OWNER}/${GITHUB_REPO:-<org-level>}"

  case "$RUNNER_ARCH" in
    x64)   arch_label="X64"   ;;
    arm64) arch_label="ARM64" ;;
  esac
  labels="self-hosted, Linux, ${arch_label}"
  [[ -n "${RUNNER_LABELS}" ]] && labels="${labels}, ${RUNNER_LABELS}"

  if [[ "${RUNNER_COUNT}" -eq 1 ]]; then
    instance_range="${RUNNER_NAME_PREFIX}-1"
  else
    instance_range="${RUNNER_NAME_PREFIX}-1 … ${RUNNER_NAME_PREFIX}-${RUNNER_COUNT}"
  fi

  echo
  echo -e "${BLUE}┌─ GitHub Actions Runner Bootstrap ──────────────────────────┐${NC}"
  printf  "${BLUE}│${NC}  %-18s %s\n" "Target:"       "$target"
  printf  "${BLUE}│${NC}  %-18s %s\n" "Instances:"    "${RUNNER_COUNT}  (${instance_range})"
  printf  "${BLUE}│${NC}  %-18s %s\n" "Labels:"       "$labels"
  printf  "${BLUE}│${NC}  %-18s %s\n" "Work dir:"     "${RUNNER_WORKDIR}"
  printf  "${BLUE}│${NC}  %-18s %s\n" "Runner user:"  "${RUNNER_USER}"
  printf  "${BLUE}│${NC}  %-18s %s\n" "Arch:"         "${RUNNER_ARCH}"
  if [[ "${FORCE}" == "true" ]]; then
    printf "${BLUE}│${NC}  %-18s %s\n" "Mode:" "forced — re-register all runners"
  else
    printf "${BLUE}│${NC}  %-18s %s\n" "Mode:" "skip already-running runners  (--force to override)"
  fi
  echo -e "${BLUE}│${NC}"
  printf  "${BLUE}│${NC}  Tools: Docker · Node 24 · Go · .NET 10 · Rust · Java · PostgreSQL 18 client\n"
  printf  "${BLUE}│${NC}         AWS CLI · Azure CLI · gcloud · kubectl · Helm · gh\n"
  printf '%b\n' "${BLUE}│${NC}  Android: JDK 17 · SDK 35/36 · API 35 emulator · NDK · CMake · KVM (x64)"
  printf  "${BLUE}│${NC}  Cron  : daily Docker + workspace cleanup at 03:00\n"
  echo -e "${BLUE}└────────────────────────────────────────────────────────────┘${NC}"
  echo
}

countdown() {
  local secs=${1:-5}
  for ((i = secs; i > 0; i--)); do
    printf "\r  ${YELLOW}Ctrl+C to abort.${NC} Starting in %d second(s)..." "$i"
    sleep 1
  done
  printf "\r  %-60s\n" "Starting..."
}

# Discover installed instances instead of asking for GitHub registration settings.
refresh_runner_os_config() {
  local instance_dir idx service
  for instance_dir in "${RUNNER_WORKDIR}"/*; do
    [[ -f "${instance_dir}/.runner" ]] || continue
    idx="${instance_dir##*/}"
    [[ "$idx" =~ ^[1-9][0-9]*$ ]] || continue
    configure_runner_android "$idx"
    if [[ "${ANDROID_RUNNER_ENV_CHANGED:-false}" == "true" && -f "${instance_dir}/.service" ]]; then
      service=$(cat "${instance_dir}/.service")
      if systemctl is-active --quiet "$service"; then
        sudo systemctl restart "$service"
        info "Restarted '${service}' to load updated OS configuration"
      fi
    fi
  done
}

main() {
  for arg in "$@"; do
    case "$arg" in
      --force) FORCE=true ;;
      --os-only) OS_ONLY=true ;;
      *) die "Unknown argument: ${arg}\n\n  Usage: bash setup.sh [--force | --os-only]" ;;
    esac
  done

  if [[ "${OS_ONLY}" == "true" ]]; then
    RUNNER_WORKDIR="${RUNNER_WORKDIR:-/opt/actions-runner}"
    export RUNNER_WORKDIR
  else
    validate_env
  fi

  # If running as root: create the dedicated runner user (if absent), grant it
  # passwordless sudo with env passthrough, then re-exec as that user.
  if [[ "$(id -u)" -eq 0 ]]; then
    [[ -f "$0" ]] || die "Root re-exec requires a file path — cannot re-exec from a pipe."

    if ! id "${RUNNER_USER}" &>/dev/null; then
      useradd --system --create-home --shell /bin/bash \
        --comment "GitHub Actions runner" "${RUNNER_USER}"
      info "Created dedicated user '${RUNNER_USER}'"
    else
      info "Using existing user '${RUNNER_USER}'"
    fi

    local sudoers_file="/etc/sudoers.d/90-${RUNNER_USER}-runner"
    printf '%s ALL=(ALL) NOPASSWD:ALL\nDefaults:%s !env_reset, !requiretty\n' \
      "${RUNNER_USER}" "${RUNNER_USER}" > "${sudoers_file}"
    chmod 0440 "${sudoers_file}"

    local script_copy="/home/${RUNNER_USER}/setup.sh"
    cp "$0" "${script_copy}"
    chown "${RUNNER_USER}:${RUNNER_USER}" "${script_copy}"
    chmod 0750 "${script_copy}"
    info "Script copied to ${script_copy}"

    info "Re-executing as '${RUNNER_USER}'..."
    exec sudo -E -u "${RUNNER_USER}" env HOME="/home/${RUNNER_USER}" bash -s -- "$@" < "$0"
  fi

  command -v sudo &>/dev/null || die "sudo not found"
  command -v curl &>/dev/null || die "curl not found — install it first"

  if [[ "${OS_ONLY}" == "true" ]]; then
    section "OS-only update"
    info "Updating host tools and configuration; GitHub registration is unchanged"
    info "Existing runner directory: ${RUNNER_WORKDIR}"
  else
    check_github_permissions
    print_plan
  fi
  countdown 5

  install_system_packages

  # Runner user must exist before Docker (group membership) and Rust (home dir)
  create_runner_user

  install_docker
  install_node
  install_android
  install_go
  install_dotnet
  install_postgres_client
  install_rust
  install_aws_cli
  install_azure_cli
  install_gcloud
  install_kubectl
  install_helm
  install_gh_cli
  install_cleanup_cron

  if [[ "${OS_ONLY}" == "true" ]]; then
    refresh_runner_os_config
    section "Done"
    info "Host tools and OS configuration aligned; existing runner registration preserved."
  else
    download_runner
    for ((i = 1; i <= RUNNER_COUNT; i++)); do
      setup_runner_instance "$i"
    done
    section "Done"
    info "All ${RUNNER_COUNT} runner instance(s) configured and running."
  fi
  info ""
  info "Check status : sudo systemctl list-units 'actions.runner.*'"
  info "Stream logs  : sudo journalctl -u 'actions.runner.*' -f"
}

main "$@"
