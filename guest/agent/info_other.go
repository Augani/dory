//go:build !linux

package main

func guestInfo() map[string]any {
	return map[string]any{
		"kernel":           "test-host",
		"uptime_seconds":   0,
		"memory_total":     0,
		"memory_free":      0,
		"protocol_version": 1,
	}
}
