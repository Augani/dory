package main

import (
	"bytes"
	"os/exec"
)

func bytesReader(b []byte) *bytes.Reader {
	return bytes.NewReader(b)
}

func runCommand(cmd *exec.Cmd) ([]byte, []byte, int, error) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	code := 0
	if cmd.ProcessState != nil {
		code = cmd.ProcessState.ExitCode()
	}
	return stdout.Bytes(), stderr.Bytes(), code, err
}
