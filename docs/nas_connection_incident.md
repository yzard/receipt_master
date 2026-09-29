# NAS connection failure: 2026-09-29

## Cause

Android lost access to the NAS API and could not log in again. The service remained
running and served `/`, but `/health` and `/api/auth/login` timed out both through
Caddy and directly at the container's internal address. DNS and TLS succeeded.

The live process backtrace showed SQLite connections blocked in `findReusableFd`
and `unixOpen`, while closing connections waited in `unixClose` and `unixLock`.
Authentication and receipt requests shared SQLite's stuck process-wide mutex.
The image bundled SQLite **3.51.1** via rusqlite 0.38.0 / libsqlite3-sys 0.36.0.

This matches the concurrent WAL connection open/close deadlock reported in the
[SQLite forum](https://sqlite.org/forum/info/7497f8f6052ed70a763672edffb414ec6c6834037cf2d7d4e5b486284fcc6b7a).
SQLite's [3.51.2 release notes](https://sqlite.org/releaselog/3_51_2.html)
document the Unix locking fix. The replacement uses **3.51.3**, which also contains
the subsequent WAL-reset fix, via rusqlite 0.39.0 / libsqlite3-sys 0.37.0.

## Repair and verification

- Restart the affected process to release the deadlocked in-process locks and
  restore access while preparing the corrected image.
- Update only the SQLite dependency pair and its lockfile; no schema migration,
  password reset, database replacement, or client server-address change.
- Add a regression test requiring SQLite 3.51.3 or newer and exercising 12 threads
  repeatedly opening, reading, and closing the authentication and receipt WAL
  databases. A subprocess deadline makes a future deadlock fail instead of
  hanging the whole test runner.
- Run the combined Docker build and its API, authentication, Android/Web and
  container HTTP checks before installing the tested image on the NAS.
- Verify the live HTTPS route, prompt preservation, and both databases with
  `PRAGMA quick_check`. Before replacement both databases passed; 100 receipt
  records remained present.

The captured backtrace is a local diagnostic artifact in
`build/backend_api/nas-connection-debug/receipts-hang-backtrace.txt`. It contains
function stacks, not password or token values.

## Deployed result

The corrected API image is
`sha256:2a723102d4ffff696182db94f25411817557189caf5322d0d05ee4071e043511`,
tagged `20260929` and `latest`, installed by local image transfer and recreation
of only `receipts`. Its executable contains SQLite 3.51.3. The existing Android
APK remains build 10073; a client upgrade is not required for this server repair.

Through the real HTTPS domain, 1,200 requests at concurrency 16 completed in
0.98 seconds, with a maximum individual duration of 0.034 seconds. Health requests
returned 200; deliberately invalid JWT requests returned 401 instead of hanging.
The login endpoint also responded promptly with the expected invalid-credentials
error for a diagnostic nonexistent user. Correct-credential login and session
behavior passed the container HTTP tests; the user's actual password was not
requested or used in diagnostics.

After replacement, both databases passed `quick_check`, all 100 receipts remained,
the schema version stayed 15, and admin still did not require a password reset.
The operator prompt SHA256 stayed
`339dbeae3303e1772bc2a964218e0a2f593a4f4be79b27a2512dbc6c057cdd72`.
