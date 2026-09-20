.PHONY: test lint

test:
	tests/test.sh
	tests/lifecycle.sh
	tests/lib/bashunit -j 8 tests/bashunit/pane_labels_behavior_test.sh
	tests/reconcile.sh

lint:
	bash -n bin/herdr-pane-labels bin/*.sh lib/*.sh scripts/*.sh tests/*.sh
	shellcheck --severity=warning bin/herdr-pane-labels bin/*.sh lib/*.sh scripts/*.sh tests/*.sh
