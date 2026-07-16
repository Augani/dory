#!/bin/bash

dory_kernel_resolve_profile() {
  local profile="${DORY_KERNEL_PROFILE:-}"
  local legacy_gpu="${DORY_EXPERIMENTAL_GPU:-0}"

  case "$legacy_gpu" in
    0|1) ;;
    *) echo "DORY_EXPERIMENTAL_GPU must be 0 or 1" >&2; return 64 ;;
  esac

  if [ -z "$profile" ]; then
    if [ "$legacy_gpu" = "1" ]; then
      profile="venus"
    else
      profile="headless"
    fi
  fi

  case "$profile" in
    headless|venus|desktop) ;;
    *) echo "DORY_KERNEL_PROFILE must be headless, venus, or desktop" >&2; return 64 ;;
  esac
  if [ "$legacy_gpu" = "1" ] && [ "$profile" != "venus" ]; then
    echo "DORY_EXPERIMENTAL_GPU=1 conflicts with DORY_KERNEL_PROFILE=$profile" >&2
    return 64
  fi
  printf '%s\n' "$profile"
}

dory_kernel_profile_suffix() {
  case "$1" in
    headless) printf '\n' ;;
    venus) printf '%s\n' '-gpu' ;;
    desktop) printf '%s\n' '-desktop' ;;
    *) return 64 ;;
  esac
}
