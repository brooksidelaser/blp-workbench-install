#!/usr/bin/env bash
# BLP Workbench installer: sets up (or updates) an install folder with Docker Compose.
#   curl -fsSLO https://raw.githubusercontent.com/brooksidelaser/blp-workbench-install/main/install.sh
#   bash install.sh
# It asks a few questions, writes compose.yaml and .env, signs in to the image registry if
# needed, then pulls and starts the app. To update later:
#   cd <install folder> && docker compose pull && docker compose up -d
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/brooksidelaser/blp-workbench-install/main"
IMAGE="ghcr.io/brooksidelaser/blp-workbench"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ask() { # ask "Question" default -> answer in $REPLY
  local q=$1 def=${2-}
  if [ -n "$def" ]; then read -rp "$q [$def]: " REPLY </dev/tty; else read -rp "$q: " REPLY </dev/tty; fi
  REPLY=${REPLY:-$def}
}
yes_no() { # yes_no "Question" y|n -> 0 for yes
  ask "$1 (y/n)" "$2"
  [[ $REPLY =~ ^[Yy] ]]
}
fail() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# ---- Rollback: if setup stops before the app is started (an error, no access to the image,
# Ctrl+C), undo what this run did, so running the installer again starts clean. Only what it
# created goes: folders and files it made, and containers it started. A registry sign-in stays
# (the next try then doesn't ask for the token again).
CREATED=()
STARTED=false
FINISHED=false
# Explicit return values: in a trap handler, a bare "return" gives the status from before the
# trap (the failure), which would stop the clean-up early.
remove() {
  if rm -rf "$1" 2>/dev/null; then return 0; fi
  # The app (another user) may have written into the data folder.
  if command -v sudo >/dev/null && sudo rm -rf "$1"; then return 0; fi
  echo "Couldn't remove $1; remove it by hand (sudo rm -rf $1)."
  return 0
}
rollback() {
  local code=$?
  set +e
  if [ "$FINISHED" = true ] || [ ${#CREATED[@]} -eq 0 ]; then return; fi
  say "Setup didn't finish. Undoing what it did, so you can run the installer again."
  if [ "$STARTED" = true ]; then
    (cd "$DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
  fi
  cd /
  for ((i = ${#CREATED[@]} - 1; i >= 0; i--)); do remove "${CREATED[i]}"; done
  echo "Cleaned up. Fix the problem above, then run: bash install.sh"
  exit "$code"
}
trap rollback EXIT
trap 'exit 130' INT TERM

# ---- Requirements
command -v docker >/dev/null || fail "Docker is not installed (https://docs.docker.com/engine/install/)."
docker compose version >/dev/null 2>&1 || fail "The Docker Compose plugin is missing (docker compose)."
command -v curl >/dev/null || fail "curl is not installed."
docker info >/dev/null 2>&1 ||
  fail "This user can't use Docker. Add it to the docker group (then sign in again), or run with sudo."

say "BLP Workbench installer"

# Instance name: the container's name and the install folder's name (several instances can run
# side by side, e.g. blp-workbench and blp-workbench-test).
ROOT_DEFAULT=$HOME
while true; do
  ask "Instance name (letters, digits, - _ . ; no spaces)" blp-workbench
  NAME=$REPLY
  if ! [[ $NAME =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "Use letters, digits, - _ or . only (starting with a letter or digit)."
    continue
  fi
  ask "Folder to install into (the instance goes in a subfolder named $NAME)" "$ROOT_DEFAULT"
  ROOT=${REPLY%/}
  ROOT_DEFAULT=$ROOT
  DIR="$ROOT/$NAME"
  if [ -f "$DIR/.env" ] || [ -f "$DIR/compose.yaml" ]; then
    echo "$DIR already has an install. To update it:"
    echo "  cd $DIR && docker compose pull && docker compose up -d"
    echo "Choose another instance name or folder for a new install."
    continue
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    echo "A container named $NAME already exists (another install). Choose another instance name."
    continue
  fi
  break
done
# Remember the topmost folder this run creates (a rollback removes it with what's inside).
TOP=""
p=$DIR
while [ ! -e "$p" ]; do TOP=$p; p=$(dirname "$p"); done
mkdir -p "$DIR"
[ -n "$TOP" ] && CREATED+=("$TOP")
cd "$DIR"
# In a folder that was already there, only the files written below are removed on a rollback.
own() { [ -z "$TOP" ] && [ ! -e "$DIR/$1" ] && CREATED+=("$DIR/$1"); return 0; }

# ---- Questions
port_free() { ! (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | awk '{print $4}' | grep -qE "[:.]$1\$"; }
PORT_GUESS=7080
while ! port_free "$PORT_GUESS" && [ "$PORT_GUESS" -lt 7180 ]; do PORT_GUESS=$((PORT_GUESS + 1)); done
HOST_GUESS=$(hostname -I 2>/dev/null | awk '{print $1}')
HOST_GUESS=${HOST_GUESS:-$(hostname)}
# HTTPS with Let's Encrypt: needs a domain name pointing at this machine, with ports 80 and 443
# reachable from the internet (the app then gets and renews its certificate by itself).
say "HTTPS"
echo "With a domain name that points at this machine (ports 80 and 443 reachable from the"
echo "internet), the app gets a free Let's Encrypt certificate by itself. Without one, HTTPS"
echo "can be set up later in the app (Admin › Settings › HTTPS)."
DOMAIN=""
TLS_EMAIL=""
while true; do
  ask "Domain name for HTTPS (leave empty to skip)" ""
  DOMAIN=$(printf '%s' "$REPLY" | tr '[:upper:]' '[:lower:]')
  [ -z "$DOMAIN" ] && break
  if ! [[ $DOMAIN =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
    echo "Enter a domain name such as workbench.example.com (not an IP address), or leave it empty."
    continue
  fi
  if ! port_free 80 || ! port_free 443; then
    echo "Ports 80 and 443 must be free on this machine for Let's Encrypt. Leave the domain empty to skip."
    continue
  fi
  break
done
if [ -n "$DOMAIN" ]; then
  PORT=80
  HTTPS_PORT=443
  ask "Email for certificate expiry notices (optional)" ""
  TLS_EMAIL=$REPLY
  URL_GUESS="https://$DOMAIN"
else
  while true; do
    ask "Port on this machine" "$PORT_GUESS"
    PORT=$REPLY
    [[ $PORT =~ ^[0-9]+$ ]] && port_free "$PORT" && break
    echo "Port $PORT is not a number or is already in use."
  done
  # HTTPS (served once the app has a certificate): the next free port from 7443.
  HTTPS_PORT=7443
  while { ! port_free "$HTTPS_PORT" || [ "$HTTPS_PORT" = "$PORT" ]; } && [ "$HTTPS_PORT" -lt 7543 ]; do
    HTTPS_PORT=$((HTTPS_PORT + 1))
  done
  URL_GUESS="http://$HOST_GUESS:$PORT"
fi
ask "Address people will open (used in QR codes and links)" "$URL_GUESS"
PUBLIC_URL=${REPLY%/}
ask "Version to run (a tag such as v0.66b, or latest)" latest
VERSION=$REPLY

# The app runs as this host user and group, which must own the data folder.
if [ "$(id -u)" = 0 ]; then DEF_UID=1000 DEF_GID=1000; else DEF_UID=$(id -u) DEF_GID=$(id -g); fi
say "The app runs as a user and group on this machine that own its data folder."
echo "The default is $([ "$(id -u)" = 0 ] && echo "1000:1000" || echo "you ($(id -un), $DEF_UID:$DEF_GID)")."
while true; do
  ask "User id" "$DEF_UID"
  UID_=$REPLY
  ask "Group id" "$DEF_GID"
  GID_=$REPLY
  [[ $UID_ =~ ^[0-9]+$ && $GID_ =~ ^[0-9]+$ ]] && break
  echo "Ids are numbers (see: id <username>)."
done

# ---- Files
say "Writing compose.yaml and .env in $DIR"
own compose.yaml && own .env.example && own .env && own data
curl -fsSL "$REPO_RAW/compose.yaml" -o compose.yaml || fail "Couldn't download compose.yaml."
curl -fsSL "$REPO_RAW/.env.example" -o .env.example || fail "Couldn't download .env.example."
sed \
  -e "s|^BLP_VERSION=.*|BLP_VERSION=$VERSION|" \
  -e "s|^CONTAINER_NAME=.*|CONTAINER_NAME=$NAME|" \
  -e "s|^APP_PORT=.*|APP_PORT=$PORT|" \
  -e "s|^APP_HTTPS_PORT=.*|APP_HTTPS_PORT=$HTTPS_PORT|" \
  -e "s|^# APP_UID=.*|APP_UID=$UID_|" \
  -e "s|^# APP_GID=.*|APP_GID=$GID_|" \
  -e "s|^PUBLIC_URL=.*|PUBLIC_URL=$PUBLIC_URL|" \
  .env.example >.env
if [ -n "$DOMAIN" ]; then
  sed -i.bak -e "s|^# TLS_DOMAIN=.*|TLS_DOMAIN=$DOMAIN|" -e "s|^# TLS_EMAIL=.*|TLS_EMAIL=$TLS_EMAIL|" .env && rm -f .env.bak
fi
chmod 600 .env
mkdir -p data
# The data folder must belong to the app's user: change its owner if that's someone else.
if [ "$(stat -c %u:%g data)" != "$UID_:$GID_" ]; then
  if [ "$(id -u)" = 0 ]; then
    chown "$UID_:$GID_" data
  elif command -v sudo >/dev/null; then
    echo "Giving $DIR/data to $UID_:$GID_ (sudo may ask for your password)."
    sudo chown "$UID_:$GID_" data || fail "Couldn't change the owner. Run: sudo chown $UID_:$GID_ $DIR/data"
  else
    fail "Change the data folder's owner first: chown $UID_:$GID_ $DIR/data (as root), then run the installer again."
  fi
fi

# ---- Registry sign-in (the image is private)
if ! docker pull -q "$IMAGE:$VERSION" >/dev/null 2>&1; then
  say "Sign in to the image registry (ghcr.io)"
  echo "Use your GitHub username and a classic personal access token with only the"
  echo "read:packages scope (GitHub › Settings › Developer settings › Personal access tokens)."
  ask "GitHub username"
  GH_USER=$REPLY
  read -rsp "Token: " GH_TOKEN </dev/tty
  echo
  echo "$GH_TOKEN" | docker login ghcr.io -u "$GH_USER" --password-stdin >/dev/null ||
    fail "Sign-in failed. Check the username and token (read:packages)."
  unset GH_TOKEN
  docker pull -q "$IMAGE:$VERSION" >/dev/null 2>&1 ||
    fail "Signed in, but $IMAGE:$VERSION can't be downloaded. Check that your GitHub account was given access to it, and that version $VERSION exists."
fi

# ---- Start
say "Starting BLP Workbench (the first start takes a moment)"
docker compose pull || fail "Couldn't download the app's image."
STARTED=true
docker compose up -d || fail "Couldn't start the app."
# Started: from here on nothing is undone (a slow first start isn't a failure).
FINISHED=true
for _ in $(seq 1 60); do
  if curl -fs "http://localhost:$PORT/api/health" >/dev/null 2>&1; then break; fi
  sleep 2
done
if curl -fs "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
  say "Done. Open $PUBLIC_URL"
  echo "A new install asks you to create the administrator account (or restore a backup)."
  if [ -n "$DOMAIN" ]; then
    echo "The app is getting its HTTPS certificate for $DOMAIN, which takes a minute. If"
    echo "https://$DOMAIN doesn't open, check that $DOMAIN points at this machine and that"
    echo "ports 80 and 443 reach it, then see Admin › Settings › HTTPS (or http://$DOMAIN)."
  fi
else
  say "The app hasn't answered yet. Check: docker compose logs (in $DIR)"
fi
echo "Install folder: $DIR (data in $DIR/data)."
echo
echo "To update:"
echo "  cd $DIR && docker compose pull && docker compose up -d"
