using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Media;
using System.Runtime.InteropServices;
using System.Speech.Recognition;
using System.Threading;
using System.Windows.Forms;

// Floating subtitle overlay + system speech recognition for Windows.
// Build: scripts\build-listener-windows.bat

class Program
{
    static string language = "auto";
    static double silenceTimeout = 2.0;
    static double maxDuration = 60.0;

    static void Main(string[] args)
    {
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--language":       if (i + 1 < args.Length) language = args[++i]; break;
                case "--silence-timeout": if (i + 1 < args.Length) double.TryParse(args[++i], out silenceTimeout); break;
                case "--max-duration":    if (i + 1 < args.Length) double.TryParse(args[++i], out maxDuration); break;
            }
        }

        if (language == "auto")
        {
            language = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh" ? "zh-CN" : "en-US";
        }

        Application.EnableVisualStyles();
        Application.Run(new ListenForm(language, silenceTimeout, maxDuration));
    }
}

class ListenForm : Form
{
    private readonly string locale;
    private readonly double silenceTimeout;
    private readonly double maxDuration;

    private Label label;
    private SpeechRecognitionEngine engine;
    private string currentText = "";
    private DateTime lastChange = DateTime.Now;
    private bool done = false;
    private System.Windows.Forms.Timer silenceTimer;
    private System.Windows.Forms.Timer maxTimer;

    // Click-through: the overlay is visible but does not steal focus or
    // intercept mouse events.
    const int WS_EX_LAYERED = 0x80000;
    const int WS_EX_TRANSPARENT = 0x20;
    const int WS_EX_TOOLWINDOW = 0x80;
    const int WS_EX_TOPMOST = 0x8;
    const int WS_EX_NOACTIVATE = 0x08000000;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW
                        | WS_EX_TOPMOST | WS_EX_NOACTIVATE;
            return cp;
        }
    }

    public ListenForm(string locale, double silenceTimeout, double maxDuration)
    {
        this.locale = locale;
        this.silenceTimeout = silenceTimeout;
        this.maxDuration = maxDuration;

        // Form setup — centered near the bottom of the primary screen.
        var screen = Screen.PrimaryScreen.WorkingArea;
        int w = Math.Min((int)(screen.Width * 0.8), 800);
        int h = 80;
        int x = screen.Left + (screen.Width - w) / 2;
        int y = screen.Bottom - h - 80;

        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Location = new Point(x, y);
        Size = new Size(w, h);
        TopMost = true;
        ShowInTaskbar = false;
        BackColor = Color.Black;
        Opacity = 0.85;

        // Rounded corners.
        try
        {
            var path = new GraphicsPath();
            path.AddArc(0, 0, 32, 32, 180, 90);
            path.AddArc(w - 32, 0, 32, 32, 270, 90);
            path.AddArc(w - 32, h - 32, 32, 32, 0, 90);
            path.AddArc(0, h - 32, 32, 32, 90, 90);
            path.CloseFigure();
            Region = new Region(path);
        }
        catch { /* older Windows */ }

        label = new Label
        {
            Text = "Preparing...",
            ForeColor = Color.White,
            BackColor = Color.Transparent,
            Font = new Font("Segoe UI", 18, FontStyle.Regular),
            TextAlign = ContentAlignment.MiddleCenter,
            Dock = DockStyle.Fill,
            Padding = new Padding(16, 0, 16, 0)
        };
        Controls.Add(label);

        Load += (s, e) => StartListening();
    }

    private void StartListening()
    {
        // Create the recognizer for the requested locale.
        try
        {
            var culture = new CultureInfo(locale);
            engine = new SpeechRecognitionEngine(culture);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Recognizer unavailable for " + locale + ": " + ex.Message);
            Console.Error.WriteLine("You may need to install the language pack in:");
            Console.Error.WriteLine("  Settings > Time & Language > Speech");
            OutputAndExit("");
            return;
        }

        // Connect to the default microphone.
        try
        {
            engine.SetInputToDefaultAudioDevice();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Error: no microphone available: " + ex.Message);
            Console.Error.WriteLine("Check that a microphone is connected and that this app");
            Console.Error.WriteLine("has permission in: Settings > Privacy > Microphone");
            OutputAndExit("");
            return;
        }

        engine.LoadGrammar(new DictationGrammar());

        engine.SpeechHypothesized += (s, e) =>
        {
            if (done) return;
            Invoke(new Action(() =>
            {
                currentText = e.Result.Text;
                lastChange = DateTime.Now;
                label.Text = currentText;
                label.ForeColor = Color.White;
            }));
        };

        engine.SpeechRecognized += (s, e) =>
        {
            if (done) return;
            Invoke(new Action(() =>
            {
                if (e.Result != null && e.Result.Confidence > 0.3)
                {
                    currentText = e.Result.Text;
                    lastChange = DateTime.Now;
                    label.Text = currentText;
                }
            }));
        };

        engine.RecognizeCompleted += (s, e) =>
        {
            if (!done) Invoke(new Action(() => Finish()));
        };

        // Chime before listening begins.
        SystemSounds.Asterisk.Play();

        engine.RecognizeAsync(RecognizeMode.Multiple);
        label.Text = "";
        Console.Error.WriteLine("Listening...");
        lastChange = DateTime.Now;

        // Silence detector.
        silenceTimer = new System.Windows.Forms.Timer { Interval = 300 };
        silenceTimer.Tick += (s, e) =>
        {
            if (done || string.IsNullOrEmpty(currentText)) return;
            if ((DateTime.Now - lastChange).TotalSeconds >= silenceTimeout)
                Finish();
        };
        silenceTimer.Start();

        // Max duration.
        maxTimer = new System.Windows.Forms.Timer { Interval = (int)(maxDuration * 1000) };
        maxTimer.Tick += (s, e) => Finish();
        maxTimer.Start();

        // Monitor stdin for stop signal, but only when stdin is a
        // console (interactive).  When launched by a non-interactive
        // parent, stdin is a pipe that hits EOF immediately — rely on
        // silence timeout / max duration instead.
        if (Console.IsInputRedirected == false)
        {
            new Thread(() =>
            {
                try { while (Console.In.ReadLine() != null) { } } catch { }
                try { Invoke(new Action(() => Finish())); } catch { }
            }) { IsBackground = true }.Start();
        }
    }

    private void Finish()
    {
        if (done) return;
        done = true;

        silenceTimer?.Stop();
        maxTimer?.Stop();
        try { engine?.RecognizeAsyncCancel(); } catch { }

        // Visual confirmation.
        if (string.IsNullOrEmpty(currentText))
        {
            label.Text = "(no speech detected)";
        }
        else
        {
            label.Text = "\u2713 " + currentText;
            label.ForeColor = Color.FromArgb(80, 230, 130);
        }

        // Output JSON to stdout for AI.
        string escaped = currentText
            .Replace("\\", "\\\\")
            .Replace("\"", "\\\"")
            .Replace("\n", "\\n")
            .Replace("\r", "\\r")
            .Replace("\t", "\\t");
        Console.WriteLine("{\"text\":\"" + escaped + "\"}");
        Console.Out.Flush();
        Console.Error.WriteLine("Done.");

        // Show confirmation briefly, then exit.
        var exitTimer = new System.Windows.Forms.Timer { Interval = 1500 };
        exitTimer.Tick += (s, e) =>
        {
            exitTimer.Stop();
            Application.Exit();
        };
        exitTimer.Start();
    }

    private void OutputAndExit(string text)
    {
        string escaped = text
            .Replace("\\", "\\\\")
            .Replace("\"", "\\\"");
        Console.WriteLine("{\"text\":\"" + escaped + "\"}");
        Console.Out.Flush();
        Application.Exit();
    }
}
