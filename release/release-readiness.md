# OpenCommander Release Readiness

Stand: 9. August 2026

## Bereit

- App-Code ist auf GitHub: https://github.com/Niclas85/openComander
- Debug-Build wurde erfolgreich gebaut und auf einem angeschlossenen Android-Geraet installiert.
- Version 1.3 (Code 6) kann lokal als signiertes Release-AAB gebaut werden.
- APK-Dateien werden nach einer ausdruecklichen Nutzeraktion an den Android-Paketinstaller uebergeben.
- Android-TV-Unterstuetzung (Leanback-Launcher, D-Pad-Fokus, TV-Banner und TV-Screenshot) ist vorbereitet.
- Google-Play-Listing liegt auf Deutsch und Englisch vor.
- Fastlane-Metadaten liegen unter `fastlane/metadata/android/`.
- F-Droid-Metadatenentwurf liegt unter `metadata/com.opencommander.yml`.
- Play-Console-Antworten fuer Data Safety und All Files Access liegen unter `playstore/play-console-answers-de.md`.
- Store-Assets liegen unter `playstore/`.
- Neuer lokaler Upload-Key wurde erstellt: `release/opencommander-upload-key.jks` (durch `.gitignore` geschuetzt).
- Das Kennwort liegt im macOS-Schluesselbund unter `com.opencommander.upload-key.v2`.
- Signiertes Release-AAB wurde gebaut: `app/build/outputs/bundle/release/app-release.aab`.
- Signierte, direkt installierbare TV-APK wurde gebaut: `release/OpenCommander-1.3-tv-universal.apk`.
- TV-Installationsanleitung und ADB-Helfer liegen unter `release/TV-INSTALLATION-DE.md` und `release/install-on-tv.sh`.
- Signatur-Fingerabdruck (SHA-256): `0A:72:E5:84:25:C7:1C:C8:53:34:28:56:36:CF:D3:BE:D4:45:C0:62:F4:43:B3:3F:A7:78:CA:C5:92:08:D5:30`.

## Blocker Vor Play-Release

- Google Play hat den neuen Uploadschluessel registriert, akzeptiert damit signierte AABs wegen der Sicherheitswartezeit aber erst ab 11. August 2026, 20:27:25 UTC (22:27:25 Uhr Europe/Zurich).
- Upload-Key und Schluesselbund-Eintrag sicher extern sichern. Ohne beides sind spaetere Updates nicht mit demselben Upload-Key signierbar.
- Die Erklaerungen fuer `MANAGE_EXTERNAL_STORAGE` und `REQUEST_INSTALL_PACKAGES` muessen beim Release korrekt eingereicht werden.
- Android-TV-Store-Eintrag mit TV-Banner und TV-Screenshot abschliessen und zur TV-Pruefung einreichen.
- Produktionszugriff ist in der Console beantragbar, aber noch nicht freigeschaltet; bis dahin bleibt der geschlossene Alpha-Test der aktive Track.

## Empfohlener Ablauf

1. Genehmigung der Uploadschluessel-Zuruecksetzung abwarten.
2. Key-Datei und macOS-Schluesselbund-Eintrag extern sichern.
3. Kennwort aus dem Schluesselbund als `OPENCOMMANDER_KEYSTORE_PASSWORD` und `OPENCOMMANDER_KEY_PASSWORD` setzen und `./gradlew :app:bundleRelease` ausfuehren.
4. Signiertes AAB in den geschlossenen Alpha-Test hochladen.
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
