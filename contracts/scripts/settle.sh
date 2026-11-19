#!/usr/bin/env bash
set -euo pipefail

source .env
: "${PAYMENT_GATE:?Set PAYMENT_GATE in .env first}"

PQ_PUB_KEY=$(jq -r '.public_key' keypair.json)
PQ_PRIV_KEY=$(jq -r '.private_key' keypair.json)

echo "=== 1. Funding PaymentGate Escrow ($AMOUNT tUSD8 base units) ==="
cast send "$TUSD8_ADDR" "transfer(address,uint256)" "$PAYMENT_GATE" "$AMOUNT" \
  --rpc-url "$QDAY_RPC" --private-key "$SETTLER_PK" > /dev/null

echo "=== 2. Computing On-Chain authHash (Nonce: $NONCE) ==="
AUTH_HASH=$(cast call "$PAYMENT_GATE" \
  "computeAuthHash(address,uint256,uint256)(bytes32)" \
  "$PAYEE" "$AMOUNT" "$NONCE" --rpc-url "$QDAY_RPC")
echo "authHash: $AUTH_HASH"

echo "=== 3. Signing authHash Off-Chain with ForgeLattice ML-DSA-65 ==="
./pqauth sign --privKey "$PQ_PRIV_KEY" --message "$AUTH_HASH" --level 65 > sig.json
SIGNATURE=$(jq -r '.signature' sig.json)

echo "=== 4. Verifying ML-DSA-65 Signature Off-Chain (Hard Gate) ==="
./pqauth verify --pubKey "$PQ_PUB_KEY" --signature "$SIGNATURE" --message "$AUTH_HASH" --level 65

echo "=== 5. Settling tUSD8 On-Chain via PaymentGate.release() ==="
cast send "$PAYMENT_GATE" \
  "release(address,uint256,uint256,bytes)" \
  "$PAYEE" "$AMOUNT" "$NONCE" "$SIGNATURE" \
  --rpc-url "$QDAY_RPC" --private-key "$SETTLER_PK"