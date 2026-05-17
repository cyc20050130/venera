# Changelog

## 1.6.5 - 2026-05-17

Release tag: `v8a`

- Fixed cache cleanup stability and cache database self-recovery.
- Fixed reading history indexing to use stable `sourceKey`, preventing cross-source collisions.
- Restored continue-reading progress across export and import on the repaired package format.
- Fixed history schema migration recovery when an upgrade is interrupted.
- Updated in-app update links to `cyc20050130/venera` and removed the Telegram entry.
- Merged offline cache improvements, including comic details caching and related offline reading updates.
