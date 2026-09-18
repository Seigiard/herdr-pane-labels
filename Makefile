.PHONY: test lint

test:
	tests/test.sh
	tests/reconcile.sh

lint:
	bash -n bin/herdr-pane-labels bin/*.sh lib/*.sh scripts/*.sh tests/*.sh
	shellcheck --severity=warning bin/herdr-pane-labels bin/*.sh lib/*.sh scripts/*.sh tests/*.sh
