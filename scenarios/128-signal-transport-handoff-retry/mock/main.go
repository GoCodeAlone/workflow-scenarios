package main

import (
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"
	"sync"
)

type message struct {
	ID                   string `json:"id"`
	RecipientRef         string `json:"recipient_ref"`
	TransportPayloadJSON string `json:"transport_payload_json"`
	Acked                bool   `json:"acked"`
	Released             bool   `json:"released"`
}

type state struct {
	Messages     []message `json:"messages"`
	PublishCount int       `json:"publish_count"`
	FetchCount   int       `json:"fetch_count"`
	AckCount     int       `json:"ack_count"`
	ReleaseCount int       `json:"release_count"`
}

type server struct {
	mu    sync.Mutex
	path  string
	state state
}

func main() {
	addr := flag.String("addr", "127.0.0.1:19128", "listen address")
	path := flag.String("path", "", "state file path")
	flag.Parse()
	if *path == "" {
		log.Fatal("--path is required")
	}
	s := &server{path: *path}
	if err := s.load(); err != nil {
		log.Fatalf("load state: %v", err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("/publish", s.publish)
	mux.HandleFunc("/fetch", s.fetch)
	mux.HandleFunc("/ack", s.ack)
	mux.HandleFunc("/release", s.release)
	mux.HandleFunc("/state", s.dumpState)
	log.Printf("mock signal transport listening on %s", *addr)
	log.Fatal(http.ListenAndServe(*addr, mux))
}

func (s *server) publish(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var in struct {
		ID                   string `json:"id"`
		RecipientRef         string `json:"recipient_ref"`
		TransportPayloadJSON string `json:"transport_payload_json"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	if in.ID == "" || in.RecipientRef == "" || in.TransportPayloadJSON == "" {
		http.Error(w, "id, recipient_ref, and transport_payload_json are required", http.StatusBadRequest)
		return
	}
	if !json.Valid([]byte(in.TransportPayloadJSON)) {
		http.Error(w, "transport_payload_json must contain JSON", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state.PublishCount++
	s.state.Messages = append(s.state.Messages, message{
		ID:                   in.ID,
		RecipientRef:         in.RecipientRef,
		TransportPayloadJSON: in.TransportPayloadJSON,
	})
	if err := s.writeLocked(); err != nil {
		http.Error(w, "write state", http.StatusInternalServerError)
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"status": "published", "id": in.ID})
}

func (s *server) fetch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	recipientRef := r.URL.Query().Get("recipient_ref")
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state.FetchCount++
	for _, msg := range s.state.Messages {
		if msg.RecipientRef == recipientRef && !msg.Acked && !msg.Released {
			if err := s.writeLocked(); err != nil {
				http.Error(w, "write state", http.StatusInternalServerError)
				return
			}
			_ = json.NewEncoder(w).Encode(msg)
			return
		}
	}
	if err := s.writeLocked(); err != nil {
		http.Error(w, "write state", http.StatusInternalServerError)
		return
	}
	http.Error(w, "not found", http.StatusNotFound)
}

func (s *server) ack(w http.ResponseWriter, r *http.Request) {
	s.mark(w, r, "acked")
}

func (s *server) release(w http.ResponseWriter, r *http.Request) {
	s.mark(w, r, "released")
}

func (s *server) mark(w http.ResponseWriter, r *http.Request, status string) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	id := r.URL.Query().Get("id")
	if id == "" {
		http.Error(w, "id is required", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.Messages {
		if s.state.Messages[i].ID != id {
			continue
		}
		switch status {
		case "acked":
			s.state.Messages[i].Acked = true
			s.state.AckCount++
		case "released":
			s.state.Messages[i].Released = true
			s.state.ReleaseCount++
		}
		if err := s.writeLocked(); err != nil {
			http.Error(w, "write state", http.StatusInternalServerError)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"status": status, "id": id})
		return
	}
	http.Error(w, "not found", http.StatusNotFound)
}

func (s *server) dumpState(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	_ = json.NewEncoder(w).Encode(s.state)
}

func (s *server) load() error {
	raw, err := os.ReadFile(s.path)
	if os.IsNotExist(err) || len(raw) == 0 {
		return nil
	}
	if err != nil {
		return err
	}
	return json.Unmarshal(raw, &s.state)
}

func (s *server) writeLocked() error {
	raw, err := json.MarshalIndent(s.state, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.path, raw, 0o600)
}
