# OpenCommander Media Package

Stand: 19. Juni 2026

## Play Store Images

Store-ready cleaned copies:

- `playstore/final-clean/app-icon-512.png`
- `playstore/final-clean/feature-graphic-1024x500.png`
- `playstore/final-clean/phone-01.png`
- `playstore/final-clean/phone-02.png`
- `playstore/final-clean/phone-03.png`
- `playstore/final-clean/phone-04.png`
- `playstore/final-clean/phone-05.png`

Raw generated copies are kept in `playstore/final/`.

## Videos

- `release/video/opencommander-promo.mp4` - 24 second portrait promo draft
- `release/video/opencommander-dual-pane.mp4` - 8 second dual-pane clip
- `release/video/opencommander-undo.mp4` - 8 second delete/trash/undo clip
- `release/video/opencommander-zip.mp4` - 8 second ZIP clip

Google Play requires a YouTube URL for promo videos, not a direct MP4 upload. Upload the chosen MP4 to YouTube and enter that URL in the Play Console.

## Gemini Notes

`MEDIA-PROMPTS.md` contains Gemini/Veo prompts for regenerating these assets through Gemini. The current repository does not include local `gemini/` or `gemini-video/` automation scripts, so this package was generated locally from product UI drafts and existing project assets.

The Gemini watermark cleaner was run on copy outputs in `playstore/final-clean/` with a small bottom-right region. Use the cleaned images for store upload.

## Verification

- Icon: 512x512 PNG
- Feature graphic: 1024x500 PNG
- Phone screenshots: 1080x1920 PNG
- Videos: 1080x1920 MP4
