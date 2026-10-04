# BLP Workbench installer

Sets up BLP Workbench on a machine with Docker.

## Before installing

### 1. Request early access

BLP Workbench is in early access. Sign in to GitHub (no account yet? Create one for free at
[github.com/signup](https://github.com/signup)), then
[open an early access request](https://github.com/brooksidelaser/blp-workbench-install/issues/new?template=early-access.yml)
to Brookside Laser. Access is granted to the GitHub account that opens the request, and you'll
get a reply on the request when your account can download the BLP Workbench image.

### 2. Create a GitHub token for downloading the image

The installer signs in to the image registry (ghcr.io) with a GitHub token that can only read
packages:

1. Sign in to GitHub and open **Settings** (your profile picture › Settings).
2. Open **Developer settings** (at the bottom of the left menu) › **Personal access tokens** ›
   **Tokens (classic)**.
3. Choose **Generate new token** › **Generate new token (classic)**.
4. Give it a name (e.g. "BLP Workbench") and an expiration date.
5. Tick only the **read:packages** scope.
6. Choose **Generate token**, then copy the token: GitHub shows it only once. Keep it somewhere
   safe; the installer asks for it, along with your GitHub username.

### 3. Requirements

- Linux (or another system that runs Docker) with Docker and the Compose plugin
  (`docker compose version` should work). See
  [docs.docker.com/engine/install](https://docs.docker.com/engine/install/).
- A user that can run Docker (a member of the `docker` group), and `curl`.

## Install

```sh
curl -fsSLO https://raw.githubusercontent.com/brooksidelaser/blp-workbench-install/main/install.sh
bash install.sh
```

The installer asks for:

- an instance name (default `blp-workbench`; use another, e.g. `blp-workbench-test`, to run a
  second instance on the same machine) and the folder to install into: the instance goes in a
  subfolder with its name (default `~/blp-workbench`);
- the port and the address people will open;
- the version (a tag such as `v0.66b`, or `latest`);
- whether to add demo data (fictional records for trying things out);
- the user and group ids the app runs as (default: you), which own its data folder;
- your GitHub username and token, if the machine isn't signed in to ghcr.io yet.

It then writes `compose.yaml` and `.env`, and starts the app. Open the address it prints. A new
install asks you to create the administrator account, or to restore a backup instead, and then
walks you through the setup.

## Update

Run the installer again with the same instance name and folder: it pulls the version set in `.env` (you can
change it) and restarts. Your data stays in `data/`; the app backs it up before updating its
database.

## By hand

The same files are in this repository: copy `compose.yaml` and `.env.example` (as `.env`) into a
folder, edit `.env`, sign in once with
`echo <token> | docker login ghcr.io -u <GitHub username> --password-stdin`, then run
`docker compose pull && docker compose up -d`.

## Feedback

[Open a feedback issue](https://github.com/brooksidelaser/blp-workbench-install/issues/new?template=feedback.yml)
for questions, problems and ideas, with the version shown at the bottom of the app's pages.
Issues are public, so leave out customer names, prices, passwords and other private details.
