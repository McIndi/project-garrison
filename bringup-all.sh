#!/bin/bash
# bringup-all — Convenience wrapper for garrison + armory co-deployment
#
# Usage:
#   ./bringup-all.sh [--help] [--dry-run] [--garrison-only]
#
# Run model:
#   - Outer loop (armory changed): armory site.yml → garrison site.yml
#     (an armory rebuild wipes garrison's realm + OpenBao KV state)
#   - Inner loop (garrison changed): garrison site.yml only
#   - Default: outer loop (safest); use --garrison-only to skip armory
#
# Requirements:
#   - SSH or vagrant access to armory VM (controls kubeconfig, env vars)
#   - .env file present in garrison root (sourced by playbooks)
#   - project-armory and project-garrison co-located (siblings, e.g. /vagrant/*)
#
# Exit codes:
#   0 = success
#   1 = validation failed (missing .env, armory not reachable, etc.)
#   2 = --dry-run completed (no changes made)

set -euo pipefail

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
  echo -e "${BLUE}==>${NC} $*"
}

print_success() {
  echo -e "${GREEN}✓${NC} $*"
}

print_error() {
  echo -e "${RED}✗${NC} $*" >&2
}

print_warning() {
  echo -e "${YELLOW}!${NC} $*"
}

# Parse arguments
DRY_RUN=false
GARRISON_ONLY=false
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --help|-h)
      SHOW_HELP=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --garrison-only)
      GARRISON_ONLY=true
      shift
      ;;
    *)
      print_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Show help
if [[ "$SHOW_HELP" == "true" ]]; then
  cat <<'EOF'
bringup-all.sh — Co-deployment orchestrator for garrison + armory

USAGE:
  ./bringup-all.sh [--help] [--dry-run] [--garrison-only]

OPTIONS:
  --help, -h            Show this help message and exit.
  --dry-run             Print commands without executing them.
  --garrison-only       Skip armory; deploy only garrison (inner loop).

RUN MODELS:
  Outer loop (default): Armory rebuild → garrison deploy
    - Use when armory code has changed or k3s/Keycloak/OpenBao state unknown
    - Armory rebuild wipes garrison's realm + OpenBao KV paths
    - Safe: always works after a full reset

  Inner loop (--garrison-only): Garrison only
    - Use when only garrison code has changed
    - Assumes armory platform still running (Keycloak, OpenBao, ingress, VSO, cert-manager, trust-manager ready)
    - ~10× faster than outer loop

ENVIRONMENT:
  Set or verify in .env:
    ARMORY_PROJECT_ROOT          Where project-armory repo lives (typically /vagrant/project-armory)
    GARRISON_PROJECT_ROOT        Where project-garrison repo lives (typically /vagrant/project-garrison)
    ARMORY_KUBECONFIG_PATH       Path to armory's k3s kubeconfig (typically /etc/rancher/k3s/k3s.yaml)
    GARRISON_ANSIBLE_ROOT        Path to garrison's ansible/ dir (auto-derived from GARRISON_PROJECT_ROOT)

EXAMPLES:
  # Full outer-loop rebuild (e.g., after `vagrant destroy/up`)
  ./bringup-all.sh

  # Preview what would run without executing
  ./bringup-all.sh --dry-run

  # Fast redeploy of garrison only (changed garrison code)
  ./bringup-all.sh --garrison-only

EXIT CODES:
  0   Success
  1   Validation failed (missing .env, paths not found, etc.)
  2   --dry-run completed (no changes made)

EOF
  exit 0
fi

# Validation: check .env exists
print_header "Validating environment"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
  print_error ".env file not found in $SCRIPT_DIR"
  print_warning "Copy .env.example → .env and adjust paths for your environment"
  exit 1
fi

print_success ".env found"

# Source .env
set +u  # Temporarily disable -u to allow unset vars during sourcing
source "$SCRIPT_DIR/.env"
set -u

# Validate required vars
required_vars=(
  "GARRISON_ENV_SOURCED"
  "GARRISON_PROJECT_ROOT"
  "ARMORY_PROJECT_ROOT"
  "GARRISON_ANSIBLE_ROOT"
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    print_error "$var not set in .env"
    exit 1
  fi
done

print_success "All required env vars set"

# Check paths exist
if [[ ! -d "$ARMORY_PROJECT_ROOT" ]]; then
  print_error "ARMORY_PROJECT_ROOT not found: $ARMORY_PROJECT_ROOT"
  print_warning "Expected to run inside armory's VM with repos at /vagrant"
  exit 1
fi

if [[ ! -d "$GARRISON_PROJECT_ROOT" ]]; then
  print_error "GARRISON_PROJECT_ROOT not found: $GARRISON_PROJECT_ROOT"
  exit 1
fi

print_success "Project roots validated"

# Determine what to run
if [[ "$GARRISON_ONLY" == "true" ]]; then
  print_header "Inner loop: garrison only (assumes armory platform ready)"
  TARGETS=("garrison")
else
  print_header "Outer loop: armory → garrison (full rebuild order)"
  TARGETS=("armory" "garrison")
fi

# Dry run?
if [[ "$DRY_RUN" == "true" ]]; then
  print_warning "DRY RUN — commands will be printed but NOT executed"
fi

# Run each target
for target in "${TARGETS[@]}"; do
  print_header "Running $target site.yml"

  if [[ "$target" == "armory" ]]; then
    ansible_root="$ARMORY_PROJECT_ROOT/ansible"
  else
    ansible_root="$GARRISON_ANSIBLE_ROOT"
  fi

  if [[ ! -f "$ansible_root/playbooks/site.yml" ]]; then
    print_error "$target site.yml not found: $ansible_root/playbooks/site.yml"
    exit 1
  fi

  cmd="cd '$ansible_root' && set -a; source $SCRIPT_DIR/.env; set +a && ansible-playbook playbooks/site.yml"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  $ $cmd"
  else
    if eval "$cmd"; then
      print_success "$target deployed"
    else
      print_error "$target deployment failed"
      exit 1
    fi
  fi
done

# All done
if [[ "$DRY_RUN" == "true" ]]; then
  print_warning "DRY RUN complete — no changes made"
  exit 2
fi

print_header "🎉 All deployments complete"
print_success "Garrison is ready. Next: verify login (see tickets/open/001-agentstack-external-keycloak.md § Phase 4)"
