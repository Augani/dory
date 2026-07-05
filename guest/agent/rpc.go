package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"os/exec"
	"time"
)

const maxFrameBytes = 16 * 1024 * 1024

type request struct {
	ID     int             `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type response struct {
	ID     int       `json:"id"`
	Result any       `json:"result,omitempty"`
	Error  *rpcError `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func readFrame(r *bufio.Reader) ([]byte, error) {
	var prefix [4]byte
	if _, err := io.ReadFull(r, prefix[:]); err != nil {
		return nil, err
	}
	length := binary.BigEndian.Uint32(prefix[:])
	if length > maxFrameBytes {
		return nil, errors.New("agent frame too large")
	}
	payload := make([]byte, length)
	_, err := io.ReadFull(r, payload)
	return payload, err
}

func writeFrame(w io.Writer, payload []byte) error {
	if len(payload) > maxFrameBytes {
		return errors.New("agent frame too large")
	}
	var prefix [4]byte
	binary.BigEndian.PutUint32(prefix[:], uint32(len(payload)))
	if _, err := w.Write(prefix[:]); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}

func serveRPC(rw io.ReadWriter) error {
	reader := bufio.NewReader(rw)
	for {
		payload, err := readFrame(reader)
		if err != nil {
			return err
		}
		var req request
		if err := json.Unmarshal(payload, &req); err != nil {
			return writeResponse(rw, response{Error: &rpcError{Code: -32700, Message: err.Error()}})
		}
		resp := dispatch(req)
		if err := writeResponse(rw, resp); err != nil {
			return err
		}
	}
}

func writeResponse(w io.Writer, resp response) error {
	payload, err := json.Marshal(resp)
	if err != nil {
		return err
	}
	return writeFrame(w, payload)
}

func dispatch(req request) response {
	result, err := call(req.Method, req.Params)
	if err != nil {
		var methodErr methodError
		if errors.As(err, &methodErr) {
			return response{ID: req.ID, Error: &rpcError{Code: methodErr.code, Message: methodErr.message}}
		}
		return response{ID: req.ID, Error: &rpcError{Code: -1, Message: err.Error()}}
	}
	return response{ID: req.ID, Result: result}
}

type methodError struct {
	code    int
	message string
}

func (e methodError) Error() string { return e.message }

func call(method string, params json.RawMessage) (any, error) {
	switch method {
	case "ping":
		return map[string]any{"ok": true, "info": guestInfo()}, nil
	case "info":
		return guestInfo(), nil
	case "exec":
		return runExec(params)
	case "clock.sync":
		var p struct {
			HostEpochNS int64 `json:"hostEpochNS"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
		return map[string]any{"synced": true}, syncClock(p.HostEpochNS)
	case "fsevents.batch":
		return applyFSEvents(params)
	case "ports.watch":
		return currentListeningPorts(params)
	case "usb.attach":
		return attachUSB(params)
	case "usb.detach":
		return detachUSB(params)
	case "debug.shell":
		return debugShell(params)
	default:
		return nil, methodError{code: -32601, message: "unknown method"}
	}
}

func runExec(params json.RawMessage) (any, error) {
	var p struct {
		Argv      []string          `json:"argv"`
		Env       map[string]string `json:"env"`
		StdinB64  string            `json:"stdin"`
		TimeoutMS int               `json:"timeout_ms"`
	}
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if len(p.Argv) == 0 {
		return nil, errors.New("exec argv is empty")
	}
	timeout := time.Duration(p.TimeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, p.Argv[0], p.Argv[1:]...)
	for key, value := range p.Env {
		cmd.Env = append(cmd.Env, key+"="+value)
	}
	if p.StdinB64 != "" {
		stdin, err := base64.StdEncoding.DecodeString(p.StdinB64)
		if err != nil {
			return nil, err
		}
		cmd.Stdin = bytesReader(stdin)
	}
	stdout, stderr, code, err := runCommand(cmd)
	if ctx.Err() == context.DeadlineExceeded {
		return nil, errors.New("exec timed out")
	}
	if err != nil && code == 0 {
		return nil, err
	}
	return map[string]any{
		"exit_code":  code,
		"stdout_b64": base64.StdEncoding.EncodeToString(stdout),
		"stderr_b64": base64.StdEncoding.EncodeToString(stderr),
	}, nil
}
