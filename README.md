# ForgeLattice PQAuth — Post-Quantum tUSD8 Payment Gate on QDay Aevum

Off-chain **ML-DSA-65 (FIPS 204)** authorization powered by [ForgeLattice](https://github.com/Deeptiman/forgelattice), paired with deterministic on-chain **tUSD8** escrow settlement on the **QDay Aevum Testnet**.

## Overview

Quantum computers threaten elliptic-curve signatures (`ECDSA`) used across standard EVM accounts. **ForgeLattice PQAuth** secures stablecoin disbursements on **QDay Aevum** using NIST-standardized **ML-DSA-65 (FIPS 204)** lattice cryptography:

1. **Off-Chain PQC Authorization (`pqauth` Go CLI):**
   - Generates deterministic or CSPRNG-seeded FIPS 204 `ML-DSA-65` keypairs (`1,952`-byte public key, `4,032`-byte private key).
   - Signs contract-bound payment digests (`3,309`-byte detached signatures) and enforces strict cryptographic verification as a zero-gas pre-broadcast gate.
2. **On-Chain Escrow & Settlement (`PaymentGate.sol`):**
   - Commits to the signer's `1,952`-byte ML-DSA-65 public key and its `keccak256` digest at deployment.
   - Computes `authHash` on-chain bound to domain separator, `chainId`, contract address, public key hash, `payee`, `amount`, and `nonce`.
   - Enforces exact FIPS 204 byte-length invariants, prevents replay attacks (`used[authHash]`), releases escrowed `tUSD8`, and emits `keccak256(signature)` for auditability.
   - *Upgrade-ready:* Designed so QDay's native ML-DSA-65 precompile can be plugged directly into `release()` once enabled on mainnet without altering key formats or CLI workflows.

## Architecture Flow

```text
┌──────────────────────┐     1. computeAuthHash()      ┌───────────────────────────┐
│   ForgeLattice CLI   │ ────────────────────────────► │     PaymentGate.sol       │
│  (pqauth / ML-DSA-65)│ ◄──────────────────────────── │   (QDay Aevum Testnet)    │
└──────────┬───────────┘     2. 32-byte authHash       └─────────────▲─────────────┘
           │                                                         │
           │ 3. Sign authHash (3,309B sig)                           │
           │ 4. Hard Gate: pqauth verify (0 gas if invalid)          │ 5. release(..., sig)
           └─────────────────────────────────────────────────────────┘
                                                                     │
                                                                     ▼
                                                       ┌───────────────────────────┐
                                                       │  tUSD8 Stablecoin Escrow  │
                                                       │   → Transfer to Payee     │
                                                       └───────────────────────────┘
```

## Live QDay Aevum Testnet Deployment

- **Network:** QDay Aevum Testnet (`Chain ID: 44005`, RPC: `https://rpc-test.qday.info`)
- **tUSD8 Token:** [`0x456569838f1d43009A91ebA4263147Afd7233483`](https://explorer-test.qday.info/address/0x456569838f1d43009A91ebA4263147Afd7233483)
- **PaymentGate Contract:** [`0x12f273657f0eE986DB244B10475a6A55D61a425e`](https://explorer-test.qday.info/address/0x12f273657f0eE986DB244B10475a6A55D61a425e)
- **Verified Settlement Tx:** [`0xec4ef32d91338b44f8de7d89ff7bedf5393267cece94eef6cfbce414d6533c4c`](https://explorer-test.qday.info/tx/0xec4ef32d91338b44f8de7d89ff7bedf5393267cece94eef6cfbce414d6533c4c)

## Project Structure

```text
forgelattice-pqauth/
├── cmd/
│   └── pqauth.go            # Cobra CLI commands: keygen, sign, verify
├── contracts/
│   ├── foundry.toml         # Foundry config targeting Shanghai EVM
│   ├── scripts/
│   │   ├── deploy.sh        # Standalone deployment helper
│   │   └── settle.sh        # Standalone sign + verify + release helper
│   └── src/
│       └── PaymentGate.sol  # Post-quantum tUSD8 escrow & settlement contract
├── main.go                  # CLI entrypoint
├── Makefile                 # Color-coded, self-bootstrapping automation
└── README.md
```

## Quickstart

### Prerequisites
- **Go** `1.21+`
- **Foundry** (`forge`, `cast`)
- **`jq`** & **`openssl`**
- Funded QDay Aevum Testnet wallet (`tQDAY` for gas + `tUSD8` for escrow)

### Option 1: One-Command End-to-End Demo (Recommended)

Run the entire workflow in a single command. On first run, `make demo` automatically initializes `.env` (prompting once for `SETTLER_PK` with masked input), compiles the Go CLI and Solidity contract, generates an `ML-DSA-65` keypair, deploys `PaymentGate.sol`, funds `tUSD8` escrow, tests off-chain tamper rejection, settles on-chain, and verifies replay protection:

```bash
make demo
```

### Option 2: Step-by-Step Execution

1. **Build CLI & Smart Contract:**
   ```bash
   make build
   ```

2. **Generate FIPS 204 ML-DSA-65 Keypair:**
   ```bash
   make keygen
   # Outputs keypair.json (PK: 1952B, SK: 4032B)
   ```

3. **Deploy `PaymentGate.sol` to QDay Aevum Testnet:**
   ```bash
   make deploy
   # Add the deployed contract address to .env: PAYMENT_GATE="0x..."
   ```

4. **Fund Escrow with `tUSD8`:**
   ```bash
   make fund
   ```

5. **Sign On-Chain `authHash` Off-Chain:**
   ```bash
   make sign
   # Outputs sig.json (3309B signature)
   ```

6. **Verify Off-Chain & Settle On-Chain:**
   ```bash
   make settle
   make status
   ```

7. **Run Adversarial Security Checks:**
   ```bash
   make tamper-test   # Flips 1 byte in sig.json -> blocked off-chain (0 gas)
   make replay-test   # Re-submits settled nonce -> reverts on-chain (AuthAlreadyUsed)
   ```

## Makefile Reference

| Command | Description |
| :--- | :--- |
| `make help` | Show all available workflow commands |
| `make demo` | Run the full 8-stage end-to-end demo on QDay Aevum Testnet |
| `make build` | Compile the `pqauth` Go binary and `PaymentGate.sol` |
| `make keygen` | Generate a fresh `ML-DSA-65` keypair into `keypair.json` |
| `make deploy` | Deploy `PaymentGate.sol` bound to the generated public key |
| `make fund` | Transfer `AMOUNT` of `tUSD8` base units into `PaymentGate` escrow |
| `make sign` | Query on-chain `computeAuthHash()` and sign into `sig.json` |
| `make verify` | Run off-chain `ML-DSA-65` verification against on-chain `authHash` |
| `make settle` | Enforce off-chain verification gate, then execute `PaymentGate.release()` |
| `make status` | Inspect escrow balance, payee balance, `authHash`, and replay lock |
| `make tamper-test` | Verify that a 1-byte signature mutation is rejected off-chain (`0` gas) |
| `make replay-test` | Verify that re-submitting a used nonce reverts with `AuthAlreadyUsed` |
| `make run-payment NONCE=2` | Execute a subsequent payment cycle on an existing `PAYMENT_GATE` |
| `make clean` | Remove compiled binaries and Foundry build cache |

## Security Invariants

- **Domain & Context Separation:** `authHash` binds `"FORGELATTICE_MLDSA65_PAYMENT_V1"`, `block.chainid` (`44005`), `address(this)`, `keccak256(dilithiumPublicKey)`, `payee`, `amount`, and `nonce`—preventing cross-chain, cross-contract, or parameter-substitution replays.
- **Exact FIPS 204 Sizing:** Both the constructor and `release()` enforce strict `1,952`-byte public keys and `3,309`-byte signatures.
- **Zero-Gas Malformed Rejection:** `make settle` requires `./pqauth verify` to exit `0` before broadcasting `cast send`, blocking invalid signatures without wasting gas.
- **Checks-Effects-Interactions-Events (CEIE):** `used[authHash]` is set to `true` and `Released` is emitted before invoking `tusd8.transfer(...)`.