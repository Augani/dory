#!/bin/bash

# Return success when a generated Linux .config honors one policy assignment from a Dory config
# fragment. Kconfig omits disabled symbols whose dependencies are unavailable instead of always
# writing "# CONFIG_FOO is not set". Such an omission is equivalent to =n, but any explicit
# assignment (including y or m) must still fail closed.
dory_kernel_config_honors_policy() {
  local config="$1" symbol="$2" expected="$3"

  if [ "$expected" = "n" ]; then
    if grep -q "^${symbol}=" "$config"; then
      grep -Fqx "${symbol}=n" "$config"
    else
      return 0
    fi
  else
    grep -Fqx "${symbol}=${expected}" "$config"
  fi
}
