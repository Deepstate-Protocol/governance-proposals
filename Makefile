SHELL := bash

.PHONY: build check check-dependencies check-layout check-live deploy-contracts fmt invariants lint register-dgp-001 register-dgp-002 test

ACCOUNT ?= deepstate

fmt:
	forge fmt --check

lint:
	forge lint
	bash -n script/check-dependency-layout.sh
	bash -n script/check-deep-role-history.sh
	bash -n script/check-live-deployment.sh
	bash -n script/check-proposal-layout.sh

check-dependencies:
	bash script/check-dependency-layout.sh

check-layout:
	bash script/check-proposal-layout.sh

build:
	forge build --sizes --threads 0 --skip test --skip MockSablierLockupLinearV4.sol

test:
	forge test --force -vvv --threads 0

invariants:
	forge test --force --match-path 'test/invariant/*.t.sol' -vvv --threads 0

check-live:
	set -Eeuo pipefail; \
		live_rpc="$${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com/}"; \
		ROBINHOOD_RPC_URL="$$live_rpc" bash script/check-live-deployment.sh; \
		ROBINHOOD_RPC_URL="$$live_rpc" forge test --force \
			--match-path 'test/live/DeepstateMinterControllerLiveSablier.t.sol' -vvv --threads 0

deploy-contracts:
	forge script script/DeployContracts.s.sol:DeployContracts \
		--rpc-url robinhood --account "$(ACCOUNT)" --broadcast --slow -vvvv

register-dgp-001:
	forge script script/DeployDGP001.s.sol:DeployDGP001 \
		--rpc-url robinhood --account "$(ACCOUNT)" --broadcast --slow -vvvv

register-dgp-002:
	forge script script/DeployDGP002.s.sol:DeployDGP002 \
		--rpc-url robinhood --account "$(ACCOUNT)" --broadcast --slow -vvvv

check: fmt lint check-dependencies check-layout build test
