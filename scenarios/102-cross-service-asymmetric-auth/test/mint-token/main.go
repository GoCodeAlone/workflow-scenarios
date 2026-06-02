// mint-token: minimal stdlib-only ES256 JWT minter for scenario-102 negative test cases.
//
// Usage:
//
//	mint-token -iss http://app-a:8080 -aud app-b [-exp -1m] [-key /path/ec.pem]
//
// When -key is omitted, a fresh ephemeral EC P-256 key is generated.
// The -exp flag accepts Go duration syntax (e.g. 1h, -1m) relative to now.
// Output: a single-line JWT written to stdout.
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"
)

func main() {
	iss := flag.String("iss", "http://app-a:8080", "issuer claim")
	aud := flag.String("aud", "app-b", "audience claim")
	expDur := flag.String("exp", "1h", "expiry duration relative to now (e.g. 1h, -1m)")
	keyPath := flag.String("key", "", "PEM file with EC private key; omit to generate ephemeral key")
	flag.Parse()

	// Load or generate signing key
	var privKey *ecdsa.PrivateKey
	if *keyPath != "" {
		raw, err := os.ReadFile(*keyPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "mint-token: read key: %v\n", err)
			os.Exit(1)
		}
		block, _ := pem.Decode(raw)
		if block == nil {
			fmt.Fprintf(os.Stderr, "mint-token: no PEM block in key file\n")
			os.Exit(1)
		}
		switch block.Type {
		case "EC PRIVATE KEY":
			k, err := x509.ParseECPrivateKey(block.Bytes)
			if err != nil {
				fmt.Fprintf(os.Stderr, "mint-token: parse EC key: %v\n", err)
				os.Exit(1)
			}
			privKey = k
		case "PRIVATE KEY":
			k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
			if err != nil {
				fmt.Fprintf(os.Stderr, "mint-token: parse PKCS8 key: %v\n", err)
				os.Exit(1)
			}
			var ok bool
			privKey, ok = k.(*ecdsa.PrivateKey)
			if !ok {
				fmt.Fprintf(os.Stderr, "mint-token: key is not EC\n")
				os.Exit(1)
			}
		default:
			fmt.Fprintf(os.Stderr, "mint-token: unsupported PEM type %q\n", block.Type)
			os.Exit(1)
		}
	} else {
		k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			fmt.Fprintf(os.Stderr, "mint-token: generate key: %v\n", err)
			os.Exit(1)
		}
		privKey = k
	}

	// Parse expiry duration (supports leading '-' for negative)
	expOffset, err := parseDuration(*expDur)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mint-token: bad -exp %q: %v\n", *expDur, err)
		os.Exit(1)
	}
	now := time.Now()
	exp := now.Add(expOffset)

	// Build JWT header and payload
	header := map[string]any{"alg": "ES256", "typ": "JWT"}
	payload := map[string]any{
		"iss": *iss,
		"aud": *aud,
		"sub": "mint-token-test",
		"iat": now.Unix(),
		"exp": exp.Unix(),
	}

	hdr, err := jsonB64URL(header)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mint-token: encode header: %v\n", err)
		os.Exit(1)
	}
	pay, err := jsonB64URL(payload)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mint-token: encode payload: %v\n", err)
		os.Exit(1)
	}

	sigInput := hdr + "." + pay
	digest := sha256.Sum256([]byte(sigInput))
	r, s, err := ecdsa.Sign(rand.Reader, privKey, digest[:])
	if err != nil {
		fmt.Fprintf(os.Stderr, "mint-token: sign: %v\n", err)
		os.Exit(1)
	}

	// ES256 signature: R || S each padded to 32 bytes big-endian
	sig := make([]byte, 64)
	rb := r.Bytes()
	sb := s.Bytes()
	copy(sig[32-len(rb):32], rb)
	copy(sig[64-len(sb):64], sb)

	fmt.Println(sigInput + "." + base64.RawURLEncoding.EncodeToString(sig))
}

func jsonB64URL(v any) (string, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

// parseDuration wraps time.ParseDuration (which already accepts a leading '-') for
// negative offsets (e.g. "-1m" → token expired 1 minute ago).
func parseDuration(s string) (time.Duration, error) {
	neg := false
	if strings.HasPrefix(s, "-") {
		neg = true
		s = s[1:]
	}
	d, err := time.ParseDuration(s)
	if err != nil {
		return 0, err
	}
	if neg {
		d = -d
	}
	return d, nil
}
