package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
)

var usbBusIDPattern = regexp.MustCompile(`^[0-9]+-[0-9]+(\.[0-9]+)*$`)

// buildUsbipImportRequest encodes the 40-byte OP_REQ_IMPORT frame the host's UsbipServer decodes:
// version(0x0111) + code(0x8003) + status(0) big-endian, then a 32-byte NUL-padded/truncated busid.
func buildUsbipImportRequest(busID string) []byte {
	req := make([]byte, 40)
	binary.BigEndian.PutUint16(req[0:], 0x0111)
	binary.BigEndian.PutUint16(req[2:], 0x8003)
	binary.BigEndian.PutUint32(req[4:], 0)
	copy(req[8:40], []byte(busID))
	return req
}

func attachUSB(params json.RawMessage) (any, error) {
	var p struct {
		BusID     string `json:"busid"`
		Port      int    `json:"port"`
		SocketFD  int    `json:"socket_fd"`
		VsockPort int    `json:"vsock_port"`
		DeviceID  int    `json:"device_id"`
		Speed     int    `json:"speed"`
		Sysfs     string `json:"sysfs_root"`
	}
	p.Port = -1
	p.SocketFD = -1
	p.VsockPort = -1
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if !usbBusIDPattern.MatchString(p.BusID) {
		return nil, errors.New("invalid usb busid")
	}
	if p.Port < 0 {
		return nil, errors.New("usb attach requires a vhci port")
	}

	// Real path: dial the host usbip server ourselves and run the import handshake so vhci gets a
	// guest-owned connected fd. A caller-supplied socket_fd (>= 0) stays a test seam that writes the
	// vhci command verbatim without touching the network.
	sockFD := p.SocketFD
	dialed := false
	if sockFD < 0 {
		if p.VsockPort < 0 {
			return nil, methodError{code: -32001, message: "usb attach requires a connected usbip socket fd or a vsock_port to dial"}
		}
		fd, err := connectVsock(uint32(p.VsockPort))
		if err != nil {
			return nil, methodError{code: -32001, message: fmt.Sprintf("usbip vsock dial: %v", err)}
		}
		if err := usbipImport(fd, p.BusID); err != nil {
			_ = closeFD(fd)
			return nil, methodError{code: -32001, message: err.Error()}
		}
		sockFD = fd
		dialed = true
	}

	root := p.Sysfs
	if root == "" {
		root = "/sys"
	}
	vhci, err := findVHCI(root)
	if err != nil {
		if dialed {
			_ = closeFD(sockFD)
		}
		return nil, methodError{code: -32001, message: err.Error()}
	}
	command := fmt.Sprintf("%d %d %d %d", p.Port, sockFD, p.DeviceID, p.Speed)
	writeErr := os.WriteFile(filepath.Join(vhci, "attach"), []byte(command), 0200)
	// vhci dups the fd (sockfd_to_socket/fget), so our copy must be closed after the write to avoid
	// leaking it, whether the write succeeded or not.
	if dialed {
		_ = closeFD(sockFD)
	}
	if writeErr != nil {
		return nil, writeErr
	}
	return map[string]any{"attached": true, "busid": p.BusID, "port": p.Port}, nil
}

func detachUSB(params json.RawMessage) (any, error) {
	var p struct {
		BusID string `json:"busid"`
		Port  int    `json:"port"`
		Sysfs string `json:"sysfs_root"`
	}
	p.Port = -1
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.BusID != "" && !usbBusIDPattern.MatchString(p.BusID) {
		return nil, errors.New("invalid usb busid")
	}
	if p.Port < 0 {
		return nil, errors.New("usb detach requires a vhci port")
	}
	root := p.Sysfs
	if root == "" {
		root = "/sys"
	}
	vhci, err := findVHCI(root)
	if err != nil {
		return nil, methodError{code: -32001, message: err.Error()}
	}
	if err := os.WriteFile(filepath.Join(vhci, "detach"), []byte(strconv.Itoa(p.Port)), 0200); err != nil {
		return nil, err
	}
	return map[string]any{"detached": true, "busid": p.BusID, "port": p.Port}, nil
}

func findVHCI(root string) (string, error) {
	candidates := []string{
		filepath.Join(root, "devices", "platform", "vhci_hcd.0"),
		filepath.Join(root, "platform", "vhci_hcd.0"),
		root,
	}
	for _, candidate := range candidates {
		if _, err := os.Stat(filepath.Join(candidate, "attach")); err == nil {
			if _, err := os.Stat(filepath.Join(candidate, "detach")); err == nil {
				return candidate, nil
			}
		}
	}
	return "", errors.New("usbip vhci_hcd sysfs interface is not available")
}
