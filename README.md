# ESPHome Git Push for Home Assistant

A Home Assistant app (add-on) that pushes the git history the **ESPHome Device
Builder** already keeps in `/config/esphome` to a **private GitHub repository**, so
your device configs survive the loss of the Home Assistant machine.

- Immediate push after every save in the Device Builder.
- Periodic safety net for files changed outside the Builder.
- `secrets.yaml` pushed only encrypted (`secrets.yaml.gpg`, AES256).
- Retries failed pushes; optional failure notice to the devices and with the text you choose.
- Approve GitHub access once with a code (GitHub App, contents only), or use an SSH deploy key.
- Restores everything, with history, on an empty install.

## Install

[![Add repository to your Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fwillrnsantana%2Fha-esphome-git-push)

Or: **Settings > Apps > App store > ... > Repositories**, add
`https://github.com/willrnsantana/ha-esphome-git-push`, then install **ESPHome Git Push**.

Requires Home Assistant OS or Supervised, and ESPHome Device Builder 2026.6 or later
(the version history feature). See [DOCS.md](esphome_git_push/DOCS.md) for setup.

## License

GPL-3.0. See [LICENSE](LICENSE).
