package main

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestBuildUsbipImportRequestMatchesWireFormat(t *testing.T) {
	req := buildUsbipImportRequest("3-2")
	if len(req) != 40 {
		t.Fatalf("want 40-byte OP_REQ_IMPORT, got %d", len(req))
	}
	if v := binary.BigEndian.Uint16(req[0:]); v != 0x0111 {
		t.Errorf("version = %#04x, want 0x0111", v)
	}
	if c := binary.BigEndian.Uint16(req[2:]); c != 0x8003 {
		t.Errorf("code = %#04x, want 0x8003 (OP_REQ_IMPORT)", c)
	}
	if s := binary.BigEndian.Uint32(req[4:]); s != 0 {
		t.Errorf("status = %d, want 0", s)
	}
	busid := req[8:40]
	if !bytes.HasPrefix(busid, []byte("3-2\x00")) {
		t.Errorf("busid not NUL-terminated at start: %q", busid)
	}
	for _, b := range busid[3:] {
		if b != 0 {
			t.Errorf("busid tail not NUL-padded: %q", busid)
			break
		}
	}
}

func TestBuildUsbipImportRequestTruncatesLongBusID(t *testing.T) {
	long := "1234567890123456789012345678901234567890" // > 32 chars
	req := buildUsbipImportRequest(long)
	if len(req) != 40 {
		t.Fatalf("want 40 bytes, got %d", len(req))
	}
	if !bytes.Equal(req[8:40], []byte(long)[:32]) {
		t.Errorf("busid not truncated to 32 bytes")
	}
}
