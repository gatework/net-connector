# Shared gates come from the published go-standards; see standard.mk.
include standard.mk

CHECK_EXTRA := modverify

.PHONY: modverify fuzz
modverify:
	$(GO) mod verify

FUZZTIME ?= 30s

fuzz:
	$(GO) test -run '^$$' -fuzz FuzzResponse -fuzztime $(FUZZTIME) ./terminal
	$(GO) test -run '^$$' -fuzz FuzzReadOnly -fuzztime $(FUZZTIME) ./driver
