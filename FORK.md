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

The app is signed with the local Apple Development certificate and keeps the upstream bundle ID
`com.FluidApp.app`, so it uses the same settings and meeting library as the release build.

```bash
scripts/fork-install.sh         # builds Release, backs up /Applications/FluidVoice.app, installs
```

Permissions are tied to the signing team. The first launch after switching from the official
build needs Microphone, Accessibility and Screen & System Audio access granted again. Turn off
automatic updates in FluidVoice, or an upstream update replaces this build.

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
