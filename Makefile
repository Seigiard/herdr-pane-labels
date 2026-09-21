.PHONY: test lint

# Every shell file in the package except the vendored runner. Built with find
# because the suites live in tests/bashunit and tests/helpers, which a
# non-recursive glob silently skips, and because the harness is .bash.
LINT_SOURCES := bin/herdr-pane-labels $(shell find bin lib scripts tests -type f \( -name '*.sh' -o -name '*.bash' \) -not -path 'tests/lib/*' | sort)

test:
	tests/test.sh
	tests/lifecycle.sh
	tests/lib/bashunit -j 8 tests/bashunit/pane_labels_behavior_test.sh
	tests/reconcile.sh

lint:
	bash -n $(LINT_SOURCES)
	shellcheck --severity=warning $(LINT_SOURCES)
