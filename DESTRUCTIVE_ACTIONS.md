# Dory destructive-action contract

Dory 0.4 treats every path that deletes durable data, replaces state, or removes a running workload
as a named operation with visible scope. A red button or explicit delete verb is not sufficient on
its own. GUI actions require a confirmation dialog; Dory-owned CLI actions require the exact target
again through `--confirm`. There is no `Delete`, `Backspace`, or `Command-Delete` shortcut for a
destructive action.

## Surface audit

| Operation | App, menu, and keyboard contract | CLI contract | Recovery |
|---|---|---|---|
| Container removal | Exact container name and permanent writable-layer warning; no keyboard shortcut | Docker-native `rm` keeps Docker's explicit verb and target semantics | Recreate from image/Compose; named volumes stay |
| Compose down | Every Containers/Compose detail surface confirms stack name and removal scope; global/menu-bar commands only open the confirming page | Docker-native `compose down` keeps Docker's explicit verb and target semantics | Images and named volumes stay; writable layers do not |
| Image/network/volume delete or prune | Exact object or class confirmation; volume data is called out separately | `dory cleanup` previews exact objects, needs `--apply`, and needs `--include-volumes` for volumes | No automatic undo; preview and backup are the safeguards |
| Linux-machine delete | Exact machine confirmation; no destructive shortcut | `dory machine delete NAME --confirm NAME` | Existing snapshots/exports survive only when retained separately |
| Linux-machine snapshot restore | Confirms the machine and explains replacement | `dory machine restore NAME SNAPSHOT --confirm NAME` | App and CLI create a retained pre-restore safety snapshot before mutation |
| Linux-machine snapshot delete | Exact snapshot confirmation | `dory machine delete-snapshot NAME SNAPSHOT --confirm SNAPSHOT` | No undo after deletion |
| Kubernetes resource delete | Exact kind, namespace, and name confirmation | `kubectl delete` remains a Kubernetes-native explicit verb | Controller reconciliation may recreate managed objects |
| Kubernetes version switch/disable | Switch and disable both state that cluster-local workloads are removed; app and menu bar cannot bypass confirmation | Kubernetes-native commands keep their own explicit target semantics | Export manifests/data first; Docker workloads stay |
| Optional component removal | Confirms exact component and states that workload data stays | `dory component remove ID --confirm ID` | Reinstall the signed component; workload data was not deleted |
| Data-drive restore/select/grow | Restore must target a new absent path; selection verifies durable drive identity; shrink and overwrite are refused | Same fail-closed path/identity contract | Original drive is never deleted automatically |
| Migration | Source inventory is read-only; import plans and rollback ledgers name every destination mutation; source deletion is not implemented | Exact plan/transaction semantics | Roll back Dory-created destination objects; source remains |
| Upgrade | Signed preflight, exact snapshot, workload smoke, automatic safe rollback, schema-aware recovery export | `dory upgrade status|recovery` are read-only | Last-known-good app/config/components or owner-only export |
| Networking/corporate profile | Preview before apply; disable removes only ownership-matching state | Dry-run is default where applicable; apply/disable are explicit | Ownership ledger restores only Dory-managed state |
| Uninstall/missing drive | Ordinary uninstall preserves the selected drive; missing-drive recovery never initializes over unknown data | Uninstall defaults to dry run and preserves workload data | Reconnect or select the identity-matching drive/verified restore |

## Enforcement

`scripts/test-destructive-action-contracts.sh` exercises the exact-confirmation parser against a
fake control client, proves restore snapshots precede mutation, rejects wrong-target acknowledgments,
checks the confirming GUI surfaces, and fails if a destructive keyboard shortcut appears. It runs
in ordinary CI and the release-output contract. The exact release UI still receives a final human
keyboard/context-menu pass because static tests cannot prove macOS presentation behavior.
