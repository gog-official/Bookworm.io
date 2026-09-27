package main

import (
    "flag"
    "fmt"
    "log"
    "net/http"
    "os"
    "path/filepath"
    "strconv"
    "strings"
    "time"

    "server/internal/server"
    "server/internal/server/clients"

    "github.com/joho/godotenv"
)

const (
    dockerMountedDataDir  = "/gameserver/data"
    dockerMountedCertsDir = "/gameserver/certs"
    keepAliveInterval     = 2 * time.Minute
)

type config struct {
    DataPath string
    Port     int
    CertPath string
    KeyPath  string
}

var (
    defaultConfig = &config{Port: 8080}
    configPath    = flag.String("config", ".env", "Path to the config file")
)

func loadConfig() *config {
    cfg := defaultConfig
    cfg.DataPath = os.Getenv("DATA_PATH")
    cfg.CertPath = os.Getenv("CERT_PATH")
    cfg.KeyPath = os.Getenv("KEY_PATH")

    port, err := strconv.Atoi(os.Getenv("PORT"))
    if err != nil {
        log.Printf("Error parsing PORT, using %d", cfg.Port)
        return cfg
    }
    cfg.Port = port
    return cfg
}

func coalescePaths(fallbacks ...string) string {
    for i, path := range fallbacks {
        if _, err := os.Stat(path); os.IsNotExist(err) {
            message := fmt.Sprintf("File/folder not found at %s", path)
            if i < len(fallbacks)-1 {
                log.Printf("%s - going to try %s", message, fallbacks[i+1])
            } else {
                log.Printf("%s - no more fallbacks to try", message)
            }
        } else {
            log.Printf("File/folder found at %s", path)
            return path
        }
    }
    return ""
}

func resolveLiveCertsPath(certPath string) string {
    normalizedPath := strings.ReplaceAll(certPath, "\\", "/")
    pathComponents := strings.Split(normalizedPath, "/live/")

    if len(pathComponents) >= 2 {
        pathTail := pathComponents[len(pathComponents)-1]

        return coalescePaths(certPath, filepath.Join(dockerMountedCertsDir, "live", pathTail))
    }

    return certPath
}

func keepAlive(addr string) {
    url := fmt.Sprintf("http://127.0.0.1%s/health", addr)
    client := &http.Client{Timeout: 10 * time.Second}

    for range time.Tick(keepAliveInterval) {
        resp, err := client.Get(url)
        if err != nil {
            log.Printf("Keep-alive request failed: %v", err)
            continue
        }
        resp.Body.Close()
    }
}

func main() {
    flag.Parse()
    if err := godotenv.Load(*configPath); err != nil {
        log.Printf("No config file at %s, using environment variables and defaults", *configPath)
    }
    cfg := loadConfig()

    cfg.DataPath = coalescePaths(cfg.DataPath, dockerMountedDataDir, ".")
    hub := server.NewHub(cfg.DataPath)

    http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
        w.WriteHeader(http.StatusOK)
    })

    http.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
        hub.Serve(clients.NewWebSocketClient, w, r)
    })
    go hub.Run()
    addr := fmt.Sprintf(":%d", cfg.Port)

    log.Printf("Starting server on %s", addr)

    go keepAlive(addr)

    cfg.CertPath = resolveLiveCertsPath(cfg.CertPath)
    cfg.KeyPath = resolveLiveCertsPath(cfg.KeyPath)

    log.Printf("Using cert at %s and key at %s", cfg.CertPath, cfg.KeyPath)
    err := http.ListenAndServeTLS(addr, cfg.CertPath, cfg.KeyPath, nil)

    if err != nil {
        log.Printf("No certificate found (%v), starting server without TLS", err)
        err = http.ListenAndServe(addr, nil)
        if err != nil {
            log.Fatalf("Failed to start server: %v", err)
        }
    }
}
