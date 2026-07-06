package main

import (
	"io"
	"log"
	"net"
	"syscall"
)

// dockerProxyPort mirrors VsockPorts.docker in Swift: dory-hv serves engine.sock on the host and
// pipes every connection here, where it is joined to dockerd's unix socket. This path replaces the
// gvproxy unix forward, which tore the stream down on a client half-close and silenced the output
// of every `docker run`/`docker attach`.
const dockerProxyPort = 1026

const dockerSocketPath = "/var/run/docker.sock"

func startDockerProxy() {
	go func() {
		listener, err := listenVsock(dockerProxyPort)
		if err != nil {
			log.Printf("docker proxy vsock listener disabled: %v", err)
			return
		}
		log.Printf("docker proxy listening on vsock:%d -> %s", dockerProxyPort, dockerSocketPath)
		for {
			conn, err := listener.Accept()
			if err != nil {
				log.Printf("docker proxy accept: %v", err)
				continue
			}
			go proxyDockerConnection(conn)
		}
	}()
}

func proxyDockerConnection(client net.Conn) {
	defer client.Close()
	// No retry: while dockerd is still starting the host just sees its /version poll fail and asks
	// again, which keeps engine readiness probes fast instead of queueing behind a dial backoff.
	upstream, err := net.Dial("unix", dockerSocketPath)
	if err != nil {
		return
	}
	defer upstream.Close()

	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(upstream, client)
		// The host is done sending (request EOF / stdin EOF). Half-close toward dockerd so the
		// response keeps streaming back on the other direction; a full close would truncate it.
		halfCloseWrite(upstream)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(client, upstream)
		// dockerd finished its response: propagate EOF to the host without tearing down the
		// connection, in case late request bytes are still in flight.
		halfCloseWrite(client)
		done <- struct{}{}
	}()
	<-done
	<-done
}

// halfCloseWrite shuts down only the write side of a connection. Vsock connections accepted via
// net.FileListener do not expose CloseWrite, so fall back to a raw SHUT_WR on the descriptor.
func halfCloseWrite(conn net.Conn) {
	if closer, ok := conn.(interface{ CloseWrite() error }); ok {
		_ = closer.CloseWrite()
		return
	}
	if sysConn, ok := conn.(syscall.Conn); ok {
		if raw, err := sysConn.SyscallConn(); err == nil {
			_ = raw.Control(func(fd uintptr) {
				_ = syscall.Shutdown(int(fd), syscall.SHUT_WR)
			})
		}
	}
}
