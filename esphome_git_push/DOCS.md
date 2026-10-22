# ESPHome Git Push

Since 2026.6 the ESPHome Device Builder keeps a **local** git history of
`/config/esphome` (one commit per save), but it never leaves Home Assistant: if the
machine dies, the history dies with it. This app pushes that history to a
**private** GitHub repository.

## What it does

- Pushes every new Device Builder commit about 15 seconds after you save.
- Every `interval_minutes`, commits and pushes changes made outside the Builder
  (Samba, File editor, `packages/`, `archive/`, images).
- Pushes `secrets.yaml` only encrypted, as `secrets.yaml.gpg` (GnuPG, AES256).
- Retries a failed push (`push_retries`, default 3). If every attempt fails, it
  raises a persistent notification and an `esphome_git_push_failed` event and,
  optionally, sends your own message to the devices you choose.
- Uses its own SSH key, generated on first start. Only the public half leaves the app.

It never rewrites history and never pushes with `--force`.

## Setup

1. Create an **empty private** repository on GitHub (no README, no .gitignore).
2. Start the app and copy, from the **Log** tab, the line
   `ssh-ed25519 ... esphome-git-push@homeassistant`.
3. In the repository: **Settings > Deploy keys > Add deploy key**, paste the key and
   tick **Allow write access**. A deploy key gives access to that repository only.
4. In the app **Configuration** tab:
   - `repository`: `git@github.com:USER/REPOSITORY.git`
   - `branch`: `main`
   - `secrets_password`: password to encrypt `secrets.yaml`. Store it in your
     password manager; without it the file cannot be decrypted.
   - `interval_minutes`: safety-net interval.
5. Restart the app and check the log for `Pushed to ...`.

## Failure notices

| Option | Default | Meaning |
|---|---|---|
| `push_retries` | 3 | Extra attempts after a failed push |
| `retry_delay_seconds` | 30 | Wait between attempts |
| `notify_on_failure` | false | Send a notice to devices after all attempts fail |
| `notify_services` | (empty) | Actions to call, one per line: `notify.mobile_app_my_phone`, `script.my_script` |
| `failure_title` / `failure_message` | English text | Your text; placeholders `{repository}`, `{attempts}`, `{error}` |

Each service is called with `title` and `message`, so a script with those two
fields also works. Device notices go out once per failure streak; the next
successful push clears the persistent notification and re-arms them.

Every final failure also fires the event `esphome_git_push_failed` with
`error`, `repository` and `attempts`, for your own automations.

## Restoring

```
git clone git@github.com:USER/REPOSITORY.git esphome
gpg -d -o esphome/secrets.yaml esphome/secrets.yaml.gpg
```

`gpg` ships with Git for Windows (`C:\Program Files\Git\usr\bin\gpg.exe`).

## Notes

- Keep the repository **private**: ESPHome YAML often contains inline API
  encryption keys and OTA passwords.
- The app writes `secrets.yaml.gpg` into `/config/esphome` and adds commits authored
  "ESPHome Git Push" to the existing repository. The Device Builder adopts existing
  repositories and keeps working normally.
