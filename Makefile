.PHONY: all test package

TESTING_PLUGINS := $(shell dirname "$$(xcrun --find swift)")/../lib/swift/host/plugins/testing

all: package

test:
	swift test $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

package:
	./scripts/package.sh
