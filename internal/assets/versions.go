// Package assets provides URL constants for downloading engine and model assets.
//
// Engines are hosted as GitHub Release assets; models on HuggingFace.
// Bump EngineTag to force all clients to re-download a new engine build.
package assets

import "fmt"

const (
	// EngineTag is the GitHub Release tag under which engine tarballs are published.
	// Changing this constant causes all clients to re-download the new engine.
	EngineTag = "engine-v0.2.0"

	// GHReleasesBase is the GitHub Releases download URL prefix.
	GHReleasesBase = "https://github.com/hoveychen/speak-cli/releases/download"

	// HFBase is the HuggingFace raw-file base URL for model downloads.
	HFBase = "https://huggingface.co/hoveyc/speak-cli-models/resolve/main"
)

// EngineURL returns the download URL for the ONNX engine bundle matching the
// given GOOS/GOARCH. Returns an error for unsupported combinations.
func EngineURL(goos, goarch string) (string, error) {
	var filename string
	switch {
	case goos == "darwin" && goarch == "arm64":
		filename = "engine-darwin-arm64-onnx.tar.gz"
	case goos == "darwin" && goarch == "amd64":
		filename = "engine-darwin-amd64-onnx.tar.gz"
	case goos == "windows" && goarch == "amd64":
		filename = "engine-windows-amd64-onnx.zip"
	default:
		return "", fmt.Errorf("unsupported platform %s/%s", goos, goarch)
	}
	return GHReleasesBase + "/" + EngineTag + "/" + filename, nil
}

// MLXEngineURL returns the download URL for the MLX engine bundle (darwin/arm64 only).
func MLXEngineURL() string {
	return GHReleasesBase + "/" + EngineTag + "/engine-darwin-arm64-mlx.tar.gz"
}

// ModelFiles returns the list of files to download for a given language variant.
// Each entry is (remoteRelPath, localFileName).
func ModelFiles(lang string) [][2]string {
	switch lang {
	case "en":
		return [][2]string{
			{"en/model.onnx", "model.onnx"},
			{"en/voices.bin", "voices.bin"},
		}
	case "zh":
		return [][2]string{
			{"zh/model.onnx", "model.onnx"},
			{"zh/voices.bin", "voices.bin"},
			{"zh/config.json", "config.json"},
		}
	default:
		return nil
	}
}

// ModelURL returns the full HuggingFace URL for a model file.
func ModelURL(relPath string) string {
	return HFBase + "/" + relPath
}
