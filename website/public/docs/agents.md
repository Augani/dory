# Drive Dory with agents

Dory exposes a local, versioned automation contract for coding agents. It does not require a Dory account, cloud service, or remote control plane.

## Discover the live contract

```sh
dory agent guide --json
```

The result uses `dev.dory.agent.guide v1`. It lists commands, schemas, safety properties, exit codes, MCP tools, and the recommended recovery loop for the installed release. Prefer this live output over assumptions from an older client.

## Connect an MCP client

Use Dory as a stdio MCP server:

```json
{
  "mcpServers": {
    "dory": {
      "command": "/Users/YOU/.dory/bin/dory",
      "args": ["mcp", "serve", "--read-only"]
    }
  }
}
```

Replace `YOU` with the macOS account name or resolve the command with `command -v dory`. Remove `--read-only` only when the client should be allowed to execute commands inside Dory machines or create sandbox runs.

Protocol version: `2025-11-25`

| Tool | Purpose | Read-only mode |
|---|---|---|
| `dory.agent_guide` | Return the installed capability contract | Available |
| `dory.doctor` | Run passive or active health groups | Available |
| `dory.compat` | Check local developer-tool compatibility | Available |
| `dory.engine_status` | Inspect engine state | Available |
| `dory.machine_list` | List persistent Linux machines | Available |
| `dory.machine_exec` | Execute a structured command in a machine | Blocked |
| `dory.sandbox_run` | Run a command in a dedicated preview VM | Blocked |
| `dory.wait` | Wait for an engine, container, or machine state | Available |
| `dory.events` | Read local idle and incident events | Available |

## Safety rules

1. Use read-only tools first.
2. Prefer JSON output.
3. Run dry runs before writes.
4. Do not add `--apply`, `--include-volumes`, a delete command, LAN exposure, or an engine restart unless the user has authorized it.
5. Use the narrowest repair target.
6. Re-run the relevant health group after a repair.

## Structured machine execution

```sh
dory machine exec dev --json -- /bin/sh -lc 'uname -a'
```

The result uses `dev.dory.machine.exec v1` and includes command status and bounded output. Inspect each machine before choosing commands: desktop machines use the selected Debian, Ubuntu, or Kali profile with systemd, Xfce, Bash, and a configured user, while headless machines use Alpine with an initial root `/bin/sh` login.

## Preview sandbox runs

```sh
dory sandbox run --json --network none --rollback -- /bin/sh -lc 'uname -a'
```

The sandbox is a dedicated VM and is deleted by default. It sees no host files unless a mount is supplied:

```sh
dory sandbox run --json \
  --mount "$PWD:/workspace:ro" \
  --network none \
  -- /bin/sh -lc 'find /workspace -maxdepth 2 -type f'
```

Policy facts for Dory 0.3.2:

- `none` blocks all egress and is enforced.
- `full` grants all egress and is enforced.
- `outbound` currently grants full egress and reports that the requested narrower policy is not enforced.
- `--rollback` restores a pre-run snapshot.
- `--keep` preserves the machine.
- `--ttl-seconds N` schedules cleanup.
- Mounts can be `ro` or `rw` and must be explicit.

## State waits and events

```sh
dory wait engine --until running --timeout 60 --json
dory wait container web --until running --timeout 60 --json
dory wait machine dev --until running --timeout 120 --json
dory events --follow --json
```

These remove the need for custom polling and terminal-text parsing. Wait results use `dev.dory.wait v1`. Events use `dev.dory.event v1` and `dev.dory.events v1`.

## Recovery loop

```sh
dory doctor --json
dory repair socket --json
dory repair socket --json --apply
dory doctor --json --only socket,api,docker
```

Only the third command changes state. If evidence must be shared, collect a redacted bundle:

```sh
dory support bundle --json --active
```

## More references

- [Complete agent reference](../llms-full.txt)
- [Versioned JSON capability map](../agent-guide.json)
- [Operations guide](operations.md)
- [Compatibility contract](compatibility.md)
