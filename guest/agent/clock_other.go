//go:build !linux

package main

func syncClock(hostEpochNS int64) error {
	_ = hostEpochNS
	return nil
}
