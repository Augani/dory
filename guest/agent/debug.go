package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var safeContainerIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.:-]*$`)

type debugShellParams struct {
	ContainerID string            `json:"containerID"`
	Argv        []string          `json:"argv"`
	Env         map[string]string `json:"env"`
	TimeoutMS   int               `json:"timeout_ms"`
	ProcRoot    string            `json:"proc_root"`
	RuntimeRoot string            `json:"runtime_root"`
	ToolboxPath string            `json:"toolbox_path"`
}

func debugShell(params json.RawMessage) (any, error) {
	var p debugShellParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.ProcRoot == "" {
		p.ProcRoot = "/proc"
	}
	if p.RuntimeRoot == "" {
		p.RuntimeRoot = "/run"
	}
	if p.ToolboxPath == "" {
		p.ToolboxPath = "/.dory-toolbox/bin"
	}
	pid, err := findContainerPID(p.ContainerID, p.ProcRoot, p.RuntimeRoot)
	if err != nil {
		return nil, methodError{code: -32002, message: err.Error()}
	}
	argv := debugNsenterArgv(pid, p.Argv, p.ToolboxPath)
	if len(p.Argv) == 0 {
		return map[string]any{"pid": pid, "argv": argv, "toolbox_path": p.ToolboxPath}, nil
	}

	timeout := time.Duration(p.TimeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	for key, value := range p.Env {
		cmd.Env = append(cmd.Env, key+"="+value)
	}
	stdout, stderr, code, err := runCommand(cmd)
	if ctx.Err() == context.DeadlineExceeded {
		return nil, errors.New("debug shell timed out")
	}
	if err != nil && code == 0 {
		return nil, err
	}
	return map[string]any{
		"pid":        pid,
		"argv":       argv,
		"exit_code":  code,
		"stdout_b64": base64.StdEncoding.EncodeToString(stdout),
		"stderr_b64": base64.StdEncoding.EncodeToString(stderr),
	}, nil
}

func debugNsenterArgv(pid int, command []string, toolboxPath string) []string {
	if len(command) == 0 {
		command = []string{toolboxPath + "/sh", "-l"}
	}
	pathPrefix := toolboxPath + ":/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	argv := []string{
		"nsenter",
		"--target", strconv.Itoa(pid),
		"--mount", "--uts", "--ipc", "--net", "--pid",
		"--",
		"env", "PATH=" + pathPrefix,
	}
	return append(argv, command...)
}

func findContainerPID(containerID, procRoot, runtimeRoot string) (int, error) {
	if !safeContainerIDPattern.MatchString(containerID) {
		return 0, errors.New("invalid container id")
	}
	if pid, err := findContainerPIDFromRuntimeState(containerID, runtimeRoot); err == nil {
		return pid, nil
	}
	entries, err := os.ReadDir(procRoot)
	if err != nil {
		return 0, fmt.Errorf("proc is not available: %w", err)
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		cgroup, err := os.ReadFile(filepath.Join(procRoot, entry.Name(), "cgroup"))
		if err != nil {
			continue
		}
		if cgroupContainsContainerID(string(cgroup), containerID) {
			return pid, nil
		}
	}
	return 0, errors.New("container namespaces are not available")
}

func findContainerPIDFromRuntimeState(containerID, runtimeRoot string) (int, error) {
	for _, path := range []string{
		filepath.Join(runtimeRoot, "containerd", "io.containerd.runtime.v2.task", "moby", containerID, "init.pid"),
		filepath.Join(runtimeRoot, "docker", "runtime-runc", "moby", containerID, "state.json"),
	} {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		if strings.HasSuffix(path, "init.pid") {
			pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
			if err == nil && pid > 0 {
				return pid, nil
			}
			continue
		}
		var state struct {
			Pid int `json:"pid"`
		}
		if json.Unmarshal(data, &state) == nil && state.Pid > 0 {
			return state.Pid, nil
		}
	}
	return 0, os.ErrNotExist
}

func cgroupContainsContainerID(cgroup, containerID string) bool {
	if strings.Contains(cgroup, containerID) {
		return true
	}
	if len(containerID) >= 12 {
		return strings.Contains(cgroup, containerID[:12])
	}
	return false
}
