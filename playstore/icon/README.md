# Android launcher and Google Play icon

`google-play-current-512.png` is the exact artwork published on Google Play for
`com.opencommander`, verified on 2026-10-07. It shows two file panes and a ZIP
archive. The white folder with OC used by the Apple listing is a different asset.

The Android launcher reuses this PNG unchanged in
`app/src/main/res/drawable-nodpi/launcher_store_artwork.png`. Both adaptive icon
resources reference the same foreground. A percentage inset keeps the panes and
ZIP visible when launchers apply circular or other masks. The unversioned normal
and round mipmaps also reuse the same artwork.

When replacing the icon, update the Google Play listing and all three Android
PNG copies together. Verify their image contents match and check the installed
app in a physical phone's launcher, including opening the app from its icon.
An icon change in the listing alone does not update installed APK resources;
customers need a new Android app update.

The older `app-icon-512.png` files under this directory and `playstore/final*`
are historical marketing assets, not the current Android launcher reference.
