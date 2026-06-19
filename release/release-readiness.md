# OpenCommander Release Readiness

Stand: 19. Juni 2026

## Bereit

- App-Code ist auf GitHub: https://github.com/Niclas85/openComander
- Debug-Build wurde erfolgreich gebaut und auf einem angeschlossenen Android-Geraet installiert.
- Release-AAB kann lokal gebaut werden.
- Google-Play-Listing liegt auf Deutsch und Englisch vor.
- Fastlane-Metadaten liegen unter `fastlane/metadata/android/`.
- F-Droid-Metadatenentwurf liegt unter `metadata/com.opencommander.yml`.
- Play-Console-Antworten fuer Data Safety und All Files Access liegen unter `playstore/play-console-answers-de.md`.
- Store-Assets liegen unter `playstore/`.
- Lokaler Upload-Key wurde erstellt: `release/opencommander-upload-key.jks` (nicht ins Repo committen).
- Lokale Signing-Konfiguration wurde erstellt: `keystore.properties` (nicht ins Repo committen).
- Signiertes Release-AAB wurde gebaut: `app/build/outputs/bundle/release/app-release.aab`.

## Blocker Vor Play-Release

- Upload-Key sicher extern sichern. Ohne diese Datei und Passwoerter koennen spaetere Updates nicht mit demselben Upload-Key signiert werden.
- Google Play App Signing / Upload-Key in der Play Console final einrichten.
- Play-Console-Zugang oder Service-Account fuer Upload bereitstellen.
- Oeffentliche Datenschutz-URL veroeffentlichen.
- Oeffentliche Impressum-/Anbieter-URL veroeffentlichen.
- Echten Anbietername und ladungsfaehige Anschrift eintragen.
- All-Files-Access-Erklaerung in der Play Console einreichen und Freigabe abwarten.

## Empfohlener Ablauf

1. Release-Key/Upload-Key erstellen und sicher speichern.
2. `app/build.gradle` um Release-Signing ergaenzen, ohne Passwoerter ins Repo zu committen.
3. `.\gradlew.bat "-Dorg.gradle.vfs.watch=false" :app:bundleRelease --no-daemon --no-watch-fs --console=plain` ausfuehren.
4. Signiertes AAB in Internal Testing hochladen.
5. Store-Listing aus `fastlane/metadata/android/` oder `playstore/` uebernehmen.
6. Data-Safety und All-Files-Access aus `playstore/play-console-answers-de.md` eintragen.
7. 10-20 Tester einladen und die Kernablaeufe testen:
   - Datei markieren
   - Kopieren
   - Verschieben
   - Loeschen in Papierkorb
   - Endgueltig loeschen
   - Rueckgaengig
   - ZIP oeffnen
   - ZIP erstellen
   - Hochformat und Querformat

## GitHub Release

Empfohlenes Tag: `v1.0.0`

Release-Titel:

`OpenCommander 1.0`

Release-Text:

```text
OpenCommander 1.0 is the first public test release of a free, open-source dual-pane file manager for Android.

Highlights:
- Dual-pane file management
- Copy and move with drag & drop
- Multi-select
- Delete with trash choice
- Undo history
- Browse and create ZIP files
- Light and dark theme
- No ads, no tracking, no account

Please test carefully before using it on important files and keep your own backups.
```
