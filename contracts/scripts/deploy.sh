#!/usr/bin/env bash
set -euo pipefail

source .env
SETTLER_ADDR=$(cast wallet address --private-key "$SETTLER_PK")

echo "=== 1. Building ForgeLattice CLI ==="
go build -o pqauth main.go

echo "=== 2. Generating ML-DSA-65 Keypair ==="
SEED="0x$(openssl rand -hex 32)"
./pqauth keygen --seed "$SEED" --level 65 > keypair.json
PQ_PUB_KEY=$(jq -r '.public_key' keypair.json)
echo "Generated PK ($(jq -r '.pk_bytes' keypair.json) bytes)"

echo "=== 3. Compiling & Deploying PaymentGate.sol to QDay Aevum ==="
forge build --root contracts
forge create --root contracts src/PaymentGate.sol:PaymentGate \
  --rpc-url "$QDAY_RPC" \
  --private-key "$SETTLER_PK" \
  --broadcast \
  --constructor-args "$TUSD8_ADDR" "$SETTLER_ADDR" "$PQ_PUB_KEY"