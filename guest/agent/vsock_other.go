//go:build !linux

package main

import (
	"net"
)

func listenVsock(port uint32) (net.Listener, error) {
	_ = port
	return net.Listen("tcp", "127.0.0.1:0")
}
