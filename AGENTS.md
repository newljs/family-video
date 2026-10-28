# Family Video

- This is an original monorepo: Flutter parent/kids applications and a Go server. Python is only used by the isolated F2 download tool.
- Keep downloads and FFmpeg processing in the Go background worker, never inside API requests. The worker starts with the HTTP server.
- All successfully processed videos are immediately visible to children (review/publishing was explicitly removed by the user). Never expose incomplete or failed import files.
- Never commit runtime data, credentials, cookies, signing keys or downloaded videos.
- Never create Android emulator AVDs inside this repository. Use `scripts/tv-emulator.ps1`, which keeps `ANDROID_AVD_HOME` outside the repo and caps `disk.dataPartition.size`; one device otherwise preallocates gigabytes (an AVD left in `runtime/` filled the disk once).
- Download providers must remain replaceable. Do not copy upstream platform algorithms into business code.
- Update README and docs when behavior or setup changes. State unverified device/platform behavior honestly.
- Before delivery run Go tests/vet and Flutter analysis/tests. Legacy Python source is historical reference, never the current backend.
