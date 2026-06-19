# Demo Video Plan

Ziel: 3 kurze Clips fuer Play Store, GitHub und Community-Posts. Jeder Clip soll echte App-Bedienung zeigen, nicht nur Text.

## Clip 1: Zwei Seiten, schneller kopieren

- Format: 9:16, 10-15 Sekunden
- Hook: `Two panes. Faster file work.`
- Szene 1: App im Querformat mit beiden Seiten sichtbar
- Szene 2: Datei markieren
- Szene 3: Datei per Drag & Drop auf die andere Seite ziehen
- Szene 4: Fortschritt kurz sichtbar
- CTA: `OpenCommander - free and open source`

## Clip 2: Fehler rueckgaengig machen

- Format: 9:16, 10-15 Sekunden
- Hook: `Undo file actions.`
- Szene 1: Datei verschieben oder loeschen
- Szene 2: Historie oeffnen
- Szene 3: Aktion rueckgaengig machen
- Szene 4: Datei ist wieder sichtbar
- CTA: `No ads. No tracking. Local files.`

## Clip 3: ZIP wie Ordner

- Format: 9:16, 10-15 Sekunden
- Hook: `Open ZIPs like folders.`
- Szene 1: ZIP-Datei in Dateiliste sichtbar
- Szene 2: ZIP oeffnen
- Szene 3: Ordnerstruktur im ZIP durchsuchen
- Szene 4: Dateien/Ordner als ZIP erstellen
- CTA: `OpenCommander on GitHub`

## Aufnahme

Mit angeschlossenem Android-Geraet:

```powershell
adb shell screenrecord /sdcard/opencommander-demo.mp4
adb pull /sdcard/opencommander-demo.mp4 release/opencommander-demo.mp4
```

Danach lokal schneiden, Textoverlays setzen und auf Wasserzeichen, Lesbarkeit und private Dateinamen pruefen.
