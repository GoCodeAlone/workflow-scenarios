// Package main — file-backed state store for the DNS stub IaCProvider plugin.
//
// wfctl spawns each plugin process anew per CLI invocation, so the stub
// cannot rely on in-process memory to persist state across `wfctl infra
// apply` followed by `wfctl infra import-all`. Each stub module instance
// gets its own state file path (config key "state_path", env var
// DNS_STUB_STATE_PATH, or a deterministic default keyed off the module's
// provider name) so multi-module scenarios (e.g. parent + child zones
// at different stub instances) can route to different state stores.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

// stubZone is the canonical persisted shape for one DNS zone in stub
// state. The Records list mirrors the records: [...] block in scenario
// configs so apply→import roundtrips return the same shape callers
// declared.
type stubZone struct {
	ID      string           `json:"id"`
	Zone    string           `json:"zone"`
	Records []map[string]any `json:"records"`
	Extras  map[string]any   `json:"extras,omitempty"`
}

// stubStore persists the stub's zone state to a JSON file. All access
// is guarded by mu so concurrent gRPC calls on a single plugin process
// (rare for the stub but valid per the SDK contract) don't race.
type stubStore struct {
	mu   sync.Mutex
	path string
}

func newStubStore(path string) *stubStore { return &stubStore{path: path} }

// load reads the on-disk state file. Returns an empty map when the file
// doesn't exist (first apply path) rather than surfacing the
// fs.ErrNotExist as a user-visible error.
func (s *stubStore) load() (map[string]*stubZone, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.loadLocked()
}

func (s *stubStore) loadLocked() (map[string]*stubZone, error) {
	out := map[string]*stubZone{}
	data, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return out, nil
		}
		return nil, fmt.Errorf("stub store: read %s: %w", s.path, err)
	}
	if len(data) == 0 {
		return out, nil
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, fmt.Errorf("stub store: parse %s: %w", s.path, err)
	}
	return out, nil
}

// save writes the full state map atomically (temp file + rename) so a
// crash mid-write doesn't corrupt the file.
func (s *stubStore) save(zones map[string]*stubZone) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.saveLocked(zones)
}

func (s *stubStore) saveLocked(zones map[string]*stubZone) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return fmt.Errorf("stub store: mkdir parent: %w", err)
	}
	data, err := json.MarshalIndent(zones, "", "  ")
	if err != nil {
		return fmt.Errorf("stub store: marshal: %w", err)
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("stub store: write tmp: %w", err)
	}
	if err := os.Rename(tmp, s.path); err != nil {
		return fmt.Errorf("stub store: rename tmp→final: %w", err)
	}
	return nil
}

// upsert adds or replaces a single zone entry.
func (s *stubStore) upsert(z *stubZone) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	zones, err := s.loadLocked()
	if err != nil {
		return err
	}
	zones[z.ID] = z
	return s.saveLocked(zones)
}

// delete removes a zone entry. No-op when the key is absent.
func (s *stubStore) delete(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	zones, err := s.loadLocked()
	if err != nil {
		return err
	}
	delete(zones, id)
	return s.saveLocked(zones)
}

// get returns a single zone entry; nil when absent.
func (s *stubStore) get(id string) (*stubZone, error) {
	zones, err := s.load()
	if err != nil {
		return nil, err
	}
	return zones[id], nil
}

// list returns every zone in store order (map iteration order
// is non-deterministic; callers needing ordered output sort by ID
// themselves).
func (s *stubStore) list() ([]*stubZone, error) {
	zones, err := s.load()
	if err != nil {
		return nil, err
	}
	out := make([]*stubZone, 0, len(zones))
	for _, z := range zones {
		out = append(out, z)
	}
	return out, nil
}
