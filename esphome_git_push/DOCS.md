# ESPHome Git Push

Since 2026.6 the ESPHome Device Builder keeps a **local** git history of
`/config/esphome` (one commit per save), but it never leaves Home Assistant: if the
machine dies, the history dies with it. This app pushes that history to a
**private** GitHub repository, and brings it back on a fresh install.

## What it does

- Pushes every new Device Builder commit about 15 seconds after you save.
- Every `interval_minutes`, commits and pushes changes made outside the Builder
  (Samba, File editor, `packages/`, `archive/`, images).
- Pushes `secrets.yaml` only encrypted, as `secrets.yaml.gpg` (GnuPG, AES256).
- On an **empty** `/config/esphome`, restores everything from the repository,
  with the full history, and decrypts `secrets.yaml`.
- Retries a failed push (`push_retries`, default 3). If every attempt fails, it
  raises a persistent notification and an `esphome_git_push_failed` event and,
  optionally, sends your own message to the devices you choose.

It never rewrites history and never pushes with `--force`.

## Setup (GitHub App, default)

1. Create an **empty private** repository on GitHub (no README, no .gitignore).
2. Install the **ESPHome Git Push for HA** GitHub App on that repository only:
   <https://github.com/apps/esphome-git-push-for-ha> > Install > Only select
   repositories. It asks only for read and write access to repository contents.
3. In the app **Configuration** tab:
   - `repository`: `USER/REPOSITORY`
   - `secrets_password`: password to encrypt `secrets.yaml`. Store it in your
     password manager; without it the file cannot be decrypted.
   - optionally `notify_services` (see below), so the approval code also reaches
     your phone.
4. Start the app. A notification shows a code: open
   <https://github.com/login/device>, enter it and approve. Done: the access
   renews by itself. You only approve again after a reinstall, or if Home
   Assistant stays off for more than 6 months.

### SSH deploy key (alternative)

Set `auth: ssh`, start the app and copy the `ssh-ed25519 ...` line from the log
into the repository: **Settings > Deploy keys > Add deploy key**, tick
**Allow write access**.

## Disaster recovery

On a new Home Assistant, before saving anything in the ESPHome Builder:

1. Install ESPHome Device Builder and this app.
2. Fill `repository` and `secrets_password`, start the app and approve the code.
3. The app sees the empty `/config/esphome`, restores all files with their history
   and decrypts `secrets.yaml`. A notification confirms how many files came back.

If the folder already has YAML files, nothing is restored and nothing is
overwritten. Manual restore, from any computer:

```
git clone https://github.com/USER/REPOSITORY.git esphome
gpg -d -o esphome/secrets.yaml esphome/secrets.yaml.gpg
```

`gpg` ships with Git for Windows (`C:\Program Files\Git\usr\bin\gpg.exe`).

## Failure notices

| Option | Default | Meaning |
|---|---|---|
| `push_retries` | 3 | Extra attempts after a failed push |
| `retry_delay_seconds` | 30 | Wait between attempts |
| `notify_on_failure` | false | Send a notice to devices after all attempts fail |
| `notify_services` | (empty) | Actions to call, one per line: `notify.mobile_app_my_phone`, `script.my_script` |
| `failure_title` / `failure_message` | English text | Placeholders `{repository}`, `{attempts}`, `{error}` |
| `approval_title` / `approval_message` | English text | Placeholders `{code}`, `{url}`, `{repository}` |

Each service is called with `title` and `message`; `script.*` entries are started
with `script.turn_on` and receive both as variables. Failure notices go out once
per failure streak; the next successful push clears the persistent notification.

Every final failure also fires the event `esphome_git_push_failed` with
`error`, `repository` and `attempts`.

## Notes

- Keep the repository **private**: ESPHome YAML often contains inline API
  encryption keys and OTA passwords.
- The app writes `secrets.yaml.gpg` into `/config/esphome`, adds commits authored
  "ESPHome Git Push" and keeps the Device Builder's never-commit list (state
  files, peer keys) in `.git/info/exclude`.
