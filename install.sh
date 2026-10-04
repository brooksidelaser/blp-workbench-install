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

ask "Install folder" "$HOME/blp-workbench"
DIR=$REPLY
mkdir -p "$DIR"
cd "$DIR"

# ---- Update an existing install
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
HOST_GUESS=$(hostname -I 2>/dev/null | awk '{print $1}')
HOST_GUESS=${HOST_GUESS:-$(hostname)}
ask "Port on this machine" 7080
PORT=$REPLY
ask "Address people will open (used in QR codes and links)" "http://$HOST_GUESS:$PORT"
PUBLIC_URL=${REPLY%/}
ask "Version to run (a tag such as v0.66b, or latest)" latest
VERSION=$REPLY
SEED=false
if yes_no "Add fictional demo data to try things out?" n; then SEED=true; fi

UID_=$(id -u)
GID_=$(id -g)
if [ "$UID_" = 0 ]; then
  say "Running as root: the app will use user 1000:1000 for its data folder."
  UID_=1000
  GID_=1000
fi

# ---- Files
say "Writing compose.yaml and .env in $DIR"
curl -fsSL "$REPO_RAW/compose.yaml" -o compose.yaml
curl -fsSL "$REPO_RAW/.env.example" -o .env.example
sed \
  -e "s|^BLP_VERSION=.*|BLP_VERSION=$VERSION|" \
  -e "s|^APP_PORT=.*|APP_PORT=$PORT|" \
  -e "s|^# APP_UID=.*|APP_UID=$UID_|" \
  -e "s|^# APP_GID=.*|APP_GID=$GID_|" \
  -e "s|^PUBLIC_URL=.*|PUBLIC_URL=$PUBLIC_URL|" \
  .env.example >.env
if [ "$SEED" = true ]; then sed -i.bak 's/^# SEED_DEMO=true/SEED_DEMO=true/' .env && rm -f .env.bak; fi
chmod 600 .env
mkdir -p data
if [ "$(id -u)" = 0 ]; then chown "$UID_:$GID_" data; fi

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
