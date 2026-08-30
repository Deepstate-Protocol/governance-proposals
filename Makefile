SHELL := bash

.PHONY: build check check-dependencies check-layout check-live fmt lint plan-deployment test

fmt:
	forge fmt --check

lint:
	forge lint
	bash -n script/check-dependency-layout.sh
	bash -n script/check-deep-role-history.sh
	bash -n script/check-live-deployment.sh
	bash -n script/check-proposal-layout.sh
	bash -n script/check-rewarder-fork.sh

check-dependencies:
	bash script/check-dependency-layout.sh
	bash script/check-rewarder-fork.sh

check-layout:
	bash script/check-proposal-layout.sh

build:
	forge build --sizes --threads 0 --skip test --skip MockSablierLockupLinearV4.sol

test:
	forge test --force -vvv --threads 0

check-live:
	set -Eeuo pipefail; \
		live_rpc="$${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com/}"; \
		ROBINHOOD_RPC_URL="$$live_rpc" bash script/check-live-deployment.sh; \
		ROBINHOOD_RPC_URL="$$live_rpc" forge test --force \
			--match-path 'test/live/DeepstateMinterControllerLiveSablier.t.sol' -vvv --threads 0

plan-deployment:
	forge script script/DeployRewarderV2System.s.sol:DeployRewarderV2System \
		--sig 'run()' --rpc-url robinhood -vvv

check: fmt lint check-dependencies check-layout build test
