package main

import (
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// defaultHostAIBridgePorts is a pure fallback used only when DORY_HOST_AI_BRIDGE_PORTS is unset
// (e.g. the agent is launched outside dory-hv). The authoritative port list is
// HostAIBridge.defaultPorts in Swift, which dory-hv always serializes into that env var.
const defaultHostAIBridgePorts = "11434,1234,18190"

// defaultHostAIBridgeAddr is the docker0 host-gateway address that containers reach via
// host.dory.internal:host-gateway. Binding this specific IP instead of the wildcard lets the
// bridge coexist with `docker run -p <port>:<port>`, whose docker-proxy binds 0.0.0.0.
const defaultHostAIBridgeAddr = "172.17.0.1"

func startHostAIBridge() {
	ports := hostAIBridgePorts()
	if len(ports) == 0 {
		log.Printf("host-ai bridge disabled")
		return
	}
	for _, port := range ports {
		port := port
		go serveHostAIPort(port)
	}
}

func hostAIBridgePorts() []int {
	raw := strings.TrimSpace(os.Getenv("DORY_HOST_AI_BRIDGE_PORTS"))
	if raw == "" {
		raw = defaultHostAIBridgePorts
	}
	if raw == "0" || strings.EqualFold(raw, "false") || strings.EqualFold(raw, "off") {
		return nil
	}
	seen := map[int]bool{}
	var ports []int
	for _, part := range strings.Split(raw, ",") {
		value := strings.TrimSpace(part)
		if value == "" {
			continue
		}
		port, err := strconv.Atoi(value)
		if err != nil || port <= 0 || port > 65535 {
			log.Printf("host-ai bridge ignoring invalid port %q", value)
			continue
		}
		if !seen[port] {
			seen[port] = true
			ports = append(ports, port)
		}
	}
	return ports
}

func serveHostAIPort(port int) {
	addr := strings.TrimSpace(os.Getenv("DORY_HOST_AI_BRIDGE_ADDR"))
	if addr == "" {
		addr = defaultHostAIBridgeAddr
	}
	bindAddr := net.JoinHostPort(addr, strconv.Itoa(port))
	var listener net.Listener
	var err error
	// docker0/172.17.0.1 does not exist until dockerd starts just after the agent, so the bind
	// returns EADDRNOTAVAIL for a short window. Retry the specific gateway address (never 0.0.0.0)
	// so the bridge coexists with container port publishing.
	for attempt := 0; attempt < 100; attempt++ {
		listener, err = net.Listen("tcp4", bindAddr)
		if err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		log.Printf("host-ai bridge port %d unavailable on %s: %v", port, addr, err)
		return
	}
	log.Printf("host-ai bridge listening on %s -> host vsock:%d", bindAddr, port)
	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("host-ai bridge accept %d: %v", port, err)
			continue
		}
		go bridgeHostAIConnection(port, conn)
	}
}

func bridgeHostAIConnection(port int, client net.Conn) {
	defer client.Close()

	fd, err := connectVsock(uint32(port))
	if err != nil {
		log.Printf("host-ai bridge vsock dial %d: %v", port, err)
		return
	}
	file := os.NewFile(uintptr(fd), fmt.Sprintf("dory-host-ai-%d", port))
	if file == nil {
		_ = closeFD(fd)
		return
	}
	defer file.Close()

	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(file, client)
		// Half-close the vsock write side so the host service sees request EOF while its response
		// keeps streaming back on the other direction. A full close here would truncate the reply.
		_ = syscall.Shutdown(fd, syscall.SHUT_WR)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(client, file)
		if closer, ok := client.(interface{ CloseWrite() error }); ok {
			_ = closer.CloseWrite()
		}
		done <- struct{}{}
	}()
	<-done
	<-done
}
