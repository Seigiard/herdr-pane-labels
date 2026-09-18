.PHONY: test lint

test:
	tests/test.sh

lint:
	bash -n bin/herdr-pane-labels bin/*.sh lib/*.sh scripts/*.sh tests/test.sh
	shellcheck --severity=warning bin/herdr-pane-labels bin/*.sh lib/*.sh scripts/*.sh tests/test.sh
