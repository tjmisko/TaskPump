# runners/claude-docker/Dockerfile — the TaskPump dogfood agent image (G0.2).
#
# The concrete instance of the image contract (docs/RUNNERS.md §4.0): the
# runner's entrypoint baked at the default /entrypoint.sh path, the claude CLI
# on PATH, git + jq, and an unprivileged `dev` user for the session. On top of
# the bare contract: mikefarah yq v4 and gawk, because the workspace task CLI
# (libexec/tp-task) runs inside the container and needs them; gh, because the
# phase-drain brief directs agents to open draft PRs.
#
# Build (what TASKPUMP_IMAGE_BUILD pins, context = this directory so the COPY
# below resolves):
#   docker build -t taskpump-agent -f runners/claude-docker/Dockerfile runners/claude-docker
FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl gawk gh git jq procps \
    && rm -rf /var/lib/apt/lists/*

# mikefarah yq v4 — a different tool from Debian's python-yq; the entrypoint's
# goal extraction depends on its --front-matter mode.
ARG YQ_VERSION=v4.47.1
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_$(dpkg --print-architecture)" \
      -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

RUN npm install -g @anthropic-ai/claude-code

# The session user. uid 1000 matches the host operator, so the bind-mounted
# worktrees and ledger are owned by the session user; safe.directory covers
# the root-side git operations that run before the entrypoint drops to `dev`.
# (The base image's `node` user holds uid 1000 — replaced, not renamed, so the
# image carries exactly one purpose-named session user.)
RUN userdel -r node && useradd -m -s /bin/bash -u 1000 dev \
    && git config --system --add safe.directory '*'

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
