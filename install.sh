#!/usr/bin/env bash
# BLP Workbench installer: sets up (or updates) an install folder with Docker Compose.
#   curl -fsSLO https://raw.githubusercontent.com/brooksidelaser/blp-workbench-install/main/install.sh
#   bash install.sh
# It asks a few questions, writes compose.yaml and .env, signs in to the image registry if
# needed, then pulls and starts the app. Run it again in the same folder to update.
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
  # That folder already has this install: update it (below).
  [ -f "$DIR/.env" ] && [ -f "$DIR/compose.yaml" ] && break
  if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    echo "A container named $NAME already exists (another install). Choose another instance name."
    continue
  fi
  break
done
mkdir -p "$DIR"
cd "$DIR"

# ---- Update an existing install (the folder already has one)
if [ -f .env ] && [ -f compose.yaml ]; then
  say "Found an install in $DIR."
  if yes_no "Update it to the version in .env (pull and restart)?" y; then
    ask "Version to run (a tag such as v0.66b, or latest)" "$(sed -n 's/^BLP_VERSION=//p' .env)"
    sed -i.bak "s/^BLP_VERSION=.*/BLP_VERSION=$REPLY/" .env && rm -f .env.bak
    curl -fsSL "$REPO_RAW/compose.yaml" -o compose.yaml
    docker compose pull && docker compose up -d
    say "Updated. The app keeps its data in $DIR/data (a backup is made first when the database changes)."
    exit 0
  fi
  fail "Nothing changed."
fi

# ---- Questions
port_free() { ! (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | awk '{print $4}' | grep -qE "[:.]$1\$"; }
PORT_GUESS=7080
while ! port_free "$PORT_GUESS" && [ "$PORT_GUESS" -lt 7180 ]; do PORT_GUESS=$((PORT_GUESS + 1)); done
HOST_GUESS=$(hostname -I 2>/dev/null | awk '{print $1}')
HOST_GUESS=${HOST_GUESS:-$(hostname)}
while true; do
  ask "Port on this machine" "$PORT_GUESS"
  PORT=$REPLY
  [[ $PORT =~ ^[0-9]+$ ]] && port_free "$PORT" && break
  echo "Port $PORT is not a number or is already in use."
done
ask "Address people will open (used in QR codes and links)" "http://$HOST_GUESS:$PORT"
PUBLIC_URL=${REPLY%/}
ask "Version to run (a tag such as v0.66b, or latest)" latest
VERSION=$REPLY
SEED=false
if yes_no "Add fictional demo data to try things out?" n; then SEED=true; fi

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
curl -fsSL "$REPO_RAW/compose.yaml" -o compose.yaml
curl -fsSL "$REPO_RAW/.env.example" -o .env.example
sed \
  -e "s|^BLP_VERSION=.*|BLP_VERSION=$VERSION|" \
  -e "s|^CONTAINER_NAME=.*|CONTAINER_NAME=$NAME|" \
  -e "s|^APP_PORT=.*|APP_PORT=$PORT|" \
  -e "s|^# APP_UID=.*|APP_UID=$UID_|" \
  -e "s|^# APP_GID=.*|APP_GID=$GID_|" \
  -e "s|^PUBLIC_URL=.*|PUBLIC_URL=$PUBLIC_URL|" \
  .env.example >.env
if [ "$SEED" = true ]; then sed -i.bak 's/^# SEED_DEMO=true/SEED_DEMO=true/' .env && rm -f .env.bak; fi
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
    fail "Sign-in failed. Check the username and token (read:packages), and that you were given access."
  unset GH_TOKEN
fi

# ---- Start
say "Starting BLP Workbench (the first start takes a moment)"
docker compose pull
docker compose up -d
for _ in $(seq 1 60); do
  if curl -fs "http://localhost:$PORT/api/health" >/dev/null 2>&1; then break; fi
  sleep 2
done
if curl -fs "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
  say "Done. Open $PUBLIC_URL"
  echo "A new install asks you to create the administrator account (or restore a backup)."
else
  say "The app hasn't answered yet. Check: docker compose logs (in $DIR)"
fi
echo "Install folder: $DIR (data in $DIR/data). Run this installer again there to update."
