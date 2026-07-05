package main

import (
	"os"
	"strings"
	"syscall"
)

func guestInfo() map[string]any {
	kernel := "unknown"
	if data, err := os.ReadFile("/proc/sys/kernel/osrelease"); err == nil {
		kernel = strings.TrimSpace(string(data))
	}
	var info syscall.Sysinfo_t
	uptime := int64(0)
	totalRAM := uint64(0)
	freeRAM := uint64(0)
	if syscall.Sysinfo(&info) == nil {
		uptime = info.Uptime
		unit := uint64(info.Unit)
		totalRAM = info.Totalram * unit
		freeRAM = info.Freeram * unit
	}
	return map[string]any{
		"kernel":           kernel,
		"uptime_seconds":   uptime,
		"memory_total":     totalRAM,
		"memory_free":      freeRAM,
		"protocol_version": 1,
	}
}
