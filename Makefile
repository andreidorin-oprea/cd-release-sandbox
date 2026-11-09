LOCALBIN ?= $(shell pwd)/bin
SBOT ?= $(LOCALBIN)/sbot
SBOT_VERSION = v1.7.2

.PHONY: sbot
sbot: $(SBOT)
$(SBOT):
	mkdir -p $(LOCALBIN)
	test -s $(SBOT) || GOBIN=$(LOCALBIN) go install github.com/restechnica/semverbot/cmd/sbot@$(SBOT_VERSION)
