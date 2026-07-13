#!/bin/bash

dory_kernel_resolve_docker_endpoint() {
  local docker_bin="$1" override="${2:-}" context endpoint

  if [ -n "$override" ]; then
    printf '%s\n' "$override"
    return 0
  fi
  if [ -n "${DOCKER_HOST:-}" ]; then
    printf '%s\n' "$DOCKER_HOST"
    return 0
  fi

  context="$("$docker_bin" context show)"
  endpoint="$("$docker_bin" context inspect "$context" --format '{{.Endpoints.docker.Host}}')"
  [ -n "$endpoint" ] || return 1
  printf '%s\n' "$endpoint"
}

dory_kernel_docker() {
  local docker_bin="$1" endpoint="$2"
  shift 2
  env -u DOCKER_CONTEXT -u DOCKER_HOST "$docker_bin" --host "$endpoint" "$@"
}
