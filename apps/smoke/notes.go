package main

// Phase 6.3b (ADR-0023): smoke is the reference application's edge.
// GET and POST /api/notes forward to the notes service at NOTES_URL
// (e.g. http://platform-notes-dev-standard-workload:8080), path /notes.
// Unset NOTES_URL leaves the routes unregistered (404, as before), so an
// environment gets them only when its overlay points at notes.
//
//   - request bodies are capped at 4 KiB, responses at 1 MiB;
//   - notes' 2xx and 4xx answers pass through unchanged (status and JSON);
//   - a notes 5xx, a timeout or a connection error becomes 502 with a
//     JSON error, so a broken dependency shows in smoke's own 5xx share -
//     the SLI covers the whole chain.

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	notesMaxRequest  = 4 << 10
	notesMaxResponse = 1 << 20
)

func parseNotesURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "http" || u.Host == "" || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.User != nil {
		return nil, errors.New("NOTES_URL must be http://host[:port] with no path, query or credentials")
	}
	return u, nil
}

func notesProxy(base *url.URL, client *http.Client) http.HandlerFunc {
	target := strings.TrimSuffix(base.String(), "/") + "/notes"
	fail := func(w http.ResponseWriter) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte(`{"error":"notes unavailable"}` + "\n"))
	}
	return func(w http.ResponseWriter, r *http.Request) {
		// Read the whole (capped) body first: forwarding the stream would
		// go out chunked, and notes' standard-library server reads only
		// Content-Length (found by the 6.3b lab test).
		payload, err := io.ReadAll(http.MaxBytesReader(w, r.Body, notesMaxRequest))
		if err != nil {
			var tooLarge *http.MaxBytesError
			if errors.As(err, &tooLarge) {
				http.Error(w, `{"error":"body too large"}`, http.StatusRequestEntityTooLarge)
				return
			}
			fail(w)
			return
		}
		req, err := http.NewRequestWithContext(r.Context(), r.Method, target, bytes.NewReader(payload))
		if err != nil {
			fail(w)
			return
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			fail(w)
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode >= 500 {
			fail(w)
			return
		}
		body, err := io.ReadAll(io.LimitReader(resp.Body, notesMaxResponse))
		if err != nil {
			fail(w)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(resp.StatusCode)
		_, _ = w.Write(body)
	}
}

func newNotesClient() *http.Client {
	return &http.Client{Timeout: 3 * time.Second}
}
