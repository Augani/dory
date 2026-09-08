GO ?= go
OUT ?= /tmp/dory-fex-go-preemption-regexpstress

.PHONY: build
build:
	GOTOOLCHAIN=go1.22.10 GOOS=linux GOARCH=amd64 GOAMD64=v1 CGO_ENABLED=0 $(GO) build -trimpath -o "$(OUT)" regexpstress.go
	$(GO) version -m "$(OUT)"
