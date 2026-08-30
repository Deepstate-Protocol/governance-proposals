SHELL := bash

.PHONY: build check check-dependencies check-layout check-live fmt lint test

fmt:
	forge fmt --check

lint:
	forge lint
	bash -n script/check-dependency-layout.sh
	bash -n script/check-live-deployment.sh
	bash -n script/check-proposal-layout.sh

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
	bash script/check-live-deployment.sh

check: fmt lint check-dependencies check-layout build test
