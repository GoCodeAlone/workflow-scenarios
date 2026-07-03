package fakes

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

type Directory struct {
	token     string
	storePath string

	mu             sync.Mutex
	entries        map[string]Entry
	requests       []RequestRecord
	tamperMode     string
	lastStoreBytes []byte
}

type PublishRequest struct {
	DirectoryRef string `json:"directory_ref"`
	IntakeRef    string `json:"intake_ref"`
	Entry        Entry  `json:"entry"`
}

type Entry struct {
	Bundle                 map[string]any `json:"bundle"`
	PublicMetadata         map[string]any `json:"public_metadata"`
	BundleSHA256           string         `json:"bundle_sha256"`
	IdentityKeyFingerprint string         `json:"identity_key_fingerprint"`
}

type ResolveResponse struct {
	Status         string         `json:"status"`
	Entry          *Entry         `json:"entry,omitzero"`
	PublicMetadata map[string]any `json:"public_metadata,omitzero"`
}

type RequestRecord struct {
	Method    string `json:"method"`
	Path      string `json:"path"`
	IntakeRef string `json:"intake_ref,omitzero"`
	Audience  string `json:"audience_ref,omitzero"`
}

type snapshot struct {
	Entries  map[string]Entry `json:"entries"`
	Requests []RequestRecord  `json:"requests"`
}

func NewDirectory(storePath, token string) (*Directory, error) {
	d := &Directory{
		token:     token,
		storePath: storePath,
		entries:   map[string]Entry{},
	}
	if storePath == "" {
		return d, nil
	}
	raw, err := os.ReadFile(storePath)
	if os.IsNotExist(err) {
		return d, nil
	}
	if err != nil {
		return nil, err
	}
	var state snapshot
	if err := json.Unmarshal(raw, &state); err != nil {
		return nil, err
	}
	if state.Entries != nil {
		d.entries = state.Entries
	}
	d.requests = state.Requests
	d.lastStoreBytes = raw
	return d, nil
}

func (d *Directory) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/entries", d.serveEntries)
	mux.HandleFunc("/entries/", d.serveEntry)
	mux.HandleFunc("/__admin/tamper", d.serveTamper)
	mux.HandleFunc("/__admin/requests", d.serveRequests)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})
	return mux
}

func (d *Directory) serveEntries(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !d.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	var req PublishRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if req.IntakeRef == "" || req.DirectoryRef == "" || req.Entry.Bundle == nil || req.Entry.PublicMetadata == nil {
		http.Error(w, "invalid entry", http.StatusBadRequest)
		return
	}
	d.mu.Lock()
	d.entries[req.IntakeRef] = req.Entry
	d.requests = append(d.requests, RequestRecord{Method: r.Method, Path: r.URL.Path, IntakeRef: req.IntakeRef})
	err := d.persistLocked()
	d.mu.Unlock()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusAccepted)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "accepted"})
}

func (d *Directory) serveEntry(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !d.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	intakeRef, err := url.PathUnescape(strings.TrimPrefix(r.URL.Path, "/entries/"))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	audienceRef := r.URL.Query().Get("audience_ref")
	requestedAt, _ := strconv.ParseInt(r.URL.Query().Get("requested_at_unix"), 10, 64)
	d.mu.Lock()
	entry, ok := d.entries[intakeRef]
	d.requests = append(d.requests, RequestRecord{Method: r.Method, Path: r.URL.Path, IntakeRef: intakeRef, Audience: audienceRef})
	mode := d.tamperMode
	err = d.persistLocked()
	d.mu.Unlock()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	response := ResolveResponse{Status: "not_found"}
	if ok {
		metadata := cloneMap(entry.PublicMetadata)
		switch {
		case expiresAt(metadata) > 0 && requestedAt > expiresAt(metadata):
			metadata["status"] = "expired"
			response = ResolveResponse{Status: "expired", PublicMetadata: metadata}
		case audienceRef != "" && stringValue(metadata["audience_ref"]) != "" && audienceRef != stringValue(metadata["audience_ref"]):
			metadata["status"] = "audience_mismatch"
			response = ResolveResponse{Status: "audience_mismatch", PublicMetadata: metadata}
			if mode == "denial_bundle" {
				response.Entry = &entry
			}
		default:
			metadata["status"] = "resolved"
			entry.PublicMetadata = metadata
			response = ResolveResponse{Status: "resolved", Entry: &entry, PublicMetadata: metadata}
			if mode == "bundle_hash" {
				response.Entry.BundleSHA256 = "tampered"
			}
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(response)
}

func (d *Directory) serveTamper(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !d.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	mode := r.URL.Query().Get("mode")
	switch mode {
	case "", "bundle_hash", "denial_bundle":
	default:
		http.Error(w, "unknown tamper mode", http.StatusBadRequest)
		return
	}
	d.mu.Lock()
	d.tamperMode = mode
	d.mu.Unlock()
	_ = json.NewEncoder(w).Encode(map[string]string{"tamper_mode": mode})
}

func (d *Directory) serveRequests(w http.ResponseWriter, r *http.Request) {
	if !d.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	d.mu.Lock()
	requests := append([]RequestRecord(nil), d.requests...)
	d.mu.Unlock()
	_ = json.NewEncoder(w).Encode(map[string]any{"requests": requests})
}

func (d *Directory) authorized(r *http.Request) bool {
	return d.token == "" || r.Header.Get("X-Directory-Token") == d.token
}

func (d *Directory) persistLocked() error {
	if d.storePath == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(d.storePath), 0o700); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(snapshot{Entries: d.entries, Requests: d.requests}, "", "  ")
	if err != nil {
		return err
	}
	d.lastStoreBytes = raw
	tmp := d.storePath + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, d.storePath)
}

func cloneMap(in map[string]any) map[string]any {
	out := make(map[string]any, len(in))
	for key, value := range in {
		out[key] = value
	}
	return out
}

func expiresAt(metadata map[string]any) int64 {
	switch value := metadata["expires_at_unix"].(type) {
	case float64:
		return int64(value)
	case string:
		parsed, _ := strconv.ParseInt(value, 10, 64)
		return parsed
	default:
		return 0
	}
}

func stringValue(value any) string {
	switch typed := value.(type) {
	case string:
		return typed
	default:
		return fmt.Sprint(typed)
	}
}
