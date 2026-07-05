//go:build !linux

package main

import (
	"errors"
	"net"
)

func listenVsock(port uint32) (net.Listener, error) {
	_ = port
	return net.Listen("tcp", "127.0.0.1:0")
}

func connectVsock(port uint32) (int, error) {
	_ = port
	return -1, errors.New("vsock is only supported on the linux guest")
}

func usbipImport(fd int, busID string) error {
	_, _ = fd, busID
	return errors.New("usbip is only supported on the linux guest")
}

func closeFD(fd int) error {
	_ = fd
	return nil
}
