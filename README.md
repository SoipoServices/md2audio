# MD2Audio

<img src="Icon/AppIcon.png" width="128" align="right" alt="MD2Audio icon">

**MD2Audio** is a **fully native** SwiftUI app: it uses the macOS system voices and needs no extra
software. Drop in a Markdown file (or type or paste text), pick a language and voice, adjust the reading
and get a WAV or M4A file, which you can play right in the app.

In Text → Audio mode, the text editor is on the left: a dropped or chosen file is loaded there and you
can edit it before converting (the original file is not changed). You can also type directly, paste with
⌘V or the **Paste** button, and empty the editor with **Clear**. Exactly the text in the editor is read.
The audio is saved next to the loaded file or, for typed or pasted text, to `Documents/Speech.m4a`
(change it with **Change…**).

The app has two modes, selectable at the top of the window:

- **Text → Audio**: from Markdown to an audio file (described below);
- **Audio → Text**: transcription of an audio file (see [Audio to text](#audio-to-text)).

## Options

| Option | Effect |
|---|---|
| Speed / Pitch | Speaking rate and pitch of the voice |
| Pause between sentences | Extra silence between sentences (sentences are detected according to the language) |
| Pause at commas and dashes | Extra silence within sentences: after commas (1×), after `;` and `:` and at spaced dashes ` - `, `–`, `—` (2×, read as a pause rather than "minus"), and for each extra space between words (1× per space, max 6×). Numbers like `3,5` or `10:30` and words like `e-mail` are left alone. 0 = off |
| Pause between blocks | Multiplier for the pauses after headings, paragraphs and lists |
| Variation | Small random change in rate and pitch for each sentence, to make the reading less monotonous |
| Read headings slower and lower | Headings are read a little slower and at a lower pitch |
| Stress bold and italic text | Bold and italic are read slower, at a higher pitch and slightly louder |
| Skip emoji | Emoji are not read |
| Pronunciations | One rule per line, `word = how to say it` (e.g. `API = a pi i`) |
| Format | WAV (uncompressed) or M4A (AAC, much smaller files) |

## Syntax

Besides the options, some elements of the text change how it is read (the **Syntax** button above the
editor shows this table with the current durations; the same guide is also in the *Help › MD2Audio Help*
menu, ⌘?):

| In the text | Effect |
|---|---|
| `# Heading` | Read slower and lower, with a pause before and after |
| `**bold**`, `*italic*` | Emphasis: a little slower, higher and louder |
| `***` or `---` on a line of its own | Section break: 2 s pause |
| `...` or `…` | Trailing thought: 500 ms pause |
| `,` `;` `:` ` - ` `–` `—` and extra spaces | Pauses within the sentence (see *Pause at commas and dashes*) |
| Code, images, tables | Not read |

The pauses for headings and section breaks are scaled by *Pause between blocks*.

The **Preview** button reads the first blocks of the text (or a sample sentence) with the current settings.

## Voices

The voice makes the biggest difference: *Enhanced* and *Premium* voices sound far more natural than the
compact ones. The **Download Voices…** button opens *System Settings › Accessibility › Spoken Content*:
from there open the *System voice* menu, choose *Manage Voices…* and download the voices you want. The
app picks them up immediately and lists them first.

## Audio to text

In **Audio → Text** mode, drop an audio file (WAV, M4A, MP3, AIFF, CAF…), choose the language and click
**Transcribe**. Recognition runs entirely on the Mac, using Apple's `SpeechAnalyzer` engine: nothing is
sent to a server and there is no length limit. The language model is downloaded automatically the first
time it is used; languages already downloaded are marked *downloaded* in the menu.

It is very fast: 40 minutes of audio are transcribed in about 25 seconds.

| Format | Content |
|---|---|
| Text | Plain text, one paragraph per stretch of speech |
| Markdown | Title (file name) and paragraphs; the file can be converted back to audio |
| Subtitles (SRT) | Timed subtitles, lines of at most ~84 characters / 6 seconds |

The **Timestamps** option adds the start time to each paragraph (Text and Markdown).
The text stays editable before you copy it or save it with **Save As…**.

Requires **macOS 26** or later; on earlier versions only Text → Audio is available.

## Building the app

Requirements:

- macOS 14 (Sonoma) or later to run the app (macOS 26+ for transcription)
- to build: the macOS 26 SDK (Xcode 26+) **or** the matching Command Line Tools (`xcode-select --install`)

Build and package for distribution:

```sh
./build_app.sh
```

The script:

1. builds a *Universal* binary (Apple Silicon + Intel) in release mode;
2. creates `build/MD2Audio.app` with its icon and `Info.plist`;
3. signs the app (ad-hoc, or with a Developer ID if given);
4. creates in `dist/` a disk image `MD2Audio-<version>.dmg` (with an *Applications* shortcut for
   drag-and-drop installation) and a `MD2Audio-<version>.zip`.

Optional environment variables:

| Variable | Example | Effect |
|---|---|---|
| `VERSION` | `VERSION=1.1` | App version number and name of the files in `dist/` (default `1.0`) |
| `SIGN_IDENTITY` | `"Developer ID Application: Name (TEAMID)"` | Sign with a Developer ID certificate and the *hardened runtime* |
| `NOTARY_PROFILE` | `md2audio` | Submit the DMG to Apple for notarization and staple the ticket (requires `SIGN_IDENTITY`) |

For development, without creating the bundle:

```sh
swift run
```

or open `Package.swift` in Xcode.

Code layout:

```
md2audio/
├── Package.swift
├── build_app.sh               # build, signing and DMG/ZIP packaging
├── Icon/
│   ├── make_icon.swift        # draws the icon and generates Resources/AppIcon.icns
│   └── AppIcon.png            # 1024×1024 preview
├── Resources/AppIcon.icns
└── Sources/MD2Audio/
    ├── MD2AudioApp.swift      # entry point
    ├── ContentView.swift      # main window, mode selection
    ├── SpeakView.swift        # Text → Audio: interface and options
    ├── SyntaxHelp.swift       # help on the syntax that changes the reading
    ├── SpeechScript.swift     # Markdown -> blocks -> SSML (pauses, prosody, emphasis, pronunciations)
    ├── AppleSpeech.swift      # synthesis with AVSpeechSynthesizer, WAV/M4A writing, preview
    ├── Converter.swift        # conversion with progress and cancellation
    ├── PlayerView.swift       # built-in audio player
    ├── TranscribeView.swift   # Audio → Text: interface
    ├── Transcriber.swift      # transcription with SpeechAnalyzer, Text/Markdown/SRT formats
    └── FileDropZone.swift     # file drop area
```

To change the icon, edit `Icon/make_icon.swift` and regenerate it with:

```sh
swift Icon/make_icon.swift
```

## Sharing the app

Share the `dist/MD2Audio-<version>.dmg` file. The recipient opens it and drags **MD2Audio** into the
*Applications* folder.

Without a *Developer ID* certificate the app is only signed ad-hoc, so macOS blocks it on first launch
("Apple could not verify “MD2Audio” is free of malware"). It only needs to be allowed once:

1. open the app and dismiss the warning;
2. go to *System Settings › Privacy & Security*, scroll down to the message about MD2Audio and click
   **Open Anyway**, then confirm.

Alternatively, from Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/MD2Audio.app
```

To avoid the warning entirely you need a membership in the [Apple Developer Program](https://developer.apple.com/programs/)
and a **Developer ID Application** certificate (an *Apple Development* certificate is not enough). Then:

```sh
# once: store the notarization credentials in the keychain
xcrun notarytool store-credentials md2audio \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=md2audio \
  VERSION=1.0 ./build_app.sh
```

The resulting DMG opens on any Mac without warnings.

## Troubleshooting

- **The voice sounds robotic**: download an *Enhanced* or *Premium* voice (see [Voices](#voices)).
- **Wrong pronunciation or odd accent**: the voice and the language must match; for individual words
  use *Pronunciations*.
- **The Markdown "has no text"**: if the document contains only code, tables or images, there is
  nothing to read.
