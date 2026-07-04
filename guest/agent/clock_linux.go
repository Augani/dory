package main

import (
	"time"

	"golang.org/x/sys/unix"
)

func syncClock(hostEpochNS int64) error {
	if hostEpochNS <= 0 {
		hostEpochNS = time.Now().UnixNano()
	}
	ts := unix.NsecToTimespec(hostEpochNS)
	return unix.ClockSettime(unix.CLOCK_REALTIME, &ts)
}
