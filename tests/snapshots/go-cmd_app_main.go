// Command app starts the HTTP service.
package main

import (
	"log"
	"net/http"
	"os"

	"app/internal/server"
)

// version is stamped at release time via -ldflags "-X main.version=...".
var version = "dev"

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "3000"
	}
	log.Printf("app %s listening on :%s", version, port)
	if err := http.ListenAndServe(":"+port, server.New()); err != nil {
		log.Fatal(err)
	}
}
