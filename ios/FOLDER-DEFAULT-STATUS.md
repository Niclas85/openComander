# Folder default and unified Mac styling — 27 September 2026

The Mac app asks once whether it should open folders instead of Finder. No
association is changed by installation, first launch, or Later. The choice is
available again through the Default folder app toolbar button, including an
explicit action to return the folder association to Finder. Errors are shown;
success is reported only after the native API completion succeeds.

The AppKit bridge uses Apple's public
[setDefaultApplication(at:toOpen:completion:)](https://developer.apple.com/documentation/appkit/nsworkspace/setdefaultapplication(at:toopen:completion:))
for UTType.folder. This is not replacement of Finder's desktop or system UI.
Document associations are untouched. Folder capability is declared with Alternate
handler rank, and incoming file URLs are validated as non-package directories
and routed into the active pane without reopening the default handler.

The Mac toolbar uses neutral surfaces, red destructive actions, larger labels,
and consistent borders. Both panes share the blue accent; the light selection
color is blue. Dialog appearance follows the selected app theme.

Verification:
- Mac Catalyst experimental NTFS build and strict deep signature verification pass.
- Installed with the previous app backed up; NTFS build condition preserved.
- First-run choice visibly appears; Later dismisses it without choosing an app.
- Relaunch does not repeat the prompt; the toolbar reopens it with both choices.
- Light-mode layout visually inspected. English and German text included.
- Actual association change, rollback and OS-delivered folder-open events are
  implemented but NOT end-to-end verified: no user default was changed during QA.
- iOS build was blocked by disk exhaustion; it is not reported as passing.
- The first Mac build also hit disk exhaustion; its retry succeeded. Cleanup of
  the temporary iOS build was rejected by the environment; no files were deleted.

No release or push was performed. The current dialog is left open for the user's
own selection. Local installed-app backup: /tmp/OpenCommander-Before-Design.Mavhre.
