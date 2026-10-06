// hello is the smallest useful service for a pipeline demo: it answers on /, reports health on /healthz,
// and says which pipeline built it, so the two images this repository publishes can be told apart.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

var builtBy = "dev" // set at build time: -ldflags "-X main.builtBy=hardened"

func handler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"message":  "hello from a Chainguard image",
		"built_by": builtBy,
	})
}

func healthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}

func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/", handler)
	mux.HandleFunc("/healthz", healthz)
	return mux
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	srv := &http.Server{Addr: ":" + port, Handler: newMux(), ReadHeaderTimeout: 5 * time.Second}
	log.Printf("listening on :%s (built by %s)", port, builtBy)
	log.Fatal(srv.ListenAndServe())
}
