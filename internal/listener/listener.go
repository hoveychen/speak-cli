// Package listener provides speech-to-text by invoking the platform-native
// listener binary (Swift on macOS, C# on Windows).
//
// On macOS, if a daemon is running (speak listen --daemon), the client
// connects via Unix socket. Otherwise it launches the binary directly.
package listener

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"syscall"
	"time"
)

// Listen starts the native ASR and blocks until it produces a result.
// The transcribed text (JSON) is written to stdout; status messages to stderr.
func Listen(language string, silenceTimeout, maxDuration float64) error {
	if runtime.GOOS != "darwin" && runtime.GOOS != "windows" {
		return fmt.Errorf("speak listen is not supported on %s", runtime.GOOS)
	}

	locale := asrLocale(language)

	// Try the daemon first (macOS only).
	if runtime.GOOS == "darwin" {
		sock := daemonSocketPath()
		if result, err := tryDaemon(sock, locale, silenceTimeout, maxDuration); err == nil {
			fmt.Print(result)
			return nil
		}
	}

	// Fall back to launching the binary directly.
	return listenDirect(locale, silenceTimeout, maxDuration)
}

// StartDaemon launches the listener binary in daemon mode.
func StartDaemon(language string) error {
	bin, err := findBinary()
	if err != nil {
		return err
	}

	locale := asrLocale(language)
	cmd := exec.Command(bin, "--daemon", "--language", locale) //nolint:gosec
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	return cmd.Run()
}

// ── daemon client ───────────────────────────────────────────────────────

func daemonSocketPath() string {
	dir, err := os.UserCacheDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "speak-cli", "listen.sock")
}

func tryDaemon(sock, locale string, silenceTimeout, maxDuration float64) (string, error) {
	if sock == "" {
		return "", fmt.Errorf("no socket path")
	}

	conn, err := net.DialTimeout("unix", sock, 2*time.Second)
	if err != nil {
		return "", err
	}
	defer conn.Close()

	// Send request.
	req := map[string]any{
		"language":        locale,
		"silence_timeout": silenceTimeout,
		"max_duration":    maxDuration,
	}
	data, _ := json.Marshal(req)
	if _, err := conn.Write(data); err != nil {
		return "", err
	}

	// Signal that we're done writing.
	if uc, ok := conn.(*net.UnixConn); ok {
		_ = uc.CloseWrite()
	}

	// Read response — wait up to max_duration + some margin.
	deadline := time.Duration(maxDuration+10) * time.Second
	_ = conn.SetReadDeadline(time.Now().Add(deadline))

	scanner := bufio.NewScanner(conn)
	if scanner.Scan() {
		return scanner.Text() + "\n", nil
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	return "", fmt.Errorf("daemon returned empty response")
}

// ── direct mode ─────────────────────────────────────────────────────────

func listenDirect(locale string, silenceTimeout, maxDuration float64) error {
	bin, err := findBinary()
	if err != nil {
		return err
	}

	cmd := exec.Command(bin,
		"--language", locale,
		"--silence-timeout", fmt.Sprintf("%.1f", silenceTimeout),
		"--max-duration", fmt.Sprintf("%.1f", maxDuration),
	) //nolint:gosec

	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	fi, _ := os.Stdin.Stat()
	isTerminal := fi.Mode()&os.ModeCharDevice != 0

	if isTerminal {
		pipe, err := cmd.StdinPipe()
		if err != nil {
			return err
		}
		if err := cmd.Start(); err != nil {
			return err
		}
		go func() {
			reader := bufio.NewReader(os.Stdin)
			_, _ = reader.ReadString('\n')
			pipe.Close()
		}()
		return checkErr(cmd.Wait())
	}

	return checkErr(cmd.Run())
}

// ── helpers ─────────────────────────────────────────────────────────────

func asrLocale(lang string) string {
	if lang == "auto" {
		return "auto"
	}
	isDarwin := runtime.GOOS == "darwin"
	switch lang {
	case "zh":
		if isDarwin {
			return "zh-Hans"
		}
		return "zh-CN"
	case "en":
		return "en-US"
	case "ja":
		return "ja-JP"
	case "es":
		return "es-ES"
	case "fr":
		return "fr-FR"
	case "ko":
		return "ko-KR"
	default:
		return lang
	}
}

func findBinary() (string, error) {
	name := "speak-listen"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}

	// 1. Next to our own executable.
	if exe, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(exe), name)
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
	}

	// 2. In PATH.
	if p, err := exec.LookPath(name); err == nil {
		return p, nil
	}

	// 3. Extract from embedded binary.
	if len(embeddedBinary) > 0 {
		return extractEmbedded(name)
	}

	return "", fmt.Errorf(
		"listener binary %q not found.\n"+
			"  macOS:   make build-listener\n"+
			"  Windows: scripts\\build-listener-windows.bat",
		name,
	)
}

// extractEmbedded writes the embedded listener binary to the cache directory
// and returns its path. It only writes if the file doesn't already exist or
// has a different size (i.e. was updated).
func extractEmbedded(name string) (string, error) {
	cacheDir, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(cacheDir, "speak-cli", "bin")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}

	dest := filepath.Join(dir, name)

	// Skip extraction if already exists with correct size.
	if info, err := os.Stat(dest); err == nil && info.Size() == int64(len(embeddedBinary)) {
		return dest, nil
	}

	if err := os.WriteFile(dest, embeddedBinary, 0o755); err != nil {
		return "", fmt.Errorf("extracting listener: %w", err)
	}
	return dest, nil
}

func checkErr(err error) error {
	if err == nil {
		return nil
	}
	if runtime.GOOS == "darwin" {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			if status, ok := exitErr.Sys().(syscall.WaitStatus); ok && status.Signal() == syscall.SIGKILL {
				return fmt.Errorf("listener was killed by the system (SIGKILL).\n" +
					"This usually means the terminal app lacks microphone permission.\n" +
					"Grant access in: System Settings → Privacy & Security → Microphone")
			}
		}
	}
	return err
}
