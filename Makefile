include vendor/mk/base.mk
include vendor/mk/shell.mk

build:
.PHONY: build

test: test-shell ## Runs all tests
.PHONY: test

check: check-shell ## Checks all linting, styling, & other rules
.PHONY: check

clean: clean-shell ## Cleans up project
.PHONY: clean

vendor-libsh: ## Vendors updated version of libsh
	@echo "--- $@"
	curl --proto '=https' --tlsv1.2 -sSf \
		https://raw.githubusercontent.com/fnichol/libsh/master/install.sh \
		| sh -s -- --mode=vendor --release=latest
.PHONY: vendor-libsh
