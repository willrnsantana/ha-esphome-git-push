# Changelog

## 1.1.1

- The approval notice links to the GitHub App install page (new placeholder
  `{install_url}`).
- When GitHub refuses the push because the GitHub App is not installed on the
  repository, the failure notice says so and gives the install link.

## 1.1.0

- **GitHub App authentication (new default, `auth: github_app`)**: approve a code
  once at github.com/login/device; no SSH key or token to store. The code is sent
  to the persistent notifications and to `notify_services`. Access renews by
  itself (8 h tokens, 6-month refresh).
  To keep using a deploy key, set `auth: ssh`.
- **Restore on an empty install (`restore_if_empty`, default on)**: when
  `/config/esphome` has no repository and no YAML, the app clones the repository
  back with its full history and decrypts `secrets.yaml`. It never touches a
  folder that already has YAML files.
- `repository` accepts `USER/REPOSITORY` as well as https and git@ URLs.
- The app now enforces the Device Builder's never-commit list (state files,
  peer keys, build output) plus `secrets.yaml` in `.git/info/exclude`.
- New options `approval_title` / `approval_message` with `{code}` and `{url}`.

## 1.0.5

- A push that hangs (e.g. GitHub not answering the SSH connection) now times out
  after 120 s and counts as a failed attempt, instead of freezing the app.
- SSH connect timeout (20 s) and keep-alive.

## 1.0.4

- `script.*` entries in `notify_services` are started with `script.turn_on`
  (title and message as variables) so a long script never blocks the app.
- 30 s timeout on calls to Home Assistant.

## 1.0.3

- Failed pushes are retried (`push_retries`, default 3; `retry_delay_seconds`,
  default 30).
- Only after every attempt fails: persistent notification, new
  `esphome_git_push_failed` event and, if `notify_on_failure` is on, your
  `failure_title` / `failure_message` sent to the `notify_services` you list
  (once per failure streak).
- The persistent notification is cleared only when a push succeeds after a failure.

## 1.0.2

- Changing `secrets_password` now re-encrypts `secrets.yaml.gpg` on the next
  start. Before, the file was only re-encrypted when `secrets.yaml` itself changed.

## 1.0.1

- A single save in the Device Builder no longer triggers two pushes: events
  queued during the 15 s wait are now collapsed into one push.

## 1.0.0

- First release: immediate push of Device Builder commits, periodic safety-net
  commits, encrypted `secrets.yaml`, failure notification.
