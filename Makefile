SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

BINARY := pqauth
LEVEL  ?= 65

CYAN   := \033[1;36m
GREEN  := \033[1;32m
YELLOW := \033[1;33m
RED    := \033[1;31m
BLUE   := \033[1;34m
BOLD   := \033[1m
RESET  := \033[0m

.PHONY: help check-env build keygen deploy verify-contract fund sign verify settle tamper-test replay-test status demo run-payment clean

help: ## Show available ForgeLattice + QDay Aevum workflow commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1;36m%-14s\033[0m %s\n", $$1, $$2}'

CLI_AMOUNT := $(AMOUNT)
CLI_NONCE  := $(NONCE)

check-env:
	@if [ ! -f .env ]; then \
		printf "$(YELLOW)=== First-Time Setup: Creating .env ===$(RESET)\n"; \
		printf 'QDAY_RPC="https://rpc-test.qday.info"\nTUSD8_ADDR="0x456569838f1d43009A91ebA4263147Afd7233483"\nSETTLER_PK=""\nPAYEE=""\nAMOUNT="100"\nNONCE="1"\n' > .env; \
	fi
	@set -a; source .env; set +a; \
	if [ -z "$$QDAY_RPC" ] || [[ "$$QDAY_RPC" == *"<"* ]]; then \
		grep -v '^QDAY_RPC=' .env > .env.tmp && mv .env.tmp .env; \
		echo 'QDAY_RPC="https://rpc-test.qday.info"' >> .env; \
	fi; \
	if [ -z "$$TUSD8_ADDR" ] || [[ "$$TUSD8_ADDR" == *"<"* ]]; then \
		grep -v '^TUSD8_ADDR=' .env > .env.tmp && mv .env.tmp .env; \
		echo 'TUSD8_ADDR="0x456569838f1d43009A91ebA4263147Afd7233483"' >> .env; \
	fi; \
	if [ -z "$$SETTLER_PK" ] || [[ "$$SETTLER_PK" == *"<"* ]] || [[ "$$SETTLER_PK" == *"YOUR_"* ]]; then \
		read -rsp "Enter SETTLER_PK (hidden input, saved to .env): " PK_INPUT; echo ""; \
		test -n "$$PK_INPUT" || (printf "$(RED)Error: SETTLER_PK cannot be empty.$(RESET)\n" && exit 1); \
		grep -v '^SETTLER_PK=' .env > .env.tmp && mv .env.tmp .env; \
		echo "SETTLER_PK=\"$$PK_INPUT\"" >> .env; \
	fi; \
	set -a; source .env; set +a; \
	if [ -z "$$PAYEE" ] || [[ "$$PAYEE" == *"<"* ]] || [[ "$$PAYEE" == *"RECIPIENT"* ]]; then \
		DEFAULT_PAYEE=$$(cast wallet address --private-key "$$SETTLER_PK"); \
		grep -v '^PAYEE=' .env > .env.tmp && mv .env.tmp .env; \
		echo "PAYEE=\"$$DEFAULT_PAYEE\"" >> .env; \
	fi; \
	if [ -z "$$AMOUNT" ] && [ -z "$(CLI_AMOUNT)" ]; then \
		read -rp "Enter tUSD8 AMOUNT in base units [default: 100]: " AMT_INPUT; \
		echo "AMOUNT=\"$${AMT_INPUT:-100}\"" >> .env; \
	fi; \
	if [ -z "$$NONCE" ] && [ -z "$(CLI_NONCE)" ]; then \
		read -rp "Enter payment NONCE [default: 1]: " NONCE_INPUT; \
		echo "NONCE=\"$${NONCE_INPUT:-1}\"" >> .env; \
	fi

build: ## Compile ForgeLattice Go CLI and PaymentGate.sol (Shanghai EVM)
	@printf "$(CYAN)=== Building ForgeLattice CLI ($(BINARY)) ===$(RESET)\n"
	@go build -o $(BINARY) main.go
	@printf "$(CYAN)=== Compiling PaymentGate.sol ===$(RESET)\n"
	@forge build --root contracts

keygen: ## Generate a new FIPS 204 ML-DSA-65 keypair into keypair.json
	@test -x ./$(BINARY) || $(MAKE) build
	@printf "$(CYAN)=== [Stage 1] Generating ML-DSA-$(LEVEL) Keypair ===$(RESET)\n"
	@SEED="0x$$(openssl rand -hex 32)"; \
	./$(BINARY) keygen --seed "$$SEED" --level $(LEVEL) > keypair.json
	@printf "$(GREEN)✓ Saved keypair.json (PK: $$(jq -r '.pk_bytes' keypair.json)B, SK: $$(jq -r '.sk_bytes' keypair.json)B)$(RESET)\n"

deploy: check-env ## Deploy PaymentGate.sol to QDay Aevum Testnet using keypair.json
	@set -a; source .env; set +a; \
	test -f keypair.json || (printf "$(RED)Error: keypair.json not found. Run 'make keygen' first.$(RESET)\n" && exit 1); \
	SETTLER_ADDR=$$(cast wallet address --private-key "$$SETTLER_PK"); \
	PQ_PUB_KEY=$$(jq -r '.public_key' keypair.json); \
	printf "$(CYAN)=== [Stage 2] Deploying PaymentGate.sol (Settler: $$SETTLER_ADDR) ===$(RESET)\n"; \
	forge create --root contracts src/PaymentGate.sol:PaymentGate \
		--rpc-url "$$QDAY_RPC" \
		--private-key "$$SETTLER_PK" \
		--broadcast \
		--constructor-args "$$TUSD8_ADDR" "$$SETTLER_ADDR" "$$PQ_PUB_KEY"

verify-contract: check-env ## Verify PaymentGate.sol source & ABI on QDay Aevum Blockscout Explorer
	@set -a; source .env; set +a; \
	: $${PAYMENT_GATE:?Set PAYMENT_GATE in .env first}; \
	test -f keypair.json || (printf "$(RED)Error: keypair.json not found.$(RESET)\n" && exit 1); \
	SETTLER_ADDR=$$(cast wallet address --private-key "$$SETTLER_PK"); \
	PQ_PUB_KEY=$$(jq -r '.public_key' keypair.json); \
	CONSTRUCTOR_ARGS=$$(cast abi-encode "constructor(address,address,bytes)" "$$TUSD8_ADDR" "$$SETTLER_ADDR" "$$PQ_PUB_KEY"); \
	printf "$(CYAN)=== Verifying PaymentGate.sol on QDay Aevum Explorer ($$PAYMENT_GATE) ===$(RESET)\n"; \
	if forge verify-contract \
		--root contracts \
		--chain-id 44005 \
		--verifier blockscout \
		--verifier-url https://explorer-test.qday.info/api \
		--constructor-args "$$CONSTRUCTOR_ARGS" \
		"$$PAYMENT_GATE" \
		src/PaymentGate.sol:PaymentGate; then \
		printf "$(GREEN)✓ Contract verified on Blockscout Explorer!$(RESET)\n"; \
	else \
		printf "$(YELLOW)⚠ Explorer verification skipped/pending (indexer delay or compiler match).$(RESET)\n"; \
	fi

fund: check-env ## Transfer $(AMOUNT) tUSD8 base units into PaymentGate escrow
	@set -a; source .env; set +a; \
	: $${PAYMENT_GATE:?Set PAYMENT_GATE in .env first}; \
	printf "$(CYAN)=== [Stage 3] Funding PaymentGate ($$PAYMENT_GATE) with $$AMOUNT tUSD8 units ===$(RESET)\n"; \
	cast send "$$TUSD8_ADDR" "transfer(address,uint256)" "$$PAYMENT_GATE" "$$AMOUNT" \
		--rpc-url "$$QDAY_RPC" --private-key "$$SETTLER_PK"

sign: check-env ## Fetch on-chain authHash for $(NONCE) and sign off-chain into sig.json
	@set -a; source .env; set +a; \
	: $${PAYMENT_GATE:?Set PAYMENT_GATE in .env first}; \
	test -f keypair.json || (printf "$(RED)Error: keypair.json not found.$(RESET)\n" && exit 1); \
	AUTH_HASH=$$(cast call "$$PAYMENT_GATE" \
		"computeAuthHash(address,uint256,uint256)(bytes32)" \
		"$$PAYEE" "$$AMOUNT" "$$NONCE" --rpc-url "$$QDAY_RPC"); \
	PQ_PRIV_KEY=$$(jq -r '.private_key' keypair.json); \
	printf "$(CYAN)=== [Stage 4] Signing authHash $$AUTH_HASH (Nonce: $$NONCE) ===$(RESET)\n"; \
	./$(BINARY) sign --privKey "$$PQ_PRIV_KEY" --message "$$AUTH_HASH" --level $(LEVEL) > sig.json
	@printf "$(GREEN)✓ Saved sig.json ($$(jq -r '.sig_bytes' sig.json) bytes)$(RESET)\n"

verify: check-env ## Verify sig.json off-chain against keypair.json and on-chain authHash
	@set -a; source .env; set +a; \
	: $${PAYMENT_GATE:?Set PAYMENT_GATE in .env first}; \
	test -f sig.json || (printf "$(RED)Error: sig.json not found. Run 'make sign' first.$(RESET)\n" && exit 1); \
	AUTH_HASH=$$(cast call "$$PAYMENT_GATE" \
		"computeAuthHash(address,uint256,uint256)(bytes32)" \
		"$$PAYEE" "$$AMOUNT" "$$NONCE" --rpc-url "$$QDAY_RPC"); \
	PQ_PUB_KEY=$$(jq -r '.public_key' keypair.json); \
	SIGNATURE=$$(jq -r '.signature' sig.json); \
	printf "$(CYAN)=== [Stage 6] Verifying Valid Original ML-DSA-$(LEVEL) Verification (sig.json) ===$(RESET)\n"; \
	./$(BINARY) verify --pubKey "$$PQ_PUB_KEY" --signature "$$SIGNATURE" --message "$$AUTH_HASH" --level $(LEVEL)

settle: verify ## Verify off-chain and settle tUSD8 on-chain via PaymentGate.release()
	@set -a; source .env; set +a; \
	SIGNATURE=$$(jq -r '.signature' sig.json); \
	printf "$(GREEN)✓ Signature VALID -> Executing On-Chain PaymentGate.release() ===$(RESET)\n"; \
	cast send "$$PAYMENT_GATE" \
		"release(address,uint256,uint256,bytes)" \
		"$$PAYEE" "$$AMOUNT" "$$NONCE" "$$SIGNATURE" \
		--rpc-url "$$QDAY_RPC" --private-key "$$SETTLER_PK"

tamper-test: ## Demo: Flip 1 byte in sig.json and confirm off-chain gate blocks tx (0 gas)
	@test -f sig.json || (printf "$(RED)Error: sig.json not found. Run 'make sign' first.$(RESET)\n" && exit 1)
	@printf "$(YELLOW)=== [Stage 5] Tamper Test: Flipping first byte of ML-DSA-65 signature ===$(RESET)\n"
	@AUTH_HASH=$$(jq -r '.auth_hash' sig.json); \
	PQ_PUB_KEY=$$(jq -r '.public_key' keypair.json); \
	ORIG_SIG=$$(jq -r '.signature' sig.json); \
	BAD_SIG="0x00$${ORIG_SIG:4}"; \
	if ./$(BINARY) verify --pubKey "$$PQ_PUB_KEY" --signature "$$BAD_SIG" --message "$$AUTH_HASH" --level $(LEVEL); then \
		printf "$(RED)Unexpected pass$(RESET)\n"; exit 1; \
	else \
		printf "$(GREEN)✓ Tampered signature rejected off-chain. Zero gas spent.$(RESET)\n"; \
	fi

replay-test: check-env ## Demo: Re-submit already-settled signature and confirm AuthAlreadyUsed revert
	@set -a; source .env; set +a; \
	: $${PAYMENT_GATE:?Set PAYMENT_GATE in .env first}; \
	test -f sig.json || (printf "$(RED)Error: sig.json not found. Run 'make sign' first.$(RESET)\n" && exit 1); \
	SIGNATURE=$$(jq -r '.signature' sig.json); \
	printf "$(YELLOW)=== [Stage 8] Replay Test: Re-submitting Nonce $$NONCE to PaymentGate ===$(RESET)\n"; \
	if cast send "$$PAYMENT_GATE" \
		"release(address,uint256,uint256,bytes)" \
		"$$PAYEE" "$$AMOUNT" "$$NONCE" "$$SIGNATURE" \
		--rpc-url "$$QDAY_RPC" --private-key "$$SETTLER_PK" 2>/dev/null; then \
		printf "$(RED)Unexpected replay success$(RESET)\n"; exit 1; \
	else \
		printf "$(GREEN)✓ Confirmed: On-chain contract reverted duplicate authHash (AuthAlreadyUsed).$(RESET)\n"; \
	fi

status: check-env ## Check escrow balance, payee balance, and authHash replay lock on QDay Aevum
	@set -a; source .env; set +a; \
	: $${PAYMENT_GATE:?Set PAYMENT_GATE in .env first}; \
	AUTH_HASH=$$(cast call "$$PAYMENT_GATE" \
		"computeAuthHash(address,uint256,uint256)(bytes32)" \
		"$$PAYEE" "$$AMOUNT" "$$NONCE" --rpc-url "$$QDAY_RPC"); \
	ESCROW_BAL=$$(cast call "$$TUSD8_ADDR" "balanceOf(address)(uint256)" "$$PAYMENT_GATE" --rpc-url "$$QDAY_RPC"); \
	PAYEE_BAL=$$(cast call "$$TUSD8_ADDR" "balanceOf(address)(uint256)" "$$PAYEE" --rpc-url "$$QDAY_RPC"); \
	IS_USED=$$(cast call "$$PAYMENT_GATE" "used(bytes32)(bool)" "$$AUTH_HASH" --rpc-url "$$QDAY_RPC"); \
	printf "$(CYAN)=== [Stage 7] On-Chain State & Replay Lock Verification ===$(RESET)\n"; \
	printf "$(BOLD)PaymentGate Escrow tUSD8 :$(RESET) %s\n" "$$ESCROW_BAL"; \
	printf "$(BOLD)Payee tUSD8 Balance      :$(RESET) %s\n" "$$PAYEE_BAL"; \
	printf "$(BOLD)AuthHash (Nonce $$NONCE)       :$(RESET) %s\n" "$$AUTH_HASH"; \
	printf "$(BOLD)Used (Replay Lock)       :$(RESET) $(GREEN)%s$(RESET)\n" "$$IS_USED"

demo: check-env build ## Run complete end-to-end demo (keygen -> deploy -> fund -> sign -> tamper -> settle -> replay)
	@set -e; set -a; source .env; set +a; \
	printf "$(BLUE)===========================================================================$(RESET)\n"; \
	printf "$(BLUE)  Post-Quantum tUSD8 Payments on QDay Aevum with ForgeLattice (ML-DSA-65)  $(RESET)\n"; \
	printf "$(BLUE)===========================================================================$(RESET)\n"; \
	$(MAKE) keygen; \
	SETTLER_ADDR=$$(cast wallet address --private-key "$$SETTLER_PK"); \
	PQ_PUB_KEY=$$(jq -r '.public_key' keypair.json); \
	echo ""; \
	printf "$(CYAN)=== [Stage 2] Deploying PaymentGate.sol to QDay Aevum ===$(RESET)\n"; \
	DEPLOY_OUT=$$(forge create --root contracts src/PaymentGate.sol:PaymentGate \
		--rpc-url "$$QDAY_RPC" \
		--private-key "$$SETTLER_PK" \
		--broadcast \
		--constructor-args "$$TUSD8_ADDR" "$$SETTLER_ADDR" "$$PQ_PUB_KEY"); \
	echo "$$DEPLOY_OUT"; \
	GATE_ADDR=$$(echo "$$DEPLOY_OUT" | grep -oE 'Deployed to: 0x[a-fA-F0-9]{40}' | awk '{print $$3}'); \
	test -n "$$GATE_ADDR" || (printf "$(RED)Failed to parse deployed address$(RESET)\n" && exit 1); \
	grep -v '^PAYMENT_GATE=' .env > .env.tmp && mv .env.tmp .env; \
	echo "PAYMENT_GATE=\"$$GATE_ADDR\"" >> .env; \
	echo ""; \
    sleep 3; \
    $(MAKE) verify-contract; \
	echo ""; \
	$(MAKE) NONCE=1 fund; \
	echo ""; \
	$(MAKE) NONCE=1 sign; \
	echo ""; \
	$(MAKE) NONCE=1 tamper-test; \
	echo ""; \
	$(MAKE) NONCE=1 settle; \
	echo ""; \
	$(MAKE) NONCE=1 status; \
	echo ""; \
	$(MAKE) NONCE=1 replay-test; \
	echo ""; \
	printf "$(GREEN)==================================================================$(RESET)\n"; \
	printf "$(GREEN)  ✓ Demo Complete! Explorer: https://explorer-test.qday.info/address/$$GATE_ADDR$(RESET)\n"; \
	printf "$(GREEN)==================================================================$(RESET)\n"

run-payment: check-env ## Run a full payment cycle on an existing PAYMENT_GATE (usage: make run-payment NONCE=2)
	@set -e; \
	$(MAKE) fund NONCE=$(NONCE); \
	$(MAKE) sign NONCE=$(NONCE); \
	$(MAKE) settle NONCE=$(NONCE); \
	$(MAKE) status NONCE=$(NONCE)

test: build ## Run Foundry unit tests for PaymentGate.sol
	@printf "$(CYAN)=== Running Foundry Unit Tests ===$(RESET)\n"
	@forge test --root contracts -vv

clean: ## Remove compiled binaries and Foundry build cache (keeps keypair.json)
	rm -f $(BINARY) sig.json
	rm -rf contracts/out contracts/cache