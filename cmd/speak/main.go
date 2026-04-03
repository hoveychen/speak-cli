// speak — multilingual TTS CLI powered by Kokoro.
//
// Usage:
//
//	speak [flags] <text>               speak text (language auto-detected)
//	speak voices [--lang en|zh|all]    list available voices (offline)
//	speak init   [--lang en|zh|all]    pre-download engine and model
//
// Flags:
//
//	--lang  auto|en|zh   Language (default: auto-detect)
//	-v, --voice string   Voice name
//	-s, --speed float    Speed multiplier 0.5–2.0  (default: 1.0)
//	-o, --output string  Save WAV to file instead of playing
//	--no-progress        Suppress download progress bar
package main

import (
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/hoveychen/speak-cli/internal/listener"
	"github.com/hoveychen/speak-cli/internal/player"
	"github.com/hoveychen/speak-cli/internal/runner"
	"github.com/hoveychen/speak-cli/internal/voices"
	"github.com/spf13/cobra"
)

func main() {
	if err := buildRoot().Execute(); err != nil {
		os.Exit(1)
	}
}

// ── root (speak) command ──────────────────────────────────────────────────────

func buildRoot() *cobra.Command {
	var (
		lang       string
		voice      string
		speed      float64
		output     string
		noProgress bool
	)

	root := &cobra.Command{
		Use:   "speak [flags] <text>",
		Short: "Multilingual TTS — Kokoro (en v1.0 / zh v1.1 / MLX)",
		Long: `speak synthesises speech using the Kokoro TTS engine.

Language is auto-detected from the text unless --lang is specified.
On Apple Silicon, English uses the faster MLX backend automatically.

On first use the appropriate engine and model are downloaded and cached
under ~/.cache/speak-cli/. Subsequent runs start instantly.

Run "speak init" to pre-download assets before going offline.`,
		Args:         cobra.ExactArgs(1),
		SilenceUsage: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			text := args[0]
			lang = resolveLang(lang, text)
			if voice == "" {
				voice = voices.DefaultFor(lang)
			}
			return speak(text, lang, voice, speed, output, noProgress)
		},
	}

	root.PersistentFlags().BoolVar(&noProgress, "no-progress", false, "Suppress download progress bar")
	root.PersistentFlags().StringVar(&lang, "lang", "auto", "Language: auto, en, zh, es, fr, hi, it, ja, pt")
	root.Flags().StringVarP(&voice, "voice", "v", "", "Voice name (default depends on language)")
	root.Flags().Float64VarP(&speed, "speed", "s", 1.0, "Speed multiplier (0.5–2.0)")
	root.Flags().StringVarP(&output, "output", "o", "", "Save WAV to file instead of playing")

	root.AddCommand(buildVoicesCmd(&noProgress))
	root.AddCommand(buildInitCmd(&noProgress))
	root.AddCommand(buildListenCmd())
	return root
}

// ── speak ─────────────────────────────────────────────────────────────────────

func speak(text, lang, voice string, speed float64, output string, noProgress bool) error {
	r, err := runner.New(lang, runner.Options{NoProgress: noProgress})
	if err != nil {
		return err
	}
	defer r.Close()

	wavPath, err := r.Speak(text, voice, speed, output)
	if err != nil {
		return err
	}

	if output != "" {
		fmt.Fprintf(os.Stderr, "Saved to %s\n", output)
		return nil
	}

	defer os.Remove(wavPath)
	return player.Play(wavPath)
}

// ── voices command ────────────────────────────────────────────────────────────

func buildVoicesCmd(noProgress *bool) *cobra.Command {
	var lang string

	cmd := &cobra.Command{
		Use:          "voices",
		Short:        "List available voices (offline)",
		SilenceUsage: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			vv := voices.All(lang)
			tw := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
			fmt.Fprintln(tw, "VOICE\tDESCRIPTION")
			fmt.Fprintln(tw, "─────\t───────────")
			for _, v := range vv {
				fmt.Fprintf(tw, "%s\t%s\n", v.Name, v.Desc)
			}
			return tw.Flush()
		},
	}
	cmd.Flags().StringVar(&lang, "lang", "all", "Filter by language: en, zh, es, fr, hi, it, ja, pt, all")
	return cmd
}

// ── init command ──────────────────────────────────────────────────────────────

func buildInitCmd(noProgress *bool) *cobra.Command {
	var lang string

	cmd := &cobra.Command{
		Use:   "init",
		Short: "Pre-download engine and model assets",
		Long: `Download and cache the engine and model files needed for offline use.

Use --lang to select which variant(s) to pre-download:
  en   English (Kokoro v1.0) — also downloads MLX engine on Apple Silicon
  zh   Chinese (Kokoro v1.1-zh)
  all  Both variants`,
		SilenceUsage: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return initAssets(lang, *noProgress)
		},
	}
	cmd.Flags().StringVar(&lang, "lang", "all", "Language to initialise: en, zh, all")
	return cmd
}

func initAssets(lang string, noProgress bool) error {
	langs := langsFor(lang)
	opts := runner.Options{NoProgress: noProgress}
	for _, l := range langs {
		fmt.Fprintf(os.Stderr, "Initialising %s ...\n", l)
		if _, err := runner.New(l, opts); err != nil {
			return fmt.Errorf("%s: %w", l, err)
		}
		fmt.Fprintf(os.Stderr, "✓ %s ready\n", l)
	}
	return nil
}

// ── listen command ───────────────────────────────────────────────────────

func buildListenCmd() *cobra.Command {
	var (
		lang           string
		silenceTimeout float64
		maxDuration    float64
		daemon         bool
	)

	cmd := &cobra.Command{
		Use:   "listen",
		Short: "Listen to microphone and transcribe speech",
		Long: `Listen to the microphone using the system's native speech recognition
and output the transcribed text as JSON to stdout.

A floating subtitle overlay shows real-time transcription on screen.
A chime plays when recording begins. The result is finalized after a
period of silence or when the user presses Enter (interactive mode).

Use --daemon to start a background listener service. Any subsequent
"speak listen" call (from any terminal, IDE, or AI tool) will connect
to the daemon via Unix socket, inheriting its microphone permission.`,
		SilenceUsage: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			if daemon {
				return listener.StartDaemon(lang)
			}
			return listener.Listen(lang, silenceTimeout, maxDuration)
		},
	}

	cmd.Flags().StringVar(&lang, "lang", "auto", "Language: auto, en, zh, ja, es, fr, ko")
	cmd.Flags().Float64Var(&silenceTimeout, "silence-timeout", 2.0, "Stop after N seconds of silence")
	cmd.Flags().Float64Var(&maxDuration, "max-duration", 60.0, "Maximum recording duration in seconds")
	cmd.Flags().BoolVar(&daemon, "daemon", false, "Run as a background listener daemon")

	return cmd
}

// ── helpers ───────────────────────────────────────────────────────────────────

// resolveLang resolves "auto" to "en" or "zh" based on the text content.
func resolveLang(lang, text string) string {
	if lang != "auto" {
		return lang
	}
	for _, r := range text {
		if r >= 0x4E00 && r <= 0x9FFF {
			return "zh"
		}
	}
	return "en"
}

// langsFor expands "all" to all supported languages, otherwise returns the single lang.
func langsFor(lang string) []string {
	if lang == "all" {
		return []string{"en", "zh", "es", "fr", "hi", "it", "ja", "pt"}
	}
	return []string{lang}
}
