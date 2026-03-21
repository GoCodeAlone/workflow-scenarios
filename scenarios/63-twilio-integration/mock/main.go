// Mock Twilio API server for scenario 51-twilio-integration.
// Returns canned Twilio JSON responses for SMS, messaging, verify, voice, and lookup APIs.
// Usage: MOCK_PORT=19051 ./mock-twilio
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strings"
	"time"
)

func main() {
	port := os.Getenv("MOCK_PORT")
	if port == "" {
		port = "19051"
	}
	mux := http.NewServeMux()

	// SMS / Messages — POST creates, GET lists
	mux.HandleFunc("/2010-04-01/Accounts/", handleAccounts)

	// Verify v2 — verifications and checks
	mux.HandleFunc("/v2/Services/", handleVerify)

	// Lookups v2
	mux.HandleFunc("/v2/PhoneNumbers/", handleLookup)

	addr := ":" + port
	log.Printf("mock Twilio API listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

// sid generates a realistic-looking Twilio SID with a given 2-char prefix.
func sid(prefix string) string {
	const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	r := rand.New(rand.NewSource(time.Now().UnixNano()))
	b := make([]byte, 32)
	for i := range b {
		b[i] = chars[r.Intn(len(chars))]
	}
	return prefix + string(b)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// handleAccounts dispatches requests under /2010-04-01/Accounts/{Sid}/...
func handleAccounts(w http.ResponseWriter, r *http.Request) {
	// Strip prefix: /2010-04-01/Accounts/{AccountSid}/
	path := strings.TrimPrefix(r.URL.Path, "/2010-04-01/Accounts/")
	// path is now "{AccountSid}/Messages.json" or "{AccountSid}/Messages/{Sid}.json" etc.
	parts := strings.SplitN(path, "/", 2)
	if len(parts) < 2 {
		http.NotFound(w, r)
		return
	}
	// parts[0] = AccountSid, parts[1] = resource path
	resource := parts[1]

	switch {
	case resource == "Messages.json" && r.Method == http.MethodPost:
		handleSendMessage(w, r)
	case resource == "Messages.json" && r.Method == http.MethodGet:
		handleListMessages(w, r)
	case strings.HasPrefix(resource, "Messages/") && strings.HasSuffix(resource, ".json") && r.Method == http.MethodGet:
		msgSid := strings.TrimSuffix(strings.TrimPrefix(resource, "Messages/"), ".json")
		handleFetchMessage(w, r, msgSid)
	case resource == "Calls.json" && r.Method == http.MethodPost:
		handleCreateCall(w, r)
	case resource == "Calls.json" && r.Method == http.MethodGet:
		handleListCalls(w, r)
	default:
		log.Printf("unmatched: %s %s", r.Method, r.URL.Path)
		http.NotFound(w, r)
	}
}

func handleSendMessage(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	to := r.FormValue("To")
	from := r.FormValue("From")
	body := r.FormValue("Body")
	mediaURL := r.FormValue("MediaUrl")
	if from == "" {
		from = "+15005550006"
	}
	resp := map[string]any{
		"sid":          sid("SM"),
		"status":       "queued",
		"to":           to,
		"from":         from,
		"body":         body,
		"date_created": time.Now().UTC().Format(time.RFC3339),
		"direction":    "outbound-api",
		"price":        nil,
	}
	if mediaURL != "" {
		resp["media_url"] = mediaURL
		resp["num_media"] = "1"
	} else {
		resp["num_media"] = "0"
	}
	writeJSON(w, http.StatusCreated, resp)
}

func handleListMessages(w http.ResponseWriter, r *http.Request) {
	messages := []map[string]any{
		{
			"sid":    sid("SM"),
			"status": "delivered",
			"to":     "+15005550001",
			"from":   "+15005550006",
			"body":   "Hello from mock",
		},
		{
			"sid":    sid("SM"),
			"status": "sent",
			"to":     "+15005550002",
			"from":   "+15005550006",
			"body":   "Second message",
		},
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"messages":        messages,
		"end":             1,
		"first_page_uri":  "/2010-04-01/Accounts/AC_test/Messages.json?Page=0",
		"next_page_uri":   nil,
		"page":            0,
		"page_size":       50,
		"previous_page_uri": nil,
		"start":           0,
		"uri":             "/2010-04-01/Accounts/AC_test/Messages.json",
	})
}

func handleFetchMessage(w http.ResponseWriter, r *http.Request, msgSid string) {
	writeJSON(w, http.StatusOK, map[string]any{
		"sid":          msgSid,
		"status":       "delivered",
		"to":           "+15005550001",
		"from":         "+15005550006",
		"body":         "Fetched message body",
		"date_created": time.Now().UTC().Format(time.RFC3339),
		"direction":    "outbound-api",
		"num_media":    "0",
	})
}

func handleCreateCall(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	to := r.FormValue("To")
	from := r.FormValue("From")
	if from == "" {
		from = "+15005550006"
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"sid":          sid("CA"),
		"status":       "queued",
		"to":           to,
		"from":         from,
		"direction":    "outbound-api",
		"date_created": time.Now().UTC().Format(time.RFC3339),
		"duration":     "0",
	})
}

func handleListCalls(w http.ResponseWriter, r *http.Request) {
	calls := []map[string]any{
		{
			"sid":      sid("CA"),
			"status":   "completed",
			"to":       "+15005550001",
			"from":     "+15005550006",
			"duration": "42",
		},
		{
			"sid":      sid("CA"),
			"status":   "completed",
			"to":       "+15005550002",
			"from":     "+15005550006",
			"duration": "17",
		},
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"calls":          calls,
		"end":            1,
		"first_page_uri": "/2010-04-01/Accounts/AC_test/Calls.json?Page=0",
		"next_page_uri":  nil,
		"page":           0,
		"page_size":      50,
		"start":          0,
		"uri":            "/2010-04-01/Accounts/AC_test/Calls.json",
	})
}

// handleVerify dispatches requests under /v2/Services/{ServiceSid}/...
func handleVerify(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/v2/Services/")
	parts := strings.SplitN(path, "/", 2)
	if len(parts) < 2 {
		http.NotFound(w, r)
		return
	}
	serviceSid := parts[0]
	resource := parts[1]

	switch {
	case resource == "Verifications" && r.Method == http.MethodPost:
		handleSendVerification(w, r, serviceSid)
	case resource == "VerificationCheck" && r.Method == http.MethodPost:
		handleCheckVerification(w, r, serviceSid)
	case resource == "PhoneNumbers" && r.Method == http.MethodPost:
		handleAddPhoneNumber(w, r, serviceSid)
	default:
		log.Printf("unmatched verify: %s %s", r.Method, r.URL.Path)
		http.NotFound(w, r)
	}
}

func handleSendVerification(w http.ResponseWriter, r *http.Request, serviceSid string) {
	_ = r.ParseForm()
	to := r.FormValue("To")
	channel := r.FormValue("Channel")
	if channel == "" {
		channel = "sms"
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"sid":         sid("VE"),
		"service_sid": serviceSid,
		"to":          to,
		"channel":     channel,
		"status":      "pending",
		"date_created": time.Now().UTC().Format(time.RFC3339),
	})
}

func handleCheckVerification(w http.ResponseWriter, r *http.Request, serviceSid string) {
	_ = r.ParseForm()
	to := r.FormValue("To")
	writeJSON(w, http.StatusOK, map[string]any{
		"sid":         sid("VE"),
		"service_sid": serviceSid,
		"to":          to,
		"channel":     "sms",
		"status":      "approved",
		"valid":       true,
		"date_created": time.Now().UTC().Format(time.RFC3339),
	})
}

func handleAddPhoneNumber(w http.ResponseWriter, r *http.Request, serviceSid string) {
	_ = r.ParseForm()
	phone := r.FormValue("PhoneNumber")
	writeJSON(w, http.StatusCreated, map[string]any{
		"sid":          sid("PN"),
		"service_sid":  serviceSid,
		"phone_number": phone,
		"country_code": "US",
		"date_created": time.Now().UTC().Format(time.RFC3339),
	})
}

// handleLookup handles GET /v2/PhoneNumbers/{PhoneNumber}
func handleLookup(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.NotFound(w, r)
		return
	}
	phone := strings.TrimPrefix(r.URL.Path, "/v2/PhoneNumbers/")
	// URL-decode the phone number (e.g., %2B15005550001 -> +15005550001)
	phone = strings.ReplaceAll(phone, "%2B", "+")
	writeJSON(w, http.StatusOK, map[string]any{
		"phone_number":    fmt.Sprintf("+%s", strings.TrimPrefix(phone, "+")),
		"country_code":    "US",
		"national_format": "(500) 555-0001",
		"valid":           true,
		"url":             fmt.Sprintf("https://lookups.twilio.com/v2/PhoneNumbers/%s", phone),
	})
}
