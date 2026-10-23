#!/usr/bin/with-contenv bashio
# ESPHome Git Push: pushes the git history of /config/esphome (kept by the
# ESPHome Device Builder, one commit per save) to a private GitHub repository.
# - Every new Device Builder commit is pushed right away (inotify on .git/logs).
# - Every N minutes, changes made outside the Builder are committed and pushed.
# - secrets.yaml is pushed only as secrets.yaml.gpg (AES256, password in options).
# - Authentication: GitHub App device flow (approve a code once; tokens renew by
#   themselves) or a classic SSH deploy key.
# - Restore: on an empty /config/esphome, clones the repository back and
#   decrypts secrets.yaml.
# - A failed push is retried push_retries times. If every attempt fails: a
#   persistent notification, an esphome_git_push_failed event and, if enabled,
#   the configured message sent to the chosen notify services (once per failure
#   streak; cleared on the next successful push).

set +e
# Bash 5.2: keep '&' in texts literal when filling message templates.
shopt -u patsub_replacement 2>/dev/null

ESP_DIR=/homeassistant/esphome
SSH_DIR=/data/ssh
KEY="${SSH_DIR}/id_ed25519"
KNOWN="${SSH_DIR}/known_hosts"
TOKEN_FILE=/data/github_token.json
LOCK=/tmp/esphome_git_push.lock
NOTIF_ID=esphome_git_push_failure
AUTH_NOTIF_ID=esphome_git_push_auth
FAILING_FLAG=/data/failing

REPO_OPT="$(bashio::config 'repository')"
if [ "${REPO_OPT}" = "null" ]; then REPO_OPT=""; fi
BRANCH="$(bashio::config 'branch')"
INTERVAL="$(bashio::config 'interval_minutes')"
RETRIES="$(bashio::config 'push_retries')"
RETRY_DELAY="$(bashio::config 'retry_delay_seconds')"
AUTH="$(bashio::config 'auth')"
CLIENT_ID="$(bashio::config 'github_app_client_id')"
# Install page of the public ESPHome Git Push GitHub App (default client ID).
DEFAULT_CLIENT_ID=Iv23liKLQWIKK4ZMEqeJ
if [ "${CLIENT_ID}" = "${DEFAULT_CLIENT_ID}" ]; then
    INSTALL_URL="https://github.com/apps/esphome-git-push-for-ha/installations/new"
else
    INSTALL_URL="the install page of your GitHub App"
fi

# Accept owner/repo, https://github.com/owner/repo(.git) or git@github.com:owner/repo(.git).
SLUG="${REPO_OPT}"
SLUG="${SLUG#https://github.com/}"
SLUG="${SLUG#git@github.com:}"
SLUG="${SLUG%.git}"
SLUG="${SLUG%/}"
REPO="${SLUG}"
if [ "${AUTH}" = "ssh" ]; then
    REMOTE="git@github.com:${SLUG}.git"
else
    REMOTE="https://github.com/${SLUG}.git"
fi

git_esp() {
    git -c safe.directory='*' -c core.fileMode=false -C "${ESP_DIR}" "$@"
}

# POST to the Home Assistant Core API through the Supervisor proxy.
ha_api() {
    curl -s -m 30 -o /dev/null -w '%{http_code}' -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -d @- "http://supervisor/core/api/$1"
}

# Replace {placeholders} in a user template. Args: text, then name=value pairs.
fill_template() {
    local text="$1" pair
    shift
    text="${text//\{repository\}/${REPO}}"
    for pair in "$@"; do
        text="${text//\{${pair%%=*}\}/${pair#*=}}"
    done
    printf '%s' "${text}"
}

persistent_notification() {
    jq -n --arg t "$2" --arg m "$3" --arg id "$1" \
        '{title: $t, message: $m, notification_id: $id}' \
        | ha_api services/persistent_notification/create > /dev/null
}

dismiss_notification() {
    jq -n --arg id "$1" '{notification_id: $id}' \
        | ha_api services/persistent_notification/dismiss > /dev/null
}

# Send title/message to every service in notify_services (scripts started without waiting).
notify_devices() {
    local title="$1" message="$2" service code
    for service in $(bashio::config 'notify_services'); do
        if [[ "${service}" != *.* ]]; then
            bashio::log.warning "Ignoring notify service '${service}': use domain.service, e.g. notify.mobile_app_my_phone"
            continue
        fi
        if [ "${service%%.*}" = "script" ]; then
            code="$(jq -n --arg e "${service}" --arg t "${title}" --arg m "${message}" \
                '{entity_id: $e, variables: {title: $t, message: $m}}' \
                | ha_api services/script/turn_on)"
        else
            code="$(jq -n --arg t "${title}" --arg m "${message}" '{title: $t, message: $m}' \
                | ha_api "services/${service%%.*}/${service#*.}")"
        fi
        if [ "${code}" = "200" ]; then
            bashio::log.info "Notice sent via ${service}."
        else
            bashio::log.error "Could not call ${service} (HTTP ${code})."
        fi
    done
}

report_failure() {
    local error="$1" attempts="$2" title message
    title="$(fill_template "$(bashio::config 'failure_title')" "error=${error}" "attempts=${attempts}")"
    message="$(fill_template "$(bashio::config 'failure_message')" "error=${error}" "attempts=${attempts}")"
    persistent_notification "${NOTIF_ID}" "${title}" "${message}"
    jq -n --arg e "${error}" --arg r "${REPO}" --argjson a "${attempts}" \
        '{error: $e, repository: $r, attempts: $a}' \
        | ha_api events/esphome_git_push_failed > /dev/null
    # Device notifications: only once per failure streak.
    if [ -f "${FAILING_FLAG}" ]; then return 0; fi
    touch "${FAILING_FLAG}"
    if bashio::config.true 'notify_on_failure'; then notify_devices "${title}" "${message}"; fi
}

clear_failure() {
    if [ -f "${FAILING_FLAG}" ]; then
        rm -f "${FAILING_FLAG}"
        dismiss_notification "${NOTIF_ID}"
        bashio::log.info "Push working again."
    fi
}

# ---------- GitHub App device flow ----------

save_token() {
    # $1 = JSON answer from GitHub. Expiry times are stored as epoch seconds (0 = never).
    local now
    now="$(date +%s)"
    echo "$1" | jq --argjson now "${now}" '{
        access_token,
        refresh_token: (.refresh_token // ""),
        expires_at: (if .expires_in then $now + .expires_in else 0 end),
        refresh_expires_at: (if .refresh_token_expires_in then $now + .refresh_token_expires_in else 0 end)
    }' > "${TOKEN_FILE}.tmp" && mv "${TOKEN_FILE}.tmp" "${TOKEN_FILE}"
    chmod 600 "${TOKEN_FILE}"
}

device_flow() {
    local answer device_code user_code uri interval expires_in deadline poll error title message
    while true; do
        answer="$(curl -s -m 30 -X POST -H 'Accept: application/json' \
            -d "client_id=${CLIENT_ID}" https://github.com/login/device/code)"
        device_code="$(echo "${answer}" | jq -r '.device_code // empty')"
        if [ -z "${device_code}" ]; then
            bashio::log.error "GitHub did not start the authorization (check github_app_client_id): ${answer}"
            sleep 300
            continue
        fi
        user_code="$(echo "${answer}" | jq -r .user_code)"
        uri="$(echo "${answer}" | jq -r .verification_uri)"
        interval="$(echo "${answer}" | jq -r '.interval // 5')"
        expires_in="$(echo "${answer}" | jq -r '.expires_in // 900')"
        deadline=$(( $(date +%s) + expires_in ))

        title="$(fill_template "$(bashio::config 'approval_title')" "code=${user_code}" "url=${uri}" "install_url=${INSTALL_URL}")"
        message="$(fill_template "$(bashio::config 'approval_message')" "code=${user_code}" "url=${uri}" "install_url=${INSTALL_URL}")"
        bashio::log.info "GitHub authorization needed: open ${uri} and enter the code ${user_code}"
        persistent_notification "${AUTH_NOTIF_ID}" "${title}" "${message}"
        notify_devices "${title}" "${message}"

        while [ "$(date +%s)" -lt "${deadline}" ]; do
            sleep "${interval}"
            poll="$(curl -s -m 30 -X POST -H 'Accept: application/json' \
                -d "client_id=${CLIENT_ID}" -d "device_code=${device_code}" \
                -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
                https://github.com/login/oauth/access_token)"
            if echo "${poll}" | jq -e '.access_token' > /dev/null 2>&1; then
                save_token "${poll}"
                dismiss_notification "${AUTH_NOTIF_ID}"
                bashio::log.info "GitHub access approved."
                return 0
            fi
            error="$(echo "${poll}" | jq -r '.error // "unknown"')"
            case "${error}" in
                authorization_pending) ;;
                slow_down) interval=$((interval + 5)) ;;
                expired_token) break ;;
                access_denied)
                    bashio::log.warning "GitHub access was denied; asking again in 10 minutes."
                    sleep 600
                    break ;;
                *)
                    bashio::log.error "GitHub authorization error: ${error}"
                    sleep 60
                    break ;;
            esac
        done
        bashio::log.info "Authorization code expired; requesting a new one."
    done
}

refresh_token() {
    local refresh answer
    refresh="$(jq -r '.refresh_token' "${TOKEN_FILE}")"
    answer="$(curl -s -m 30 -X POST -H 'Accept: application/json' \
        -d "client_id=${CLIENT_ID}" -d "grant_type=refresh_token" -d "refresh_token=${refresh}" \
        https://github.com/login/oauth/access_token)"
    if echo "${answer}" | jq -e '.access_token' > /dev/null 2>&1; then
        save_token "${answer}"
        return 0
    fi
    bashio::log.warning "Could not renew the GitHub access: $(echo "${answer}" | jq -r '.error // "unknown"')"
    return 1
}

# Prints a valid access token, renewing or re-authorizing when needed.
github_token() {
    local now expires refresh_expires
    now="$(date +%s)"
    if [ -f "${TOKEN_FILE}" ]; then
        expires="$(jq -r '.expires_at' "${TOKEN_FILE}")"
        refresh_expires="$(jq -r '.refresh_expires_at' "${TOKEN_FILE}")"
        if [ "${expires}" -eq 0 ] || [ "${now}" -lt $((expires - 300)) ]; then
            jq -r '.access_token' "${TOKEN_FILE}"
            return 0
        fi
        if [ -n "$(jq -r '.refresh_token' "${TOKEN_FILE}")" ] \
            && { [ "${refresh_expires}" -eq 0 ] || [ "${now}" -lt "${refresh_expires}" ]; } \
            && refresh_token >&2; then
            jq -r '.access_token' "${TOKEN_FILE}"
            return 0
        fi
        rm -f "${TOKEN_FILE}"
    fi
    device_flow >&2
    jq -r '.access_token' "${TOKEN_FILE}"
}

# Runs git against the remote with the right credentials. Args: git arguments.
git_remote() {
    if [ "${AUTH}" = "ssh" ]; then
        timeout 120 git -c safe.directory='*' -c core.fileMode=false "$@"
    else
        local token header
        token="$(github_token)"
        header="Authorization: Basic $(printf 'x-access-token:%s' "${token}" | base64 | tr -d '\n')"
        timeout 120 git -c safe.directory='*' -c core.fileMode=false \
            -c credential.helper= -c "http.https://github.com/.extraHeader=${header}" "$@"
    fi
}

# ---------- SSH (alternative) ----------

setup_ssh() {
    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"
    if [ ! -f "${KEY}" ]; then
        bashio::log.info "Generating the app SSH key (one time only)."
        ssh-keygen -q -t ed25519 -N "" -C "esphome-git-push@homeassistant" -f "${KEY}"
    fi
    # GitHub's published host key (https://api.github.com/meta), pinned.
    echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" > "${KNOWN}"
    export GIT_SSH_COMMAND="ssh -i ${KEY} -o IdentitiesOnly=yes -o UserKnownHostsFile=${KNOWN} -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"
    bashio::log.info "App public key (add it as a Deploy key with write access to the repository):"
    bashio::log.info "$(cat "${KEY}.pub")"
}

# ---------- repository content ----------

secrets_password() {
    local password
    password="$(bashio::config 'secrets_password')"
    if [ "${password}" = "null" ]; then password=""; fi
    printf '%s' "${password}"
}

secrets_fingerprint() {
    { cat "${ESP_DIR}/secrets.yaml"; secrets_password; } | sha256sum | cut -d' ' -f1
}

encrypt_secrets() {
    local source="${ESP_DIR}/secrets.yaml" target="${ESP_DIR}/secrets.yaml.gpg" current saved=""
    if [ ! -f "${source}" ]; then return 0; fi
    if [ -z "$(secrets_password)" ]; then
        bashio::log.warning "secrets_password is empty: secrets.yaml will NOT be pushed."
        return 0
    fi
    # Fingerprint of content + password: changing either one re-encrypts.
    current="$(secrets_fingerprint)"
    if [ -f /data/secrets.sha256 ]; then saved="$(cat /data/secrets.sha256)"; fi
    if [ "${current}" != "${saved}" ] || [ ! -f "${target}" ]; then
        if secrets_password | gpg --batch --yes --quiet --pinentry-mode loopback \
            --passphrase-fd 0 --symmetric --cipher-algo AES256 -o "${target}" "${source}"; then
            echo "${current}" > /data/secrets.sha256
            bashio::log.info "secrets.yaml encrypted to secrets.yaml.gpg."
        else
            bashio::log.error "Failed to encrypt secrets.yaml."
        fi
    fi
}

# Same never-commit list the Device Builder keeps (machine state, keys, build
# output) plus the plain secrets file. Restored or hand-made repositories don't
# have the Builder's block yet, and the safety commit uses "git add -A".
ensure_excludes() {
    local file="${ESP_DIR}/.git/info/exclude" marker="# >>> ESPHome Git Push (managed) >>>"
    mkdir -p "${ESP_DIR}/.git/info"
    if grep -qF "${marker}" "${file}" 2>/dev/null; then return 0; fi
    printf '\n%s\n.esphome/\n.device-builder*\n.receiver_peers.json\n.offloader_pairings.json\n.DS_Store\nsecrets.yaml\nsecrets.yml\n# <<< ESPHome Git Push (managed) <<<\n' \
        "${marker}" >> "${file}"
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
        bashio::log.warning "Option 'repository' is empty: nothing pushed. E.g. USER/esphome-configs"
        return 0
    fi
    local output attempt total=$((RETRIES + 1)) token=""
    for attempt in $(seq 1 "${total}"); do
        if output="$(git_remote -C "${ESP_DIR}" push "${REMOTE}" "HEAD:refs/heads/${BRANCH}" 2>&1)"; then
            bashio::log.info "Pushed to ${REPO} (${BRANCH}): $(git_esp log -1 --format='%h %s')"
            clear_failure
            return 0
        fi
        if [ "${AUTH}" != "ssh" ] && [ -f "${TOKEN_FILE}" ]; then
            token="$(jq -r '.access_token' "${TOKEN_FILE}")"
            output="${output//${token}/***}"
            # A revoked or invalid token: drop it so the next attempt asks for approval again.
            if [[ "${output}" == *"Authentication failed"* || "${output}" == *"Invalid username or token"* ]]; then
                rm -f "${TOKEN_FILE}"
            fi
        fi
        bashio::log.warning "Push attempt ${attempt}/${total} failed: ${output}"
        if [ "${attempt}" -lt "${total}" ]; then sleep "${RETRY_DELAY}"; fi
    done
    bashio::log.error "Push failed after ${total} attempts."
    if [ "${AUTH}" != "ssh" ] && [[ "${output}" == *"Write access to repository not granted"* || "${output}" == *"Repository not found"* ]]; then
        output="The GitHub App has no access to ${REPO}. Install it on this repository: ${INSTALL_URL} (GitHub said: ${output})"
    fi
    report_failure "${output}" "${total}"
}

# Restore only when the folder has no repository and no YAML at all.
restore_if_empty() {
    local tmp=/tmp/esphome_restore count password
    if ! bashio::config.true 'restore_if_empty'; then return 0; fi
    if [ -z "${REPO}" ] || [ -d "${ESP_DIR}/.git" ]; then return 0; fi
    if compgen -G "${ESP_DIR}/*.yaml" > /dev/null || compgen -G "${ESP_DIR}/*.yml" > /dev/null; then
        return 0
    fi
    if [ -z "$(git_remote ls-remote "${REMOTE}" "refs/heads/${BRANCH}" 2>/dev/null)" ]; then
        bashio::log.info "${REPO} has no '${BRANCH}' branch yet: nothing to restore."
        return 0
    fi
    bashio::log.info "${ESP_DIR} is empty: restoring from ${REPO} (${BRANCH})."
    rm -rf "${tmp}"
    if ! git_remote clone -q --branch "${BRANCH}" "${REMOTE}" "${tmp}" > /dev/null 2>&1; then
        bashio::log.error "Restore failed: could not clone ${REPO}."
        persistent_notification "${NOTIF_ID}" "ESPHome Git Push: restore failed" \
            "Could not clone ${REPO} into ${ESP_DIR}. See the app log."
        return 1
    fi
    # The clone authenticated with a header; the remote URL kept in .git/config has no credentials.
    mkdir -p "${ESP_DIR}"
    cp -a "${tmp}/." "${ESP_DIR}/"
    rm -rf "${tmp}"
    count="$(git_esp ls-files | wc -l)"
    password="$(secrets_password)"
    if [ -f "${ESP_DIR}/secrets.yaml.gpg" ] && [ -n "${password}" ]; then
        if printf '%s' "${password}" | gpg --batch --yes --quiet --pinentry-mode loopback \
            --passphrase-fd 0 --decrypt -o "${ESP_DIR}/secrets.yaml" "${ESP_DIR}/secrets.yaml.gpg"; then
            secrets_fingerprint > /data/secrets.sha256
            bashio::log.info "secrets.yaml decrypted."
        else
            bashio::log.error "Could not decrypt secrets.yaml.gpg: wrong secrets_password?"
            persistent_notification "${NOTIF_ID}" "ESPHome Git Push: secrets not restored" \
                "The ESPHome files were restored, but secrets.yaml.gpg could not be decrypted. Check secrets_password."
        fi
    fi
    bashio::log.info "Restored ${count} files from ${REPO}."
    persistent_notification "esphome_git_push_restore" "ESPHome Git Push: configs restored" \
        "${count} files restored from ${REPO} into ${ESP_DIR}, with the full history."
}

cycle() {
    (
        flock 9
        if [ "$1" = "safety" ]; then safety_commit; fi
        push
    ) 9>"${LOCK}"
}

# ---- start ----
if [ "${AUTH}" = "ssh" ]; then
    setup_ssh
elif [ -n "${REPO}" ]; then
    github_token > /dev/null
fi

until [ -d "${ESP_DIR}/.git" ]; do
    restore_if_empty
    if [ -d "${ESP_DIR}/.git" ]; then break; fi
    bashio::log.warning "${ESP_DIR} is not a git repository yet (the Device Builder creates it on save). Waiting..."
    sleep 300
done

ensure_excludes
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
