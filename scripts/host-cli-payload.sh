#!/bin/bash
# Pinned supply-chain metadata for the clean-Mac Docker, Buildx, Compose, and kubectl payloads.

DORY_KUBECTL_DEFAULT_VERSION="v1.36.1"
DORY_DOCKER_CLI_DEFAULT_VERSION="29.0.1"
DORY_BUILDX_DEFAULT_VERSION="v0.34.1"
DORY_COMPOSE_DEFAULT_VERSION="v2.39.2"

dory_host_cli_default_sha256() {
  case "$1:$2" in
    kubectl:arm64) printf '%s\n' 9092778abaef3079449da4cd70ded0e4be112480c93efcdeace3155968d1d133 ;;
    kubectl:x86_64) printf '%s\n' b4973e90ebb00537d735b63d6f8293c1959156e6ff435f6a43c08aeaa1a2e7d7 ;;
    docker:arm64) printf '%s\n' 9bd7f9cb4e357001df5370484164c179b506c82b88e575f978ad1bf7fbeb729f ;;
    docker:x86_64) printf '%s\n' e64b960996f1f6c174d07f727855dc49e18b958775e3ad03c1b93a4b5e62f736 ;;
    docker-buildx:arm64) printf '%s\n' e5040acdaac1a349de84c0e7a80c861a368e0d141bf7260e1fd9a74b16749477 ;;
    docker-buildx:x86_64) printf '%s\n' a4a74ff86e70706a0ae24330052ab52989da9f2090dc8fc478e398813de7b550 ;;
    docker-compose:arm64) printf '%s\n' 44ea135a29b176d959aed927d61d3483b3f0e7b4a2025ab7812aa00086916f13 ;;
    docker-compose:x86_64) printf '%s\n' fb72c16602af3fe9331e198b7f0534fd194b157a68eb6c293641c1ebbe7eac8b ;;
    *) echo "error: no default host CLI digest for $1 $2" >&2; return 1 ;;
  esac
}

dory_host_cli_default_version() {
  case "$1" in
    kubectl) printf '%s\n' "$DORY_KUBECTL_DEFAULT_VERSION" ;;
    docker) printf '%s\n' "$DORY_DOCKER_CLI_DEFAULT_VERSION" ;;
    docker-buildx) printf '%s\n' "$DORY_BUILDX_DEFAULT_VERSION" ;;
    docker-compose) printf '%s\n' "$DORY_COMPOSE_DEFAULT_VERSION" ;;
    *) echo "error: unknown host CLI '$1'" >&2; return 1 ;;
  esac
}

dory_host_cli_version_override() {
  case "$1" in
    kubectl) printf '%s' "${DORY_KUBECTL_VERSION:-}" ;;
    docker) printf '%s' "${DORY_DOCKER_CLI_VERSION:-}" ;;
    docker-buildx) printf '%s' "${DORY_BUILDX_VERSION:-}" ;;
    docker-compose) printf '%s' "${DORY_DOCKER_COMPOSE_VERSION:-${DORY_COMPOSE_VERSION:-}}" ;;
    *) return 1 ;;
  esac
}

dory_host_cli_version() {
  local override
  override="$(dory_host_cli_version_override "$1")"
  if [ -n "$override" ]; then printf '%s\n' "$override"; else dory_host_cli_default_version "$1"; fi
}

dory_host_cli_sha_override() {
  local name="$1" arch="$2" variable
  case "$name:$arch" in
    kubectl:arm64) variable=DORY_KUBECTL_SHA256_ARM64 ;;
    kubectl:x86_64) variable=DORY_KUBECTL_SHA256_X86_64 ;;
    docker:arm64) variable=DORY_DOCKER_CLI_SHA256_ARM64 ;;
    docker:x86_64) variable=DORY_DOCKER_CLI_SHA256_X86_64 ;;
    docker-buildx:arm64) variable=DORY_BUILDX_SHA256_ARM64 ;;
    docker-buildx:x86_64) variable=DORY_BUILDX_SHA256_X86_64 ;;
    docker-compose:arm64) variable=DORY_DOCKER_COMPOSE_SHA256_ARM64 ;;
    docker-compose:x86_64) variable=DORY_DOCKER_COMPOSE_SHA256_X86_64 ;;
    *) return 1 ;;
  esac
  printf '%s' "${!variable:-}"
}

dory_host_cli_expected_sha256() {
  local override
  override="$(dory_host_cli_sha_override "$1" "$2")"
  if [ -n "$override" ]; then printf '%s\n' "$override"; else dory_host_cli_default_sha256 "$1" "$2"; fi \
    | tr '[:upper:]' '[:lower:]'
}

dory_host_cli_validate_metadata() {
  local name version_override sha_arm sha_x86 value
  for name in kubectl docker docker-buildx docker-compose; do
    version_override="$(dory_host_cli_version_override "$name")"
    sha_arm="$(dory_host_cli_sha_override "$name" arm64)"
    sha_x86="$(dory_host_cli_sha_override "$name" x86_64)"
    if [ -n "$version_override" ] && { [ -z "$sha_arm" ] || [ -z "$sha_x86" ]; }; then
      echo "error: custom $name version requires pinned arm64 and x86_64 SHA-256 overrides" >&2
      return 1
    fi
    if [ -z "$version_override" ] && { [ -n "$sha_arm" ] || [ -n "$sha_x86" ]; }; then
      echo "error: custom $name SHA-256 values require an explicit version override" >&2
      return 1
    fi
    for value in "$(dory_host_cli_version "$name")" \
                 "$(dory_host_cli_expected_sha256 "$name" arm64)" \
                 "$(dory_host_cli_expected_sha256 "$name" x86_64)"; do
      [ -n "$value" ] || { echo "error: empty $name release metadata" >&2; return 1; }
    done
    for value in "$(dory_host_cli_expected_sha256 "$name" arm64)" \
                 "$(dory_host_cli_expected_sha256 "$name" x86_64)"; do
      case "$value" in *[!0-9A-Fa-f]*) echo "error: invalid $name SHA-256 '$value'" >&2; return 1 ;; esac
      [ "${#value}" -eq 64 ] || { echo "error: invalid $name SHA-256 length" >&2; return 1; }
    done
  done
}

dory_verify_host_cli_payload() {
  local file="$1" expected="$2" actual
  [ -s "$file" ] || { echo "error: host CLI payload is missing or empty: $file" >&2; return 1; }
  actual="$(shasum -a 256 "$file" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
  expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
  [ "$actual" = "$expected" ] || {
    echo "error: host CLI SHA-256 mismatch for $(basename "$file") (expected $expected, got $actual)" >&2
    return 1
  }
}
