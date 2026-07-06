package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
)

type state struct {
	GenerationRef string                     `json:"generation_ref"`
	Snapshots     map[string]json.RawMessage `json:"snapshots"`
	GetCount      int                        `json:"get_count"`
	PutCount      int                        `json:"put_count"`
	AuthCount     int                        `json:"auth_count"`
	LastStoreRef  string                     `json:"last_store_ref"`
}

type persistRequest struct {
	StoreRef              string          `json:"store_ref"`
	PreviousGenerationRef string          `json:"previous_generation_ref"`
	Snapshot              json.RawMessage `json:"snapshot"`
}

func main() {
	addr := flag.String("addr", "127.0.0.1:19126", "listen address")
	path := flag.String("path", "", "state file path")
	authHeader := flag.String("auth-header", "X-Workflow-Signal-Store-Token", "required auth header")
	authToken := flag.String("auth-token", "", "required auth token")
	flag.Parse()
	if *path == "" {
		log.Fatal("--path is required")
	}

	s := &server{
		path:       *path,
		authHeader: *authHeader,
		authToken:  *authToken,
		state: state{
			Snapshots: map[string]json.RawMessage{},
		},
	}
	if err := s.load(); err != nil {
		log.Fatalf("load state: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("/snapshot", s.snapshot)
	mux.HandleFunc("/control/conflict", s.conflict)
	mux.HandleFunc("/control/corrupt", s.corrupt)
	log.Printf("mock signal envelope HTTP store listening on %s", *addr)
	log.Fatal(http.ListenAndServe(*addr, mux))
}

type server struct {
	mu         sync.Mutex
	path       string
	authHeader string
	authToken  string
	state      state
}

func (s *server) snapshot(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	storeRef := r.URL.Query().Get("store_ref")
	if storeRef == "" {
		http.Error(w, "store_ref is required", http.StatusBadRequest)
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.state.AuthCount++
	s.state.LastStoreRef = storeRef

	switch r.Method {
	case http.MethodGet:
		s.state.GetCount++
		s.writeStateLocked(w)
		snapshot := s.state.Snapshots[storeRef]
		if len(snapshot) == 0 {
			_ = json.NewEncoder(w).Encode(map[string]string{
				"status":         "not_found",
				"generation_ref": s.state.GenerationRef,
			})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"status":         "ok",
			"generation_ref": s.state.GenerationRef,
			"snapshot":       json.RawMessage(snapshot),
		})
	case http.MethodPut:
		var req persistRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "bad json", http.StatusBadRequest)
			return
		}
		if req.StoreRef != storeRef {
			http.Error(w, "store_ref mismatch", http.StatusBadRequest)
			return
		}
		if req.PreviousGenerationRef != s.state.GenerationRef {
			http.Error(w, "generation conflict", http.StatusConflict)
			return
		}
		if len(req.Snapshot) == 0 || !json.Valid(req.Snapshot) {
			http.Error(w, "snapshot is required", http.StatusBadRequest)
			return
		}
		s.state.PutCount++
		s.state.GenerationRef = fmt.Sprintf("generation-%06d", s.state.PutCount)
		s.state.Snapshots[storeRef] = append(json.RawMessage(nil), req.Snapshot...)
		s.writeStateLocked(w)
		_ = json.NewEncoder(w).Encode(map[string]string{
			"status":         "ok",
			"generation_ref": s.state.GenerationRef,
		})
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *server) conflict(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state.GenerationRef = fmt.Sprintf("generation-conflict-%06d", s.state.PutCount+1)
	s.writeStateLocked(w)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"status":         "ok",
		"generation_ref": s.state.GenerationRef,
	})
}

func (s *server) corrupt(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	storeRef := r.URL.Query().Get("store_ref")
	if storeRef == "" {
		http.Error(w, "store_ref is required", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state.Snapshots[storeRef] = json.RawMessage(`{"schema_version":1,"store_ref":"` + storeRef + `","checksum":"sha256:bad","state":{"version":1,"outbox":{},"inbox":{}}}`)
	s.writeStateLocked(w)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func (s *server) authorized(r *http.Request) bool {
	return s.authToken == "" || r.Header.Get(s.authHeader) == s.authToken
}

func (s *server) load() error {
	raw, err := os.ReadFile(s.path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if len(raw) == 0 {
		return nil
	}
	if err := json.Unmarshal(raw, &s.state); err != nil {
		return err
	}
	if s.state.Snapshots == nil {
		s.state.Snapshots = map[string]json.RawMessage{}
	}
	return nil
}

func (s *server) writeStateLocked(w http.ResponseWriter) {
	raw, err := json.MarshalIndent(s.state, "", "  ")
	if err != nil {
		http.Error(w, "encode state", http.StatusInternalServerError)
		return
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		http.Error(w, "write state", http.StatusInternalServerError)
		return
	}
	if err := os.Rename(tmp, s.path); err != nil {
		http.Error(w, "replace state", http.StatusInternalServerError)
	}
}
