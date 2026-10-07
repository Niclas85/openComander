# Cloud copy live test — 2026-10-07

Tested the installed `/Applications/OpenCommander.app` through its visible UI.
Only generated `OpenCommander-Cloud-QA-20261007` fixtures were changed. Google
Drive and iCloud were accessed through their installed macOS File Providers;
OneDrive used the application's online Graph integration. Remote completion of
Google/iCloud background synchronization was not independently verified.

Fixtures: `A/Kopiertest.txt` and `B/Kopiertest.txt`, with different contents.

| Fixture | SHA-256 |
| --- | --- |
| A | `8202f0cb3e8187265ea61dabd2ef12c6a15c7eb7de210d8dfbf9f3605b1d5e25` |
| B | `ad184d80a1d0cd425047ddcc8c9b1902b260ca5580dbc8b6ab52b6f27626a0e9` |

## Observed results

- Local test folder → OneDrive Online: recursive upload completed; A/B listed.
- Local test folder → iCloud: completed, both hashes match.
- iCloud folder → Google Drive: completed, both hashes match.
- Google Drive B → iCloud A via Cmd+C/V: silently created `Kopiertest (2).txt`;
  original A remained intact, numbered copy matches B. No replacement dialog.
- Google Drive B → iCloud A via F5: Replace dialog appeared; replacement matches B.
- iCloud B → Google Drive A via F5: Cancel preserved A; repeating with Replace
  changed destination to B. Source B remained intact.
- OneDrive A → iCloud test root: completed, downloaded hash matches A. Transfer
  indicator was visible while downloading.
- Repeating OneDrive A → same iCloud destination: failed with `Destination
  already exists: Kopiertest.txt. Source retained.` No overwrite/keep-both choice.
- OneDrive A → Google Drive test root: completed, hash matches A.
- Google Drive B → OneDrive A: conflict dialog offered Keep Both / Skip / Cancel,
  not Replace. Keep Both created `Kopiertest (2).txt` alongside original A.
- iCloud B → OneDrive test root → local temporary test root: completed;
  downloaded hash matches B.
- History panel displayed all successful test transfers with complete source and
  destination paths, including replacements and the numbered OneDrive copy.

OneDrive progress and native directory-loading indicators were observed. A genuine
remote-sync percentage for Google/iCloud was not verified. Automated OneDrive tests
passed 14 groups; local file safety/history tests passed 9 groups.

## Outstanding gaps

- OneDrive conditional replacement and folder merging are not implemented.
- OneDrive → local/FileProvider destinations reject collisions without choices.
- Local Cmd+C/V and F5 have inconsistent collision behavior.
- Automated native mouse dragging did not initiate a transfer during this session;
  it is not counted as a successful drag-and-drop test.

This is a small-text-file regression test, not exhaustive coverage of large files,
offline providers, quota exhaustion or network interruption. Generated test folders
remain for inspection in iCloud, Google Drive and OneDrive
`OpenCommander-Funktionstest/Quelle`; personal files were not modified.
