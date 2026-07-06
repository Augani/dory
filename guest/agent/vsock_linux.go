package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"time"

	"golang.org/x/sys/unix"
)

// connectVsock dials the host (VMADDR_CID_HOST) on a vsock port and returns the raw connected fd.
// The fd is guest-owned, which is what vhci_hcd requires — an fd number cannot be passed in over RPC.
func connectVsock(port uint32) (int, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	if err := unix.Connect(fd, &unix.SockaddrVM{CID: unix.VMADDR_CID_HOST, Port: port}); err != nil {
		unix.Close(fd)
		return -1, err
	}
	return fd, nil
}

func closeFD(fd int) error { return unix.Close(fd) }

// usbipImport performs the OP_REQ_IMPORT handshake on a connected usbip socket. On success the host's
// OP_REP_IMPORT device descriptor is drained so the kernel stream begins at the first URB. A short
// timeout is applied during the handshake and cleared before the fd is handed to vhci.
func usbipImport(fd int, busID string) error {
	deadline := unix.Timeval{Sec: 5}
	_ = unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &deadline)
	_ = unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_SNDTIMEO, &deadline)
	defer func() {
		zero := unix.Timeval{}
		_ = unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &zero)
		_ = unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_SNDTIMEO, &zero)
	}()

	if err := writeAllFD(fd, buildUsbipImportRequest(busID)); err != nil {
		return fmt.Errorf("usbip import write: %w", err)
	}

	head := make([]byte, 8)
	if err := readFullFD(fd, head); err != nil {
		return fmt.Errorf("usbip import reply: %w", err)
	}
	if status := binary.BigEndian.Uint32(head[4:]); status != 0 {
		return fmt.Errorf("usbip import rejected (status %d)", status)
	}
	descriptor := make([]byte, 312) // OP_REP_IMPORT device descriptor, discarded
	if err := readFullFD(fd, descriptor); err != nil {
		return fmt.Errorf("usbip import descriptor: %w", err)
	}
	return nil
}

func writeAllFD(fd int, buffer []byte) error {
	for len(buffer) > 0 {
		n, err := unix.Write(fd, buffer)
		if err != nil {
			return err
		}
		buffer = buffer[n:]
	}
	return nil
}

func readFullFD(fd int, buffer []byte) error {
	for len(buffer) > 0 {
		n, err := unix.Read(fd, buffer)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrUnexpectedEOF
		}
		buffer = buffer[n:]
	}
	return nil
}

// listenVsock returns a hand-rolled AF_VSOCK listener. Go's net.FileListener rejects vsock fds
// with "protocol not supported" (it cannot parse the sockaddr family), so the accept loop runs on
// the raw descriptor; accepted fds are set non-blocking before os.NewFile wraps them, which
// registers them with the runtime poller for normal blocking-read/write goroutine semantics.
func listenVsock(port uint32) (net.Listener, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	addr := &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: port}
	if err := unix.Bind(fd, addr); err != nil {
		unix.Close(fd)
		return nil, err
	}
	if err := unix.Listen(fd, 128); err != nil {
		unix.Close(fd)
		return nil, err
	}
	return &vsockListener{fd: fd}, nil
}

type vsockListener struct {
	fd int
}

func (l *vsockListener) Accept() (net.Conn, error) {
	for {
		nfd, _, err := unix.Accept4(l.fd, unix.SOCK_CLOEXEC)
		if err != nil {
			if err == unix.EINTR {
				continue
			}
			return nil, err
		}
		if err := unix.SetNonblock(nfd, true); err != nil {
			unix.Close(nfd)
			return nil, err
		}
		return &vsockConn{file: os.NewFile(uintptr(nfd), "dory-agent-vsock-conn")}, nil
	}
}

func (l *vsockListener) Close() error   { return unix.Close(l.fd) }
func (l *vsockListener) Addr() net.Addr { return vsockAddr{} }

type vsockAddr struct{}

func (vsockAddr) Network() string { return "vsock" }
func (vsockAddr) String() string  { return "vsock" }

type vsockConn struct {
	file *os.File
}

func (c *vsockConn) Read(b []byte) (int, error)  { return c.file.Read(b) }
func (c *vsockConn) Write(b []byte) (int, error) { return c.file.Write(b) }
func (c *vsockConn) Close() error                { return c.file.Close() }

// CloseWrite half-closes the send side (SHUT_WR) so the peer sees EOF while its own data keeps
// flowing back — the docker proxy relies on this to relay request-EOF without truncating replies.
func (c *vsockConn) CloseWrite() error {
	raw, err := c.file.SyscallConn()
	if err != nil {
		return err
	}
	var shutdownErr error
	if controlErr := raw.Control(func(fd uintptr) {
		shutdownErr = unix.Shutdown(int(fd), unix.SHUT_WR)
	}); controlErr != nil {
		return controlErr
	}
	return shutdownErr
}

func (c *vsockConn) LocalAddr() net.Addr                { return vsockAddr{} }
func (c *vsockConn) RemoteAddr() net.Addr               { return vsockAddr{} }
func (c *vsockConn) SetDeadline(t time.Time) error      { return c.file.SetDeadline(t) }
func (c *vsockConn) SetReadDeadline(t time.Time) error  { return c.file.SetReadDeadline(t) }
func (c *vsockConn) SetWriteDeadline(t time.Time) error { return c.file.SetWriteDeadline(t) }
