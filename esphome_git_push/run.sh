#!/usr/bin/with-contenv bashio
# ESPHome Git Push: pushes the git history of /config/esphome (kept by the
# ESPHome Device Builder, one commit per save) to a private GitHub repository.
# - Every new Device Builder commit is pushed right away (inotify on .git/logs).
# - Every N minutes, changes made outside the Builder are committed and pushed.
# - secrets.yaml is pushed only as secrets.yaml.gpg (AES256, password in options).
# - A failed push is retried push_retries times. If every attempt fails: a
#   persistent notification, an esphome_git_push_failed event and, if enabled,
#   the configured message sent to the chosen notify services (once per failure
#   streak; cleared on the next successful push).

set +e
# Bash 5.2: keep '&' in error texts literal when filling message templates.
shopt -u patsub_replacement 2>/dev/null

ESP_DIR=/homeassistant/esphome
SSH_DIR=/data/ssh
KEY="${SSH_DIR}/id_ed25519"
KNOWN="${SSH_DIR}/known_hosts"
LOCK=/tmp/esphome_git_push.lock
NOTIF_ID=esphome_git_push_failure
FAILING_FLAG=/data/failing

REPO="$(bashio::config 'repository')"
if [ "${REPO}" = "null" ]; then REPO=""; fi
BRANCH="$(bashio::config 'branch')"
INTERVAL="$(bashio::config 'interval_minutes')"
RETRIES="$(bashio::config 'push_retries')"
RETRY_DELAY="$(bashio::config 'retry_delay_seconds')"

git_esp() {
    git -c safe.directory='*' -c core.fileMode=false -C "${ESP_DIR}" "$@"
}

# POST to the Home Assistant Core API through the Supervisor proxy.
ha_api() {
    curl -s -o /dev/null -w '%{http_code}' -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -d @- "http://supervisor/core/api/$1"
}

# Replace {error}, {attempts} and {repository} in a user template.
fill_template() {
    local text="$1" error="$2" attempts="$3"
    text="${text//\{error\}/${error}}"
    text="${text//\{attempts\}/${attempts}}"
    text="${text//\{repository\}/${REPO}}"
    printf '%s' "${text}"
}

report_failure() {
    local error="$1" attempts="$2" title message code service
    title="$(fill_template "$(bashio::config 'failure_title')" "${error}" "${attempts}")"
    message="$(fill_template "$(bashio::config 'failure_message')" "${error}" "${attempts}")"

    jq -n --arg t "${title}" --arg m "${message}" --arg id "${NOTIF_ID}" \
        '{title: $t, message: $m, notification_id: $id}' \
        | ha_api services/persistent_notification/create > /dev/null
    jq -n --arg e "${error}" --arg r "${REPO}" --argjson a "${attempts}" \
        '{error: $e, repository: $r, attempts: $a}' \
        | ha_api events/esphome_git_push_failed > /dev/null

    # Device notifications: only once per failure streak.
    if [ -f "${FAILING_FLAG}" ]; then return 0; fi
    touch "${FAILING_FLAG}"
    if ! bashio::config.true 'notify_on_failure'; then return 0; fi
    for service in $(bashio::config 'notify_services'); do
        if [[ "${service}" != *.* ]]; then
            bashio::log.warning "Ignoring notify service '${service}': use domain.service, e.g. notify.mobile_app_my_phone"
            continue
        fi
        code="$(jq -n --arg t "${title}" --arg m "${message}" '{title: $t, message: $m}' \
            | ha_api "services/${service%%.*}/${service#*.}")"
        if [ "${code}" = "200" ]; then
            bashio::log.info "Failure notice sent via ${service}."
        else
            bashio::log.error "Could not call ${service} (HTTP ${code})."
        fi
    done
}

clear_failure() {
    if [ -f "${FAILING_FLAG}" ]; then
        rm -f "${FAILING_FLAG}"
        jq -n --arg id "${NOTIF_ID}" '{notification_id: $id}' \
            | ha_api services/persistent_notification/dismiss > /dev/null
        bashio::log.info "Push working again."
    fi
}

setup_ssh() {
    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"
    if [ ! -f "${KEY}" ]; then
        bashio::log.info "Generating the app SSH key (one time only)."
        ssh-keygen -q -t ed25519 -N "" -C "esphome-git-push@homeassistant" -f "${KEY}"
    fi
    # GitHub's published host key (https://api.github.com/meta), pinned.
    echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" > "${KNOWN}"
    export GIT_SSH_COMMAND="ssh -i ${KEY} -o IdentitiesOnly=yes -o UserKnownHostsFile=${KNOWN} -o StrictHostKeyChecking=yes"
    bashio::log.info "App public key (add it as a Deploy key with write access to the repository):"
    bashio::log.info "$(cat "${KEY}.pub")"
}

encrypt_secrets() {
    local password source="${ESP_DIR}/secrets.yaml" target="${ESP_DIR}/secrets.yaml.gpg"
    password="$(bashio::config 'secrets_password')"
    if [ "${password}" = "null" ]; then password=""; fi
    if [ ! -f "${source}" ]; then return 0; fi
    if [ -z "${password}" ]; then
        bashio::log.warning "secrets_password is empty: secrets.yaml will NOT be pushed."
        return 0
    fi
    local current_hash saved_hash=""
    # Fingerprint of content + password: changing either one re-encrypts.
    current_hash="$({ cat "${source}"; printf '%s' "${password}"; } | sha256sum | cut -d' ' -f1)"
    if [ -f /data/secrets.sha256 ]; then saved_hash="$(cat /data/secrets.sha256)"; fi
    # Re-encrypt only when content or password change (every encryption produces new bytes).
    if [ "${current_hash}" != "${saved_hash}" ] || [ ! -f "${target}" ]; then
        if printf '%s' "${password}" | gpg --batch --yes --quiet --pinentry-mode loopback \
            --passphrase-fd 0 --symmetric --cipher-algo AES256 -o "${target}" "${source}"; then
            echo "${current_hash}" > /data/secrets.sha256
            bashio::log.info "secrets.yaml encrypted to secrets.yaml.gpg."
        else
            bashio::log.error "Failed to encrypt secrets.yaml."
        fi
    fi
}

safety_commit() {
    if [ -f "${ESP_DIR}/.git/index.lock" ]; then
        bashio::log.info "Device Builder is using the repository right now; retrying next cycle."
        return 0
    fi
    encrypt_secrets
    if ! git_esp add -A -- .; then return 0; fi
    if ! git_esp diff --cached --quiet; then
        git_esp -c user.name="ESPHome Git Push" -c user.email="esphome-git-push@homeassistant.local" \
            -c commit.gpgsign=false commit --no-verify -q \
            -m "Automatic backup: changes made outside the Device Builder" \
            && bashio::log.info "Safety commit recorded."
    fi
}

push() {
    if [ -z "${REPO}" ]; then
        bashio::log.warning "Option 'repository' is empty: nothing pushed. E.g. git@github.com:USER/esphome-configs.git"
        return 0
    fi
    local output attempt total=$((RETRIES + 1))
    for attempt in $(seq 1 "${total}"); do
        if output="$(git_esp push "${REPO}" "HEAD:refs/heads/${BRANCH}" 2>&1)"; then
            bashio::log.info "Pushed to ${REPO} (${BRANCH}): $(git_esp log -1 --format='%h %s')"
            clear_failure
            return 0
        fi
        bashio::log.warning "Push attempt ${attempt}/${total} failed: ${output}"
        if [ "${attempt}" -lt "${total}" ]; then sleep "${RETRY_DELAY}"; fi
    done
    bashio::log.error "Push failed after ${total} attempts."
    report_failure "${output}" "${total}"
}

cycle() {
    (
        flock 9
        if [ "$1" = "safety" ]; then safety_commit; fi
        push
    ) 9>"${LOCK}"
}

# ---- start ----
until [ -d "${ESP_DIR}/.git" ]; do
    bashio::log.warning "${ESP_DIR} is not a git repository yet (the Device Builder creates it on save). Waiting..."
    sleep 300
done

setup_ssh
cycle safety

# Periodic safety net.
(
    while true; do
        sleep $((INTERVAL * 60))
        cycle safety
    done
) &

# Immediate push on every Device Builder commit (logs/HEAD gets one line per commit).
inotifywait -m -q -e close_write,moved_to,modify --format '%f' "${ESP_DIR}/.git/logs" | while read -r file; do
    if [ "${file}" != "HEAD" ]; then continue; fi
    sleep 15
    # One save fires several events (modify + close_write): drop the ones queued
    # during the wait so a burst of events becomes a single push.
    while read -r -t 1 _; do :; done
    cycle push
done
