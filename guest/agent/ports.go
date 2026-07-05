package main

import (
	"bufio"
	"encoding/json"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
)

type listenPort struct {
	Protocol string `json:"protocol"`
	Port     uint16 `json:"port"`
}

type portEvent struct {
	Action   string `json:"action"`
	Protocol string `json:"protocol"`
	Port     uint16 `json:"port"`
}

var portWatchState = struct {
	sync.Mutex
	ports []listenPort
}{}

func currentListeningPorts(params json.RawMessage) (any, error) {
	ports := readListeningPorts()
	portWatchState.Lock()
	added, removed := diffPorts(portWatchState.ports, ports)
	portWatchState.ports = ports
	portWatchState.Unlock()
	return map[string]any{"ports": ports, "added": added, "removed": removed}, nil
}

func readListeningPorts() []listenPort {
	ports := make([]listenPort, 0)
	ports = append(ports, readProcNetTCP("/proc/net/tcp", "tcp")...)
	ports = append(ports, readProcNetTCP("/proc/net/tcp6", "tcp6")...)
	sortPorts(ports)
	return ports
}

func readProcNetTCP(path, protocol string) []listenPort {
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()

	var ports []listenPort
	scanner := bufio.NewScanner(file)
	first := true
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if first {
			first = false
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 4 || fields[3] != "0A" {
			continue
		}
		address := fields[1]
		colon := strings.LastIndex(address, ":")
		if colon < 0 {
			continue
		}
		rawPort, err := strconv.ParseUint(address[colon+1:], 16, 16)
		if err != nil {
			continue
		}
		ports = append(ports, listenPort{Protocol: protocol, Port: uint16(rawPort)})
	}
	sortPorts(ports)
	return ports
}

func diffPorts(previous, current []listenPort) ([]portEvent, []portEvent) {
	oldSet := make(map[string]listenPort, len(previous))
	newSet := make(map[string]listenPort, len(current))
	for _, port := range previous {
		oldSet[portKey(port)] = port
	}
	for _, port := range current {
		newSet[portKey(port)] = port
	}

	var added []portEvent
	var removed []portEvent
	for key, port := range newSet {
		if _, ok := oldSet[key]; !ok {
			added = append(added, portEvent{Action: "add", Protocol: port.Protocol, Port: port.Port})
		}
	}
	for key, port := range oldSet {
		if _, ok := newSet[key]; !ok {
			removed = append(removed, portEvent{Action: "remove", Protocol: port.Protocol, Port: port.Port})
		}
	}
	sortEvents(added)
	sortEvents(removed)
	return added, removed
}

func sortPorts(ports []listenPort) {
	sort.Slice(ports, func(i, j int) bool {
		if ports[i].Protocol != ports[j].Protocol {
			return ports[i].Protocol < ports[j].Protocol
		}
		return ports[i].Port < ports[j].Port
	})
}

func sortEvents(events []portEvent) {
	sort.Slice(events, func(i, j int) bool {
		if events[i].Protocol != events[j].Protocol {
			return events[i].Protocol < events[j].Protocol
		}
		return events[i].Port < events[j].Port
	})
}

func portKey(port listenPort) string {
	return port.Protocol + ":" + strconv.Itoa(int(port.Port))
}
