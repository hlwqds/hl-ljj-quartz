#!/usr/bin/env bash

set -uo pipefail

readonly REQUIRED_NODE_MAJOR=22
readonly REQUIRED_NODE_MINOR=19
failures=0

pass() {
  printf '[PASS] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1"
  failures=$((failures + 1))
}

skip() {
  printf '[SKIP] %s\n' "$1"
}

check_required_command() {
  local name=$1
  local version_flag=$2
  local command_path
  local version

  if ! command_path=$(command -v "$name" 2>/dev/null); then
    fail "$name: command not found"
    return
  fi

  version=$("$name" "$version_flag" 2>&1 | head -n 1)
  pass "$name: $command_path ($version)"
}

check_optional_command() {
  local name=$1
  local version_flag=$2
  local command_path
  local version

  if ! command_path=$(command -v "$name" 2>/dev/null); then
    skip "$name: command not found (optional)"
    return
  fi

  version=$("$name" "$version_flag" 2>&1 | head -n 1)
  pass "$name: $command_path ($version)"
}

check_node_requirement() {
  local raw_version
  local version
  local major
  local minor

  if ! command -v node >/dev/null 2>&1; then
    return
  fi

  raw_version=$(node --version)
  version=${raw_version#v}
  IFS=. read -r major minor _ <<<"$version"

  if ((major > REQUIRED_NODE_MAJOR)) ||
    ((major == REQUIRED_NODE_MAJOR && minor >= REQUIRED_NODE_MINOR)); then
    pass "node requirement: $raw_version satisfies >=${REQUIRED_NODE_MAJOR}.${REQUIRED_NODE_MINOR}.0"
  else
    fail "node requirement: $raw_version does not satisfy >=${REQUIRED_NODE_MAJOR}.${REQUIRED_NODE_MINOR}.0"
  fi
}

check_required_command node --version
check_node_requirement
check_required_command npm --version
check_required_command git --version
check_optional_command pnpm --version
check_optional_command pi --version

if ((failures > 0)); then
  printf '[FAIL] required environment checks failed: %d\n' "$failures"
  exit 1
fi

pass "required environment checks completed"
