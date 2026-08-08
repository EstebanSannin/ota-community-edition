# Archived docs

Superseded / obsolete documentation, kept for reference rather than deleted. **Do not rely on
these** — they describe earlier flows that no longer match the current system. Current docs are one
level up in `docs/`.

| File | Why it's archived |
|---|---|
| `api-updates.md` | Pre-console dev notes using the raw `*.ota.ce` host-based API, the removed **`campaigner`** service, `device_groups`, and "ota-lith runs without auth". Superseded by the console + `docs/tooling-credentials.md` + the API reference at `console/apidocs/`. |
| `updates-ota-cli.md` | Driving updates with `simao/ota-cli` via **`campaigner`** (`ota init --campaigner …`) — campaigner was removed from the stack, so this flow no longer applies. |
