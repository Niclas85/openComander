# Third-party source and licensing

This integration is GPL-2.0-or-later, NOT part of the independently written
MIT-licensed OpenCommanderNTFS Swift package.

## NTFS-3G

- Project: https://github.com/tuxera/ntfs-3g
- Release: 2026.7.7 (security release)
- Source: https://download.tuxera.com/opensource/ntfs-3g_ntfsprogs-2026.7.7.tgz
- SHA-256: `d67b769025d32860549d35c2147e45024d172f81c540d750390ce3602c059dab`
- The complete unmodified release source is retained in `vendor/`.
- Copyright, AUTHORS, COPYING and COPYING.LIB are in the source archive.
- Build uses the GPL-covered NTFS engine; no FUSE library is linked.

## NTFSKit engine facade

- Project: https://github.com/whereteam/ntfskit
- Revision: `b7153a8dd51b895d0a87345c6ad8e95bda963ed3`
- Original files: `NTFSModule/bridge/ntfs_bridge.c` and `ntfs_bridge.h`
- SPDX license in these files: GPL-2.0-or-later.
- Only the callback-backed byte-copy facade was adapted. No proprietary app
  UI, BitLocker, formatter, kernel-offloaded I/O or filesystem Swift code was imported.
- OpenCommander changes include required flush callback, checked I/O bounds,
  no automatic journal reset, read-only safety preflight, duplicate/name checks,
  propagated close errors and recovery-name-based replacement.

## Distribution gate

Distribute the corresponding source, this notice, COPYING, build/test scripts,
and complete vendor source alongside any binary containing this engine, in
accordance with GPLv2 section 3. Do not label the linked filesystem extension
MIT-only. Do not distribute an app-store binary before checking the compatibility
of its distribution terms with GPL obligations. This development work does not
grant a commercial Tuxera or Paragon license.
