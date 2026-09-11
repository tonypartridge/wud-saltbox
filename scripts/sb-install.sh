#!/bin/sh
# WUD command trigger: run host `sb install <tag>` when an image update
# is found, but only between SB_INSTALL_HOUR_START and SB_INSTALL_HOUR_END
# (default 01:00–03:00, host TZ). Serialized with flock so Ansible is not
# run in parallel.
#
# Sandbox role dirs are named tofa, watchstate, … but the CLI tag is
# sandbox-tofa, sandbox-watchstate. Core roles use the directory name as-is.
# Ansible must run as the Saltbox user (default media), not root.
set -eu

log() {
  echo "sb-install: $*"
}

name="${name:-}"
name="${name#/}"
user="${SB_INSTALL_USER:-media}"

if [ "${SB_INSTALL_ENABLED:-true}" != "true" ]; then
  log "disabled (SB_INSTALL_ENABLED=${SB_INSTALL_ENABLED-})"
  exit 0
fi

if [ -z "$name" ]; then
  log "no container name in environment; skip"
  exit 0
fi

case "$name" in
  *[!a-zA-Z0-9_.-]*)
    log "refuse unsafe container name: $name"
    exit 0
    ;;
esac

case "$user" in
  *[!a-zA-Z0-9_.-]*)
    log "refuse unsafe SB_INSTALL_USER: $user"
    exit 1
    ;;
esac

hour=$(date +%H | awk '{ print $1 + 0 }')
start="${SB_INSTALL_HOUR_START:-1}"
end="${SB_INSTALL_HOUR_END:-3}"
if [ "$hour" -lt "$start" ] || [ "$hour" -ge "$end" ]; then
  log "$name: outside ${start}:00–${end}:00 window (hour=${hour}); skip"
  exit 0
fi

skip="${SB_INSTALL_SKIP:-wud,arbor,arbor-vnc,arbour-fetcher,arbor-fetcher}"
oldifs=$IFS
IFS=,
for item in $skip; do
  item=$(echo "$item" | tr -d ' ')
  if [ "$item" = "$name" ]; then
    log "$name: on skip list"
    IFS=$oldifs
    exit 0
  fi
done
IFS=$oldifs

if ! command -v nsenter >/dev/null 2>&1; then
  log "nsenter missing; rebuild the image from this repo's Dockerfile"
  exit 1
fi

if [ ! -d /proc/1/ns ]; then
  log "host PID namespace not visible; compose must set pid: host"
  exit 1
fi

host_sh() {
  nsenter --target 1 --mount --uts --ipc --net -- /bin/sh -c "$1"
}

tag=""
if host_sh "test -d /srv/git/saltbox/roles/${name}"; then
  tag="$name"
elif host_sh "test -d /opt/sandbox/roles/${name}"; then
  tag="sandbox-${name}"
else
  log "$name: no Saltbox/sandbox role; skip (custom compose)"
  exit 0
fi

log "$name: sb install ${tag} as ${user} (serialized)"
# flock on the host so overlapping simple-mode triggers queue.
# runuser: Saltbox playbooks must not run as root.
host_sh "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin flock /tmp/wud-sb-install.lock runuser -u ${user} -- /usr/local/bin/sb install ${tag}"
log "$name: sb install ${tag} finished"
