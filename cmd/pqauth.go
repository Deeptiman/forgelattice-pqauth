package cmd

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/Deeptiman/forgelattice/crypto/dsa"
	"github.com/spf13/cobra"
)

// FIPS 204 exact byte sizes per ML-DSA parameter set
var fips204Sizes = map[string]struct {
	pkBytes  int
	skBytes  int
	sigBytes int
}{
	"44": {pkBytes: 1312, skBytes: 2560, sigBytes: 2420},
	"65": {pkBytes: 1952, skBytes: 4032, sigBytes: 3309},
	"87": {pkBytes: 2592, skBytes: 4896, sigBytes: 4627},
}

var pqauthCmd = &cobra.Command{
	Use:          "pqauth",
	Short:        "ForgeLattice ML-DSA (FIPS 204) keygen, sign, and verify CLI",
	SilenceUsage: true,
}

var pqauthKeyGenCmd = &cobra.Command{
	Use:   "keygen",
	Short: "Generate and validate an ML-DSA keypair from a 32-byte seed",
	RunE: func(cmd *cobra.Command, args []string) error {
		seedHex, _ := cmd.Flags().GetString("seed")
		level, _ := cmd.Flags().GetString("level")

		spec, ok := fips204Sizes[level]
		if !ok {
			return fmt.Errorf("unsupported level %q: must be 44, 65, or 87", level)
		}

		seedBytes, err := decodeHexStrict(seedHex, 32, "seed")
		if err != nil {
			return err
		}

		var seed32 [32]byte
		copy(seed32[:], seedBytes)

		d := dsa.WithFIPS204(dsa.ToLevel("ML-DSA-" + level))
		pk, sk := d.GenerateKeyPair(seed32)

		pkBytes := d.MarshalPublicKey(pk)
		skBytes := d.MarshalPrivateKey(sk)

		if len(pkBytes) != spec.pkBytes || len(skBytes) != spec.skBytes {
			return fmt.Errorf("unexpected key size generated: pk=%d, sk=%d", len(pkBytes), len(skBytes))
		}

		printJSON(map[string]any{
			"algorithm":   "ML-DSA-" + level,
			"public_key":  "0x" + hex.EncodeToString(pkBytes),
			"private_key": "0x" + hex.EncodeToString(skBytes),
			"pk_bytes":    len(pkBytes),
			"sk_bytes":    len(skBytes),
		})
		return nil
	},
}

var pqauthSignCmd = &cobra.Command{
	Use:   "sign",
	Short: "Sign a 32-byte authHash with an ML-DSA private key",
	RunE: func(cmd *cobra.Command, args []string) error {
		skHex, _ := cmd.Flags().GetString("privKey")
		msgHex, _ := cmd.Flags().GetString("message")
		level, _ := cmd.Flags().GetString("level")

		spec, ok := fips204Sizes[level]
		if !ok {
			return fmt.Errorf("unsupported level %q: must be 44, 65, or 87", level)
		}

		sk, err := decodeHexStrict(skHex, spec.skBytes, "privKey")
		if err != nil {
			return err
		}
		msg, err := decodeHexStrict(msgHex, 32, "message (authHash)")
		if err != nil {
			return err
		}

		d := dsa.WithFIPS204(dsa.ToLevel("ML-DSA-" + level))
		var rnd [32]byte // deterministic hedged signing
		sig := d.Sign(sk, msg, rnd)

		if len(sig) != spec.sigBytes {
			return fmt.Errorf("unexpected signature size: got %d, want %d", len(sig), spec.sigBytes)
		}

		printJSON(map[string]any{
			"algorithm": "ML-DSA-" + level,
			"auth_hash": "0x" + hex.EncodeToString(msg),
			"signature": "0x" + hex.EncodeToString(sig),
			"sig_bytes": len(sig),
		})
		return nil
	},
}

var pqauthVerifyCmd = &cobra.Command{
	Use:   "verify",
	Short: "Validate key/signature lengths and verify an ML-DSA signature",
	RunE: func(cmd *cobra.Command, args []string) error {
		pkHex, _ := cmd.Flags().GetString("pubKey")
		sigHex, _ := cmd.Flags().GetString("signature")
		msgHex, _ := cmd.Flags().GetString("message")
		level, _ := cmd.Flags().GetString("level")

		spec, ok := fips204Sizes[level]
		if !ok {
			return fmt.Errorf("unsupported level %q: must be 44, 65, or 87", level)
		}

		pk, err := decodeHexStrict(pkHex, spec.pkBytes, "pubKey")
		if err != nil {
			return err
		}
		sig, err := decodeHexStrict(sigHex, spec.sigBytes, "signature")
		if err != nil {
			return err
		}
		msg, err := decodeHexStrict(msgHex, 32, "message (authHash)")
		if err != nil {
			return err
		}

		d := dsa.WithFIPS204(dsa.ToLevel("ML-DSA-" + level))
		valid := d.Verify(pk, sig, msg)

		printJSON(map[string]any{
			"algorithm": "ML-DSA-" + level,
			"auth_hash": "0x" + hex.EncodeToString(msg),
			"valid":     valid,
		})
		if !valid {
			return fmt.Errorf("ML-DSA signature verification failed")
		}
		return nil
	},
}

func Execute() {
	if err := pqauthCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func init() {
	pqauthKeyGenCmd.Flags().String("seed", "", "32-byte seed (hex)")
	pqauthKeyGenCmd.Flags().String("level", "65", "ML-DSA security level: 44, 65, 87")

	pqauthSignCmd.Flags().String("privKey", "", "ML-DSA private key (hex)")
	pqauthSignCmd.Flags().String("message", "", "32-byte authHash from PaymentGate.computeAuthHash() (hex)")
	pqauthSignCmd.Flags().String("level", "65", "ML-DSA security level: 44, 65, 87")

	pqauthVerifyCmd.Flags().String("pubKey", "", "ML-DSA public key (hex)")
	pqauthVerifyCmd.Flags().String("signature", "", "ML-DSA signature (hex)")
	pqauthVerifyCmd.Flags().String("message", "", "32-byte authHash (hex)")
	pqauthVerifyCmd.Flags().String("level", "65", "ML-DSA security level: 44, 65, 87")

	pqauthCmd.AddCommand(pqauthKeyGenCmd, pqauthSignCmd, pqauthVerifyCmd)
}

func decodeHexStrict(s string, expectedLen int, field string) ([]byte, error) {
	clean := strings.TrimPrefix(strings.TrimSpace(s), "0x")
	if clean == "" {
		return nil, fmt.Errorf("missing required flag: --%s", field)
	}
	b, err := hex.DecodeString(clean)
	if err != nil {
		return nil, fmt.Errorf("invalid hex for %s: %w", field, err)
	}
	if len(b) != expectedLen {
		return nil, fmt.Errorf("invalid %s length: got %d bytes, expected %d bytes", field, len(b), expectedLen)
	}
	return b, nil
}

func printJSON(v any) {
	data, _ := json.MarshalIndent(v, "", "  ")
	fmt.Println(string(data))
}
