# Changelog

## 1.0.2

- Changing `secrets_password` now re-encrypts `secrets.yaml.gpg` on the next
  start. Before, the file was only re-encrypted when `secrets.yaml` itself changed.

## 1.0.1

- A single save in the Device Builder no longer triggers two pushes: events
  queued during the 15 s wait are now collapsed into one push.

## 1.0.0

- First release: immediate push of Device Builder commits, periodic safety-net
  commits, encrypted `secrets.yaml`, failure notification.
