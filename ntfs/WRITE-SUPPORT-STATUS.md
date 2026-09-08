# NTFS-Schreibunterstützung: tatsächlicher Stand

Prüfung vom 8. September 2026. Anforderung: OpenCommander soll Dateien auf
NTFS-Laufwerken anlegen, kopieren, ändern, umbenennen und löschen können,
mit einem kostenlos verteilbaren integrierten Treiber ohne macFUSE.

## Aktualisierung: schreibender Engine-Prototyp vorhanden

Neu ist `NTFS3G/`: NTFS-3G 2026.7.7 ohne FUSE, angepasste GPL-Bridge und
eine opt-in FSKit-Volume-Implementierung. Echte NTFS-Testabbilder wurden
beschrieben und mit macOS unabhängig gelesen. Signierter App-Build erfolgreich.
Inzwischen bestanden: Einhängen über FSKit ohne sudo, Unicode-Datei anlegen,
Lesen/Schreiben, 2-MiB-Datei, Kopieren, Umbenennen, Ersetzen, Löschen,
Verkleinern und fsync auf einem neuen 64-MiB-Testabbild. Nach dem Aushängen
wurden Inhalte und Löschungen mit Apples eigenem NTFS-Lesetreiber unabhängig
verifiziert. Es wurde nicht über die OpenCommander-Oberfläche getestet.

Der bisherige Mountfehler war ein im Kernelprotokoll belegtes `file-mount`
Verbot für `fskitd` am Mountpunkt innerhalb von „Dokumente“. Ein neuer privater
temporärer Mountpunkt löst diesen Fehler ohne Änderung von Datenschutzfreigaben.
Die frühere FSClient-Vorprüfung war ein falsch-negatives Hindernis: Obwohl sie
unsere Erweiterung nicht auflistet, kann macOS sie starten und aktivieren.
Bei fehlendem FSClient-Eintrag wird jetzt zusätzlich pluginkit rein lesend
geprüft und eine Warnung ausgegeben. Registrierung allein gilt nicht als
bestandener Schreibtest. sudo bleibt entfernt, da die Registrierung pro
Benutzer gilt. Mindestens 512 MiB freier Speicher bleiben Testvoraussetzung.
Die vollständige Produktionsreife ist **noch nicht erreicht**; insbesondere
Oberflächentests und Absturz-/Stromausfallsicherheit bleiben offene Prüfungen.

Aktueller Testumfang, reproduzierbare Befehle, Lizenzhinweise und verbleibende
Sicherheitsgrenzen: [NTFS3G/README.md](NTFS3G/README.md).
Die folgenden Abschnitte dokumentieren den früheren MIT-Kern und die erste
Alternativenprüfung. Die Aussage „kein Fremdcode übernommen“ gilt für jenen
Stand und weiterhin für den MIT-Kern, nicht für die neue separate GPL-Bridge.

## Noch nicht erfüllt

Die macOS-App zeigt NTFS-Volumes an und verwendet deren aktuellen Mount.
`Elements` ist bei dieser Prüfung unter `/Volumes/Elements` als NTFS
schreibgeschützt eingebunden. Es wurde bei dieser Prüfung weder umgehängt
noch beschrieben.

Der eigene MIT-lizenzierte Kern in `OpenCommanderNTFS` ersetzt bislang nur
gleich große, bereits vorhandene residente Dateiinhalte in Testabbildern.
Das ist kein allgemeiner NTFS-Schreibtreiber. Es fehlen insbesondere neue
Dateien, Verzeichnisindexänderungen, Speicherplatzzuweisung und ein
absturzsicherer Ablauf für zusammengehörige Metadatenänderungen.

`OpenCommanderNTFSFileSystem.loadResource` liefert im normalen Build weiterhin `ENOTSUP`.
Die Erweiterung zu aktivieren oder ihre Schreibsperren zu entfernen ergänzt
diese fehlenden Operationen nicht. Erfolgreiche Core-Tests und erfolgreiche
App-Builds sind kein Nachweis für funktionierende NTFS-Dateioperationen.

## Weiterentwicklung: FSKit-Blockzugriff

Am 8. September 2026 wurde der bisherige direkte Blockzugriff durch einen
getesteten `SectorAlignedBlockDevice`-Adapter ergänzt. Er richtet kleine und
sektorübergreifende Zugriffe auf die physischen Sektoren aus, erhält bei
Teil-Schreibzugriffen die Nachbardaten und begrenzt einzelne Ressourcenzugriffe
standardmäßig auf 1 MiB. Lesen, Read-Modify-Write und Flush werden innerhalb
derselben Adapterinstanz serialisiert. Kapazitätsüberläufe und Geometrien mit
unvollständigem letzten physischen Sektor werden konservativ abgelehnt.

Dies ist keine Crash-Sicherheit und keine neue NTFS-Dateioperation. Fehler
können nach bereits geschriebenen Teilblöcken auftreten; Transaktions- und
Wiederherstellungslogik bleiben Aufgabe der darüberliegenden Schicht.
Die Mount-Sperre bleibt erhalten. Es wurden nur synthetische Speichergeräte
und Testabbilder beschrieben, keine angeschlossene Festplatte.

Lizenz, Voraussetzungen und Grenzen der FSKit-Nutzung stehen in
[FSKIT-INTEGRATION-DE.md](FSKIT-INTEGRATION-DE.md).

## Geprüfte freie Alternative

- NTFS-3G: https://github.com/tuxera/ntfs-3g
- FSKit-Anbindung: https://github.com/whereteam/ntfskit
- Untersuchte Revision: `b7153a8dd51b895d0a87345c6ad8e95bda963ed3`

NTFSKit bezeichnet `NTFSModule/` und `fsbundle/` als GPL-2.0-lizenziert;
die App-Oberfläche ist davon getrennt lizenziert. Eine Integration muss die
Lizenztexte, Urheberhinweise und die zur Verteilung passenden Quelltexte
einschließlich Änderungen und Buildanweisungen bereitstellen. Fremdcode darf
nicht als Teil unserer unabhängigen MIT-Implementierung ausgegeben werden.
Es wurde kein Code dieses Projekts in OpenCommander übernommen.

Konkreter Hinderungsgrund für die unveränderte Übernahme:
`NTFSModule/NTFSVolume.swift`, `renameItem(...overItem:)` entfernt das
bestehende Ziel mit `nk_delete`, bevor `nk_rename` ausgeführt wird. Scheitert
die Umbenennung, ist das Ziel bereits gelöscht; dieser Pfad stellt es nicht
wieder her. Diese Fehlerbehandlung muss vor einem Einsatz auf Nutzerdaten
ersetzt und mit gezielten Fehlerfällen getestet werden.

Ein weiteres gefundenes Projekt, https://github.com/HuanchuanTech/xntfs,
beschreibt eine FSKit-/NTFS-3G-Anbindung, stellt im geprüften öffentlichen
Dateibaum jedoch nur Dokumentation und Lizenzdateien bereit. Die
README-Buildanleitung allein liefert keine integrierbare Implementierung.

## Abnahmekriterien für eine schreibfähige Version

1. Kostenlos verteilbare Engine samt Lizenz- und Quelltextlieferung integrieren.
2. Neue Dateien, große Dateien, Verzeichnisse, Unicode-Namen, Umbenennen,
   Ersetzen und Löschen auf neu erstellten NTFS-Testabbildern prüfen.
3. Fehler bei vollem Datenträger, Schreibabbrüchen und Ersetzen prüfen;
   schmutzige und hibernierte Volumes dürfen nicht unbemerkt schreibbar werden.
4. Nach dem Aushängen und erneuten Einhängen Inhalte unabhängig verifizieren.
5. Dieselben Operationen über die eingebettete FSKit-Erweiterung und die
   OpenCommander-Oberfläche prüfen, nicht nur über die Engine.
6. Erst danach einen eindeutig benannten neuen Schreibtest auf `Elements`
   durchführen und den zurückgelesenen Inhalt vergleichen.

Bis dahin ist NTFS-Schreiben eine offene Implementierungsaufgabe. Eine
neue Oberflächen-Vorschau darf nicht als schreibfähige NTFS-Version
bezeichnet werden.
