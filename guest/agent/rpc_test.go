package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFrameRoundTrip(t *testing.T) {
	var out bytes.Buffer
	if err := writeFrame(&out, []byte("hello")); err != nil {
		t.Fatal(err)
	}
	if got := out.Bytes()[:4]; !bytes.Equal(got, []byte{0, 0, 0, 5}) {
		t.Fatalf("length prefix = %v", got)
	}
	payload, err := readFrame(bufio.NewReader(&out))
	if err != nil {
		t.Fatal(err)
	}
	if string(payload) != "hello" {
		t.Fatalf("payload = %q", payload)
	}
}

func TestDispatchUnknownMethod(t *testing.T) {
	resp := dispatch(request{ID: 7, Method: "nope", Params: json.RawMessage(`{}`)})
	if resp.Error == nil || resp.Error.Code != -32601 {
		t.Fatalf("response = %#v", resp)
	}
}

func TestExecMethod(t *testing.T) {
	resp := dispatch(request{
		ID:     1,
		Method: "exec",
		Params: json.RawMessage(`{"argv":["/bin/sh","-c","cat"],"stdin":"` + base64.StdEncoding.EncodeToString([]byte("ok")) + `","timeout_ms":1000}`),
	})
	if resp.Error != nil {
		t.Fatal(resp.Error)
	}
	result := resp.Result.(map[string]any)
	stdout, err := base64.StdEncoding.DecodeString(result["stdout_b64"].(string))
	if err != nil {
		t.Fatal(err)
	}
	if string(stdout) != "ok" {
		t.Fatalf("stdout = %q", stdout)
	}
}

func TestFSEventsBatchReappliesExistingMode(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watched.txt")
	if err := os.WriteFile(path, []byte("ok"), 0640); err != nil {
		t.Fatal(err)
	}
	resp := dispatch(request{
		ID:     2,
		Method: "fsevents.batch",
		Params: json.RawMessage(`{"paths":["` + path + `"]}`),
	})
	if resp.Error != nil {
		t.Fatal(resp.Error)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0640 {
		t.Fatalf("mode = %v", info.Mode().Perm())
	}
}

func TestDebugShellReturnsNsenterArgv(t *testing.T) {
	root := t.TempDir()
	proc := filepath.Join(root, "proc")
	if err := os.MkdirAll(filepath.Join(proc, "42"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proc, "42", "cgroup"), []byte("0::/docker/abcdef1234567890\n"), 0644); err != nil {
		t.Fatal(err)
	}
	resp := dispatch(request{
		ID:     3,
		Method: "debug.shell",
		Params: json.RawMessage(`{"containerID":"abcdef1234567890","proc_root":"` + proc + `","toolbox_path":"/.dory-toolbox/bin"}`),
	})
	if resp.Error != nil {
		t.Fatal(resp.Error)
	}
	result := resp.Result.(map[string]any)
	if result["pid"].(int) != 42 {
		t.Fatalf("pid = %#v", result["pid"])
	}
	argv := result["argv"].([]string)
	want := []string{"nsenter", "--target", "42", "--mount", "--uts", "--ipc", "--net", "--pid", "--", "env", "PATH=/.dory-toolbox/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "/.dory-toolbox/bin/sh", "-l"}
	if !equalStrings(argv, want) {
		t.Fatalf("argv = %#v", argv)
	}
}

func TestDebugShellUsesRuntimeStatePID(t *testing.T) {
	root := t.TempDir()
	state := filepath.Join(root, "run", "containerd", "io.containerd.runtime.v2.task", "moby", "cid123", "init.pid")
	if err := os.MkdirAll(filepath.Dir(state), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(state, []byte("77\n"), 0644); err != nil {
		t.Fatal(err)
	}
	pid, err := findContainerPID("cid123", filepath.Join(root, "missing-proc"), filepath.Join(root, "run"))
	if err != nil {
		t.Fatal(err)
	}
	if pid != 77 {
		t.Fatalf("pid = %d", pid)
	}
}

func TestDebugShellReportsCapabilityErrorWhenContainerMissing(t *testing.T) {
	resp := dispatch(request{
		ID:     8,
		Method: "debug.shell",
		Params: json.RawMessage(`{"containerID":"missing","proc_root":"` + t.TempDir() + `"}`),
	})
	if resp.Error == nil || resp.Error.Code != -32002 {
		t.Fatalf("response = %#v", resp)
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestUSBAttachWritesVHCICommand(t *testing.T) {
	root := filepath.Join(t.TempDir(), "sys")
	vhci := filepath.Join(root, "devices", "platform", "vhci_hcd.0")
	if err := os.MkdirAll(vhci, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(vhci, "attach"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(vhci, "detach"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	params := json.RawMessage(`{"busid":"3-2.1","port":4,"socket_fd":9,"device_id":196610,"speed":3,"sysfs_root":"` + root + `"}`)
	resp := dispatch(request{ID: 5, Method: "usb.attach", Params: params})
	if resp.Error != nil {
		t.Fatal(resp.Error)
	}
	data, err := os.ReadFile(filepath.Join(vhci, "attach"))
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "4 9 196610 3" {
		t.Fatalf("attach command = %q", data)
	}
}

func TestUSBDetachWritesVHCIPort(t *testing.T) {
	root := filepath.Join(t.TempDir(), "sys")
	if err := os.MkdirAll(root, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "attach"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "detach"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	resp := dispatch(request{
		ID:     6,
		Method: "usb.detach",
		Params: json.RawMessage(`{"busid":"3-2","port":4,"sysfs_root":"` + root + `"}`),
	})
	if resp.Error != nil {
		t.Fatal(resp.Error)
	}
	data, err := os.ReadFile(filepath.Join(root, "detach"))
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "4" {
		t.Fatalf("detach command = %q", data)
	}
}

func TestUSBAttachReportsCapabilityErrorWhenVHCIIsMissing(t *testing.T) {
	resp := dispatch(request{
		ID:     7,
		Method: "usb.attach",
		Params: json.RawMessage(`{"busid":"3-2","port":0,"socket_fd":8,"sysfs_root":"` + t.TempDir() + `"}`),
	})
	if resp.Error == nil || resp.Error.Code != -32001 {
		t.Fatalf("response = %#v", resp)
	}
}

func TestPortsWatchReturnsSnapshot(t *testing.T) {
	resp := dispatch(request{ID: 4, Method: "ports.watch", Params: json.RawMessage(`{}`)})
	if resp.Error != nil {
		t.Fatal(resp.Error)
	}
	result := resp.Result.(map[string]any)
	if _, ok := result["ports"]; !ok {
		t.Fatalf("response missing ports: %#v", result)
	}
	if _, ok := result["added"]; !ok {
		t.Fatalf("response missing added diff: %#v", result)
	}
	if _, ok := result["removed"]; !ok {
		t.Fatalf("response missing removed diff: %#v", result)
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "null") {
		t.Fatalf("ports.watch encoded null slices: %s", encoded)
	}
	var decoded map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"ports", "added", "removed"} {
		raw, ok := decoded[key]
		if !ok {
			t.Fatalf("ports.watch missing %q", key)
		}
		var arr []any
		if err := json.Unmarshal(raw, &arr); err != nil {
			t.Fatalf("ports.watch %q is not a JSON array: %s", key, raw)
		}
	}
}

func TestPortDiffReportsAddsAndRemoves(t *testing.T) {
	previous := []listenPort{{Protocol: "tcp", Port: 22}, {Protocol: "tcp", Port: 3000}}
	current := []listenPort{{Protocol: "tcp", Port: 3000}, {Protocol: "tcp6", Port: 8080}}
	added, removed := diffPorts(previous, current)
	if len(added) != 1 || added[0].Action != "add" || added[0].Protocol != "tcp6" || added[0].Port != 8080 {
		t.Fatalf("added = %#v", added)
	}
	if len(removed) != 1 || removed[0].Action != "remove" || removed[0].Protocol != "tcp" || removed[0].Port != 22 {
		t.Fatalf("removed = %#v", removed)
	}
}
