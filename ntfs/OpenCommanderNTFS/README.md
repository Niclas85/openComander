# OpenCommanderNTFS

`OpenCommanderNTFS` is an independent, MIT-licensed NTFS implementation for OpenCommander. It does not contain code from NTFS-3G, macFUSE, Tuxera, or another NTFS driver.

Implemented and tested:

- NTFS boot-sector validation and geometry
- MFT `FILE` record update-sequence fixups
- resident and nonresident attribute headers
- signed data-run decoding, including sparse runs
- bounded read-only volume access and direct `$MFT` record loading
- bounded block-device I/O
- serialized, sector-aligned byte-range adapter for FSKit resources, including
  read-modify-write for partial sectors and bounded underlying transfers
- sector-aligned write transactions with rollback
- verified read-modify-write transactions for sub-sector metadata changes
- update-sequence encoding for writing multi-sector `FILE` records
- image-tested, same-size replacement of existing resident file data
- pre-write checks for NTFS version/flags, backup boot sector, and `$MFTMirr`
- resident and allocation-backed `$I30` directory-index parsing
- automatic fail-closed `hiberfil.sys` state detection
- a fail-closed write policy for dirty, hibernated, unchecked, or unsupported volumes

The resident-data writer is deliberately limited to active user-file records (MFT record 24 or later), requires the expected record sequence and original value, and cannot resize data. It is infrastructure for image tests, **not yet a complete NTFS metadata writer**. The FSKit module therefore probes NTFS media but refuses to mount it until directory-index mutation, volume allocation-bit updates, `$LogFile` recovery, and crash-consistent metadata updates are implemented and validated.
