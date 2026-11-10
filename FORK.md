# Fork changes (oliverrahner/FluidVoice)

This fork adds a few features on top of upstream `altic-dev/FluidVoice`. Each feature is listed
with what it does and every file it touches, so it can be re-applied after upstream changes.

Every fork edit inside an upstream file is marked with a `FORK(<feature-tag>)` comment.
Run `git grep -n "FORK("` to list them all.

## Branches and updating from upstream

- Local `fork-main` (pushed to `main` on this fork): upstream `main` plus the fork commits.
  Local `main` keeps tracking upstream.
- Remotes: `origin` = upstream (`altic-dev/FluidVoice`), `fork` = this repo.

To update:

```bash
git checkout fork-main
git fetch origin
git rebase origin/main          # resolve conflicts with the notes below
git push --force-with-lease fork fork-main:main
```

## Building and installing locally

The app keeps the upstream bundle ID `com.FluidApp.app`, so it uses the same settings and
meeting library as the release build.

It is signed like T3 Code: with the self-signed **"T3 Local Signing"** certificate from the login
keychain (override with `FLUIDVOICE_SIGNING_IDENTITY`). The designated requirement pins that
certificate's hash, so Microphone, Accessibility and Screen & System Audio grants survive
rebuilds. They only have to be granted again once after switching from the official build, and
again if the certificate is replaced (it expires Oct 2027).

```bash
scripts/fork-install.sh             # build Release, sign, back up the installed app, install
scripts/fork-install.sh --no-build  # sign and install the last build
```

Notes:
- The Xcode build still signs with the Apple Development identity if one exists (ad hoc
  otherwise). The script then re-signs frameworks, `Contents/Helpers/fv-serve` and the app.
- Entitlements that need a provisioning profile (`com.apple.application-identifier`, …) are
  dropped while re-signing, or macOS refuses to launch `fv-serve`.
- Backups go to `~/Applications/FluidVoice-backups/`.
- Turn off automatic update checks in FluidVoice, or an upstream release replaces this build.

---

## Feature: Quick meeting language toggle (`meeting-language`)

**Why:** the meeting transcript language could only be changed two levels deep in the FluidMeet
settings sheet.

**What:**
- The "Record this meeting?" prompt has a segmented control: Auto · English · Deutsch
  (plus the saved language when it is something else). The choice is saved for later meetings.
- The menu bar has a "Meeting Language: …" submenu below "Start Meeting Recording".
- The FluidMeet settings sheet picks up a language changed in either place.

**Files:**
- `Sources/Fluid/Services/Meeting/MeetingLanguageChoice.swift` (new, shared with the next feature)
- `Sources/Fluid/Services/MenuBarManager+MeetingLanguage.swift` (new)
- `Sources/Fluid/Services/MenuBarManager.swift`: 2 lines (add submenu, refresh on open)
- `Sources/Fluid/UI/MeetingRecordingSourcePrompt.swift`: `selectLanguage`, `languageSelector`,
  panel height 300 → 340
- `Sources/Fluid/UI/MeetingTranscriptionView.swift`: `openMeetingSettings` refreshes the draft
  language; starting from FluidMeet reads the saved language

## Feature: Automatic meeting language (`meeting-language`)

**Why:** with a 50/50 German/English day, any fixed meeting language is wrong half the time.
Parakeet v3 already transcribes without a language hint, but the app labelled every meeting
English and could route it to the English-only Parakeet v2 model.

**What:**
- New choice "Auto-detect", and it is the default when no language was saved.
- `"auto"` exists only as a saved preference. `MeetingCaptureConfiguration.init` resolves it to
  the provisional code `"en"` and sets `detectsLanguage = true` on the configuration and session,
  so all upstream language guards keep seeing real codes.
- Automatic sessions always use a multilingual Parakeet model (never v2) and never take the
  English-only legacy backend.
- After final processing, `NLLanguageRecognizer` (limited to the Parakeet v3 languages) picks the
  dominant transcript language and stores it as the session language. Transcribing again in an
  explicitly chosen language turns detection off for that session. "Record again" keeps Auto.

**Files:**
- `Sources/Fluid/Services/Meeting/MeetingLanguageChoice.swift` (new)
- `Sources/Fluid/Services/Meeting/MeetingModels.swift`: `detectsLanguage` on
  `MeetingCaptureConfiguration` and `MeetingSession`; "auto" resolved in the configuration init
- `Sources/Fluid/Services/Meeting/MeetingSessionCoordinator.swift`: detection after processing;
  default language for auto-detected meeting starts
- `Sources/Fluid/Services/Meeting/MeetingProcessingPipeline.swift`: backend and model choice for
  automatic sessions
- `Sources/Fluid/Services/FluidAudioProvider.swift`: `preferredMultilingualModel(selected:)`
- `Sources/Fluid/Services/AppServices+MeetingMenuBar.swift`,
  `Sources/Fluid/UI/MeetingRecordingSourcePrompt.swift`,
  `Sources/Fluid/UI/MeetingTranscriptionView.swift`: default `"en"` → saved choice / Auto
- `Sources/Fluid/UI/MeetingRecordingSettingsSheet.swift`: "Auto-detect" picker entry, save guard

## Feature: Live captions in German and Auto (`live-captions-multilingual`)

**Why:** upstream live captions only run the English-only Parakeet realtime EOU model, and are
switched off for every other meeting language.

**What:**
- English meetings keep the upstream English caption model.
- German, Auto and every other language the Nemotron model supports use
  **Nemotron Speech 3.5 streaming** (`nemotron-3.5-asr-streaming320-int8-CoreML`, ~700 MB, the
  same cache folder as the dictation engine) with a language prompt (`de-DE`, `auto`, …).
- Nemotron has no end-of-utterance output. `MeetingNemotronLiveRecognizer` ends a caption line
  when the text has not changed for 1.5 s of audio, or after ~30 s at a sentence end (45 s max).
- The model is downloaded in the background at app launch, and when the meeting language
  changes, as long as the saved language is not English. Microphone, app track and prefetch
  share one download.

**Files:**
- `Sources/Fluid/Services/Meeting/LiveTranscription/MeetingNemotronLiveRecognizer.swift` (new)
- `Sources/Fluid/Services/Meeting/MeetingLanguageChoice.swift`: `liveCaptionPrompt(for:)`,
  `prefetchLiveCaptionModelIfNeeded()`
- `Sources/Fluid/Services/Meeting/LiveTranscription/MeetingLiveTranscriptionCoordinator.swift`:
  `start(…, multilingualPrompt:)` creates engines with the Nemotron recognizer
- `Sources/Fluid/Services/Meeting/MeetingSessionCoordinator.swift`: passes the prompt when live
  captions start
- `Sources/Fluid/AppDelegate.swift`: 1 line, prefetch at launch

**Tuning:** `endpointSilenceSeconds` and `maxUtteranceSeconds` in
`MeetingNemotronLiveRecognizer`.
