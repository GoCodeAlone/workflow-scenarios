package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"

	"github.com/GoCodeAlone/workflow-plugin-control-plane/descriptors"
	descriptorspb "github.com/GoCodeAlone/workflow-plugin-control-plane/descriptors/pb"
	"github.com/GoCodeAlone/workflow-plugin-control-plane/envelopes"
	envelopespb "github.com/GoCodeAlone/workflow-plugin-control-plane/envelopes/pb"
	"github.com/GoCodeAlone/workflow-plugin-control-plane/registry"
	registrypb "github.com/GoCodeAlone/workflow-plugin-control-plane/registry/pb"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

type bundleFile struct {
	Kind    string          `json:"kind"`
	Payload json.RawMessage `json:"payload"`
}

type validationResult struct {
	Path  string
	Kind  string
	Error string
}

func main() {
	output, err := runValidation(os.Args[1:])
	fmt.Print(output)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func runValidation(args []string) (string, error) {
	fs := flag.NewFlagSet("control-plane-descriptor-validator", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	validDir := fs.String("valid-dir", "", "directory containing valid bundle JSON files")
	invalidDir := fs.String("invalid-dir", "", "directory containing invalid bundle JSON files")
	if err := fs.Parse(args); err != nil {
		return "", err
	}
	if *validDir == "" || *invalidDir == "" {
		return "", fmt.Errorf("--valid-dir and --invalid-dir are required")
	}

	var out bytes.Buffer
	validCount, err := validateDir(&out, *validDir, true)
	if err != nil {
		return out.String(), err
	}
	invalidCount, err := validateDir(&out, *invalidDir, false)
	if err != nil {
		return out.String(), err
	}
	fmt.Fprintf(&out, "SUMMARY: valid=%d invalid=%d public_contract=%s\n", validCount, invalidCount, descriptors.Version)
	return out.String(), nil
}

func validateDir(out io.Writer, dir string, expectValid bool) (int, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return 0, err
	}
	sort.Strings(files)
	if len(files) == 0 {
		return 0, fmt.Errorf("no bundle fixtures found in %s", dir)
	}
	for _, file := range files {
		result, err := validateBundleFile(file, expectValid)
		if err != nil {
			return 0, err
		}
		status := "accepted"
		if !expectValid {
			status = "rejected"
		}
		fmt.Fprintf(out, "PASS: %s %s as %s\n", filepath.Base(file), status, result.Kind)
	}
	return len(files), nil
}

func validateBundleFile(path string, expectValid bool) (validationResult, error) {
	result := validationResult{Path: path}
	data, err := os.ReadFile(path)
	if err != nil {
		return result, err
	}
	var bundle bundleFile
	if err := json.Unmarshal(data, &bundle); err != nil {
		return result, err
	}
	result.Kind = bundle.Kind
	err = validateBundle(bundle)
	if expectValid {
		if err != nil {
			result.Error = err.Error()
			return result, fmt.Errorf("%s should be valid: %w", path, err)
		}
		return result, nil
	}
	if err == nil {
		return result, fmt.Errorf("%s should be invalid but passed", path)
	}
	result.Error = err.Error()
	return result, nil
}

func validateBundle(bundle bundleFile) error {
	if bundle.Kind == "" {
		return fmt.Errorf("kind is required")
	}
	if len(bundle.Payload) == 0 {
		return fmt.Errorf("payload is required")
	}
	switch bundle.Kind {
	case "route_action_descriptor":
		var msg descriptorspb.RouteActionDescriptor
		if err := unmarshal(bundle.Payload, &msg); err != nil {
			return err
		}
		return descriptors.ValidateRouteActionDescriptor(&msg)
	case "audit_envelope":
		var msg envelopespb.ControlPlaneEnvelope
		if err := unmarshal(bundle.Payload, &msg); err != nil {
			return err
		}
		return envelopes.ValidateEnvelope(&msg)
	case "descriptor_registration":
		var msg registrypb.DescriptorRegistration
		if err := unmarshal(bundle.Payload, &msg); err != nil {
			return err
		}
		return registry.ValidateDescriptorRegistration(&msg)
	default:
		return fmt.Errorf("unsupported bundle kind %q", bundle.Kind)
	}
}

func unmarshal(data []byte, msg proto.Message) error {
	return protojson.UnmarshalOptions{DiscardUnknown: false}.Unmarshal(data, msg)
}
