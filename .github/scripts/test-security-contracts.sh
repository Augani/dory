#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

fail() { echo "security contract failed: $*" >&2; exit 1; }

for forbidden_entitlement in \
  com.apple.security.cs.allow-jit \
  com.apple.security.cs.allow-unsigned-executable-memory \
  com.apple.security.cs.disable-library-validation \
  com.apple.security.virtualization \
  com.apple.security.hypervisor; do
  if grep -F "$forbidden_entitlement" Dory/Dory.entitlements >/dev/null; then
    fail "main app retains $forbidden_entitlement"
  fi
done

for required_entitlement in \
  com.apple.security.network.client \
  com.apple.security.network.server; do
  grep -F "$required_entitlement" Dory/Dory.entitlements >/dev/null \
    || fail "main app lost $required_entitlement"
done

if grep -R -E --include='*.swift' --include='init' \
  'tcp://0\.0\.0\.0:2375|guestPort: 2375|remote[^\n]*:2375' \
  Packages/ContainerizationEngine/Sources dory-core-swift/Sources guest/initfs/init >/dev/null; then
  fail "a production guest path exposes unauthenticated Docker TCP 2375"
fi

grep -F 'DorydXPCSecurity.configureIncomingConnection(connection)' \
  dory-core-swift/Sources/DorydKit/DorydService.swift >/dev/null \
  || fail "doryd listener does not authenticate incoming peers"
grep -F 'connection.setCodeSigningRequirement(productionClientRequirement)' \
  dory-core-swift/Sources/DorydKit/DorydXPCSecurity.swift >/dev/null \
  || fail "production doryd does not pin client signatures"
grep -F 'DorydDaemonSigningPolicy.daemonRequirement' \
  Dory/Runtime/Doryd/DorydClient.swift >/dev/null \
  || fail "production app does not pin doryd's signature"
grep -F 'DorydXPCSecurity.productionDaemonRequirement' \
  dory-core-swift/Sources/dorydctl/main.swift >/dev/null \
  || fail "production dorydctl does not pin doryd's signature"

grep -F 'static let attachSupported = false' Dory/Net/UsbAttachmentStore.swift >/dev/null \
  || fail "USB passthrough can be advertised before the guest RPC exists"

for kernel_contract in \
  'CONFIG_NETFILTER_XT_MATCH_OWNER=y' \
  'CONFIG_IP6_NF_FILTER=y' \
  'CONFIG_BLK_DEV_LOOP=y'; do
  grep -Fx "$kernel_contract" guest/kernel/dory.config >/dev/null \
    || fail "sandbox guest kernel lost $kernel_contract"
done
for agent_contract in DORY_AGENT_RUN_UID DORY_AGENT_MAX_PROCESSES DORY_AGENT_MAX_FILE_BYTES; do
  grep -F "$agent_contract" dory-core/agent/src/exec.rs >/dev/null \
    || fail "guest agent lost restricted exec key $agent_contract"
done
grep -F 'mode = "ro"' scripts/dory >/dev/null \
  || fail "sandbox mounts no longer default read-only"
grep -F 'DORY_SANDBOX_EXPIRES_AT' \
  scripts/dory dory-core-swift/Sources/DorydKit/SandboxTTLReconciler.swift >/dev/null \
  || fail "sandbox expiry is not persisted and daemon reconciled"
grep -F 'sandboxSSHAgentDenied' dory-core-swift/Sources/DoryVMMKit/DoryVMM.swift >/dev/null \
  || fail "sandbox VMM does not fail closed for ambient SSH-agent forwarding"
grep -F -- '--env-json-stdin' dory-core-swift/Sources/dorydctl/main.swift scripts/dory >/dev/null \
  || fail "ephemeral sandbox secrets can no longer avoid process argv"
[ -s SANDBOX_THREAT_MODEL.md ] || fail "sandbox threat model is missing"

echo "security contracts: PASS"
