# gatework shared make targets (STANDARD.md MOD-5).
# Source of truth: github.com/gatework/go-standards/standard.mk
# Distributed by `stdsync write`; do not edit the copies. A repository's
# Makefile includes this file and may add targets or extend CHECK_EXTRA.
# standard-version: 1.2.0

GO ?= go
export GOWORK := off
export GOFLAGS := -mod=readonly
export GOTOOLCHAIN := local

STANDARDS_VERSION ?= v1.2.0
GOLANGCI_LINT ?= $(GO) run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0
GOVULNCHECK ?= $(GO) run golang.org/x/vuln/cmd/govulncheck@v1.9.0

# STANDARDS_DIR points at a local go-standards checkout; when unset the
# published module at STANDARDS_VERSION is used.
ifneq ($(STANDARDS_DIR),)
STDSYNC ?= $(GO) -C $(STANDARDS_DIR) run ./cmd/stdsync
ARCHCHECK ?= $(GO) -C $(STANDARDS_DIR) run ./cmd/archcheck
else
STDSYNC ?= $(GO) run github.com/gatework/go-standards/cmd/stdsync@$(STANDARDS_VERSION)
ARCHCHECK ?= $(GO) run github.com/gatework/go-standards/cmd/archcheck@$(STANDARDS_VERSION)
endif

# Targets a repository appends to check (for example fuzz or delivery
# checks). It may be set before or after the include: it is expanded when
# check runs, not when this file is read.
CHECK_EXTRA ?=

.PHONY: check standard fmt tidy vet lint arch test vuln

check: standard fmt tidy vet lint arch test vuln
	@$(if $(strip $(CHECK_EXTRA)),$(MAKE) --no-print-directory $(CHECK_EXTRA))

standard:
	$(STDSYNC) check $(CURDIR)

# Only the diff on stdout counts; tool and download chatter goes to stderr.
fmt:
	@out=$$($(GOLANGCI_LINT) fmt --diff ./...) || exit 1; if [ -n "$$out" ]; then echo "$$out"; echo "run: $(GOLANGCI_LINT) fmt ./..."; exit 1; fi

tidy:
	$(GO) mod tidy -diff

vet:
	$(GO) vet ./...

lint:
	$(GOLANGCI_LINT) run ./...

arch:
	@if [ -f architecture.yaml ]; then $(ARCHCHECK) -dir $(CURDIR); else echo "architecture.yaml missing (ARC-1)"; exit 1; fi

test:
	$(GO) test -race -shuffle=on -count=1 ./...

vuln:
	$(GOVULNCHECK) ./...
