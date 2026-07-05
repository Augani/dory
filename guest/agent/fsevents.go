package main

import (
	"encoding/json"
	"os"
)

func applyFSEvents(params json.RawMessage) (any, error) {
	var p struct {
		Paths []string `json:"paths"`
	}
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	touched := 0
	for _, path := range p.Paths {
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		if err := os.Chmod(path, info.Mode().Perm()); err != nil {
			continue
		}
		touched++
	}
	return map[string]any{"touched": touched}, nil
}
