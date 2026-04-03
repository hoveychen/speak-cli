// Package runner manages the kokoro engine subprocess.
//
// On first use it downloads the appropriate engine bundle from GitHub Releases
// and the model files from HuggingFace, then invokes the engine binary as a
// subprocess for each TTS request.
package runner

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/hoveychen/speak-cli/internal/assets"
	"github.com/hoveychen/speak-cli/internal/downloader"
)

// Options controls the behaviour of New.
type Options struct {
	// NoProgress suppresses the download progress bar.
	NoProgress bool
	// CacheDir overrides the default cache directory (~/.cache/speak-cli).
	CacheDir string
}

// Runner holds paths to cached assets and knows how to invoke the engine.
type Runner struct {
	engineExe  string // absolute path to engine binary
	useMLX     bool   // true when MLX engine is active (darwin/arm64 + lang=en)
	modelPath  string // empty for MLX (engine downloads its own model)
	voicesPath string // empty for MLX
	configPath string // non-empty for zh ONNX (Bopomofo vocab config)
	lang       string // "en" or "zh"
	cacheDir   string // cache directory for socket files
}

// defaultCacheDir returns the platform cache directory for speak-cli.
func defaultCacheDir() (string, error) {
	base, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "speak-cli"), nil
}

// supportedLangs is the set of languages accepted by New.
var supportedLangs = map[string]bool{
	"en": true, "zh": true,
	"es": true, "fr": true, "hi": true,
	"it": true, "ja": true, "pt": true,
}

// modelLang returns the model variant ("en" or "zh") required for lang.
func modelLang(lang string) string {
	if lang == "zh" {
		return "zh"
	}
	return "en"
}

// engineLangCode maps a language tag to the single-letter code the Kokoro
// ONNX engine expects via --lang.
func engineLangCode(lang string) string {
	switch lang {
	case "es":
		return "e"
	case "fr":
		return "f"
	case "hi":
		return "h"
	case "it":
		return "i"
	case "ja":
		return "j"
	case "pt":
		return "p"
	case "zh":
		return "z"
	default:
		return "a" // en-US
	}
}

// New prepares a Runner for the given language, downloading the engine and
// model to the cache directory if they are not already present.
func New(lang string, opts Options) (*Runner, error) {
	if !supportedLangs[lang] {
		return nil, fmt.Errorf("unsupported language %q (want: en, zh, es, fr, hi, it, ja, pt)", lang)
	}

	cacheDir := opts.CacheDir
	if cacheDir == "" {
		var err error
		cacheDir, err = defaultCacheDir()
		if err != nil {
			return nil, err
		}
	}

	r := &Runner{lang: lang, cacheDir: cacheDir}

	// On darwin/arm64, prefer MLX for English; fall back to ONNX on failure.
	if runtime.GOOS == "darwin" && runtime.GOARCH == "arm64" && lang == "en" {
		r.useMLX = true
		if err := r.ensureEngine(cacheDir, opts.NoProgress); err != nil {
			fmt.Fprintf(os.Stderr, "MLX engine unavailable (%v), falling back to ONNX.\n", err)
			r.useMLX = false
		}
	}

	if !r.useMLX {
		if err := r.ensureEngine(cacheDir, opts.NoProgress); err != nil {
			return nil, fmt.Errorf("engine setup: %w", err)
		}
	}
	if !r.useMLX {
		if err := r.ensureModel(cacheDir, opts.NoProgress); err != nil {
			return nil, fmt.Errorf("model setup: %w", err)
		}
	}
	return r, nil
}

// Speak synthesises text and writes a WAV file to outputPath.
// If outputPath is empty a temp file is created; the caller is responsible
// for deleting it.
// When using MLX, if the engine fails at runtime it automatically falls back
// to the ONNX engine (e.g. Metal library unavailable on some macOS versions).
func (r *Runner) Speak(text, voice string, speed float64, outputPath string) (string, error) {
	if outputPath == "" {
		f, err := os.CreateTemp("", "speak-*.wav")
		if err != nil {
			return "", err
		}
		f.Close()
		outputPath = f.Name()
	}

	if err := r.ensureDaemon(); err != nil {
		return "", err
	}

	resp, err := r.daemonSpeak(text, voice, speed, outputPath)
	if err != nil || (resp != nil && !resp.OK) {
		if r.useMLX {
			fmt.Fprintf(os.Stderr, "MLX inference failed, falling back to ONNX.\n")
			os.Remove(outputPath)
			r.shutdownDaemon()
			if fallbackErr := r.fallbackToONNX(); fallbackErr != nil {
				return "", fmt.Errorf("MLX failed and ONNX fallback also failed: %w", fallbackErr)
			}
			if err := r.ensureDaemon(); err != nil {
				return "", err
			}
			resp, err = r.daemonSpeak(text, voice, speed, outputPath)
			if err != nil {
				os.Remove(outputPath)
				return "", err
			}
			if !resp.OK {
				os.Remove(outputPath)
				return "", fmt.Errorf("engine error: %s", resp.Error)
			}
			return outputPath, nil
		}
		os.Remove(outputPath)
		if err != nil {
			return "", err
		}
		return "", fmt.Errorf("engine error: %s", resp.Error)
	}
	return outputPath, nil
}

// Close is a no-op. The daemon runs independently and shuts down via idle timeout.
func (r *Runner) Close() {}

// fallbackToONNX switches the runner from MLX to the ONNX engine in-place.
// It downloads/verifies the ONNX engine and model if needed.
func (r *Runner) fallbackToONNX() error {
	r.useMLX = false
	if err := r.ensureEngine(r.cacheDir, true); err != nil {
		return fmt.Errorf("ONNX engine: %w", err)
	}
	return r.ensureModel(r.cacheDir, true)
}

// ── daemon management (Unix socket) ──────────────────────────────────────────

// daemonResponse is the JSON structure returned by the engine daemon.
type daemonResponse struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
	ID    string `json:"id,omitempty"`
}

// sockPath returns the Unix socket path for the current engine configuration.
func (r *Runner) sockPath() string {
	variant := "onnx"
	if r.useMLX {
		variant = "mlx"
	}
	return filepath.Join(r.cacheDir, fmt.Sprintf("daemon-%s-%s.sock", variant, modelLang(r.lang)))
}

// ensureDaemon checks if a daemon is already listening on the socket; if not,
// it starts one and waits until it is ready.
func (r *Runner) ensureDaemon() error {
	sock := r.sockPath()

	// Try connecting to an existing daemon.
	conn, err := net.DialTimeout("unix", sock, 2*time.Second)
	if err == nil {
		conn.Close()
		return nil // daemon is already running
	}

	// No daemon running — clean up stale socket and start a new one.
	os.Remove(sock) //nolint:errcheck

	return r.startDaemon(sock)
}

// startDaemon launches the engine in serve mode and waits for the ready signal.
func (r *Runner) startDaemon(sock string) error {
	args := r.serveArgs(sock)
	cmd := exec.Command(r.engineExe, args...) //nolint:gosec
	cmd.Stderr = os.Stderr

	// We read stdout only for the ready signal, then let the daemon run detached.
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("creating stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("starting engine daemon: %w", err)
	}

	// Release the process so it isn't reaped when this Go process exits.
	go func() { cmd.Wait() }() //nolint:errcheck

	scanner := bufio.NewScanner(stdoutPipe)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	// Wait for the ready signal.
	if !scanner.Scan() {
		cmd.Process.Kill() //nolint:errcheck
		if err := scanner.Err(); err != nil {
			return fmt.Errorf("engine daemon failed to start: %w", err)
		}
		return fmt.Errorf("engine daemon exited before becoming ready")
	}

	var ready struct {
		Ready bool `json:"ready"`
	}
	if err := json.Unmarshal(scanner.Bytes(), &ready); err != nil || !ready.Ready {
		cmd.Process.Kill() //nolint:errcheck
		return fmt.Errorf("engine daemon sent unexpected ready signal: %s", scanner.Text())
	}

	return nil
}

// serveArgs returns the command-line arguments for the serve subcommand.
func (r *Runner) serveArgs(sock string) []string {
	if r.useMLX {
		return []string{"serve", "--sock", sock}
	}
	args := []string{
		"serve",
		"--model", r.modelPath,
		"--voices", r.voicesPath,
		"--sock", sock,
	}
	if r.configPath != "" {
		args = append(args, "--config", r.configPath)
	}
	return args
}

// daemonSpeak connects to the daemon socket, sends a speak request, and reads the response.
func (r *Runner) daemonSpeak(text, voice string, speed float64, outputPath string) (*daemonResponse, error) {
	req := map[string]interface{}{
		"id":     "1",
		"method": "speak",
		"text":   text,
		"voice":  voice,
		"speed":  speed,
		"lang":   engineLangCode(r.lang),
		"output": outputPath,
	}
	return r.daemonRequest(req)
}

// daemonRequest connects to the daemon socket, sends a JSON request, and reads the response.
func (r *Runner) daemonRequest(req map[string]interface{}) (*daemonResponse, error) {
	sock := r.sockPath()

	conn, err := net.DialTimeout("unix", sock, 10*time.Second)
	if err != nil {
		return nil, fmt.Errorf("connecting to engine daemon: %w", err)
	}
	defer conn.Close()

	data, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshalling request: %w", err)
	}
	data = append(data, '\n')
	if _, err := conn.Write(data); err != nil {
		return nil, fmt.Errorf("writing to engine daemon: %w", err)
	}

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	if !scanner.Scan() {
		if err := scanner.Err(); err != nil {
			return nil, fmt.Errorf("reading from engine daemon: %w", err)
		}
		return nil, fmt.Errorf("engine daemon closed connection without response")
	}

	var resp daemonResponse
	if err := json.Unmarshal(scanner.Bytes(), &resp); err != nil {
		return nil, fmt.Errorf("parsing engine response: %w", err)
	}
	return &resp, nil
}

// shutdownDaemon sends a shutdown request to the daemon. Best-effort.
func (r *Runner) shutdownDaemon() {
	sock := r.sockPath()
	conn, err := net.DialTimeout("unix", sock, 2*time.Second)
	if err != nil {
		return
	}
	defer conn.Close()
	req, _ := json.Marshal(map[string]interface{}{
		"id": "shutdown", "method": "shutdown",
	})
	req = append(req, '\n')
	conn.Write(req) //nolint:errcheck
}

// ── engine management ─────────────────────────────────────────────────────────

func (r *Runner) ensureEngine(cacheDir string, noProgress bool) error {
	var (
		engineURL  string
		engineDir  string
		engineExe  string
		stampFile  string
	)

	if r.useMLX {
		engineURL = assets.MLXEngineURL()
		engineDir = filepath.Join(cacheDir, "engines", "mlx-"+assets.EngineTag+"-"+runtime.GOOS+"-"+runtime.GOARCH)
		if runtime.GOOS == "windows" {
			engineExe = filepath.Join(engineDir, "kokoro_engine_mlx", "kokoro_engine_mlx.exe")
		} else {
			engineExe = filepath.Join(engineDir, "kokoro_engine_mlx", "kokoro_engine_mlx")
		}
	} else {
		var err error
		engineURL, err = assets.EngineURL(runtime.GOOS, runtime.GOARCH)
		if err != nil {
			return err
		}
		engineDir = filepath.Join(cacheDir, "engines", "onnx-"+assets.EngineTag+"-"+runtime.GOOS+"-"+runtime.GOARCH)
		if runtime.GOOS == "windows" {
			engineExe = filepath.Join(engineDir, "kokoro_engine", "kokoro_engine.exe")
		} else {
			engineExe = filepath.Join(engineDir, "kokoro_engine", "kokoro_engine")
		}
	}
	stampFile = filepath.Join(engineDir, ".version")

	// Check if this version is already extracted.
	if stamp, err := os.ReadFile(stampFile); err == nil {
		if strings.TrimSpace(string(stamp)) == assets.EngineTag {
			r.engineExe = engineExe
			return nil
		}
	}

	// Download and extract fresh.
	fmt.Fprintf(os.Stderr, "Setting up engine (%s) ...\n", assets.EngineTag)
	if err := os.RemoveAll(engineDir); err != nil {
		return err
	}
	if err := os.MkdirAll(engineDir, 0o755); err != nil {
		return err
	}

	archiveName := archiveFilename(engineURL)
	if err := downloader.DownloadAndExtract(engineURL, engineDir, noProgress, archiveName); err != nil {
		return fmt.Errorf("downloading engine: %w", err)
	}

	// Make executable on Unix.
	if runtime.GOOS != "windows" {
		if err := os.Chmod(engineExe, 0o755); err != nil {
			return err
		}
	}

	if err := os.WriteFile(stampFile, []byte(assets.EngineTag), 0o644); err != nil {
		return err
	}

	r.engineExe = engineExe
	return nil
}

// ── model management ──────────────────────────────────────────────────────────

func (r *Runner) ensureModel(cacheDir string, noProgress bool) error {
	ml := modelLang(r.lang)
	modelDir := filepath.Join(cacheDir, "models", ml)
	stampFile := filepath.Join(modelDir, ".version")

	// Check if already downloaded.
	if stamp, err := os.ReadFile(stampFile); err == nil {
		if strings.TrimSpace(string(stamp)) == assets.EngineTag {
			return r.setModelPaths(modelDir)
		}
	}

	fmt.Fprintf(os.Stderr, "Downloading %s model ...\n", ml)
	if err := os.MkdirAll(modelDir, 0o755); err != nil {
		return err
	}

	for _, pair := range assets.ModelFiles(ml) {
		remoteRel, localName := pair[0], pair[1]
		url := assets.ModelURL(remoteRel)
		dest := filepath.Join(modelDir, localName)
		if err := downloader.Download(url, dest, noProgress, localName); err != nil {
			return err
		}
	}

	if err := os.WriteFile(stampFile, []byte(assets.EngineTag), 0o644); err != nil {
		return err
	}
	return r.setModelPaths(modelDir)
}

func (r *Runner) setModelPaths(modelDir string) error {
	r.modelPath = filepath.Join(modelDir, "model.onnx")
	r.voicesPath = filepath.Join(modelDir, "voices.bin")
	if modelLang(r.lang) == "zh" {
		r.configPath = filepath.Join(modelDir, "config.json")
	}
	return nil
}

// Voices returns the list of available voice names by querying the engine.
// This is only used when the hardcoded list needs to be refreshed; most
// callers should use the internal/voices package instead.
func (r *Runner) Voices() ([]string, error) {
	var args []string
	if r.useMLX {
		args = []string{"voices"}
	} else {
		args = []string{"voices", "--model", r.modelPath, "--voices", r.voicesPath}
		if r.configPath != "" {
			args = append(args, "--config", r.configPath)
		}
	}
	cmd := exec.Command(r.engineExe, args...) //nolint:gosec
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("engine error: %w", err)
	}
	var voices []string
	if err := json.Unmarshal([]byte(strings.TrimSpace(string(out))), &voices); err != nil {
		return nil, fmt.Errorf("parsing voice list: %w", err)
	}
	return voices, nil
}

// ── helpers ───────────────────────────────────────────────────────────────────

func archiveFilename(url string) string {
	parts := strings.Split(url, "/")
	if len(parts) > 0 {
		return parts[len(parts)-1]
	}
	return url
}
