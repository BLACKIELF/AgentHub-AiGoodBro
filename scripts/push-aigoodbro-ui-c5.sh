#!/bin/sh
# Push the already-built UI commit 548e88a onto origin/codex/aigoodbro-ui-0911v2.
# Objects live outside the locked worktree .git (sandbox cannot write objects there).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
COMMIT=548e88af799997fbde84693ab4a09e90701fc927
PARENT=724a1698272ef4f30cc1d346b14f9f14af4a0a6e
COMMON=$(git -C "$ROOT" rev-parse --git-common-dir)
OBJ="$ROOT/.local-artifacts/git-objects-548e88a"
if [ ! -d "$OBJ" ]; then
  echo "missing $OBJ" >&2
  exit 1
fi
export GIT_OBJECT_DIRECTORY="$OBJ"
export GIT_ALTERNATE_OBJECT_DIRECTORIES="$COMMON/objects"
git -C "$ROOT" rev-parse --verify "${COMMIT}^{commit}" >/dev/null
git -C "$ROOT" merge-base --is-ancestor "$PARENT" "$COMMIT"
# zsh-safe: ${COMMIT} not $COMMIT:refs
git -C "$ROOT" push origin "${COMMIT}:refs/heads/codex/aigoodbro-ui-0911v2"
git -C "$ROOT" ls-remote origin refs/heads/codex/aigoodbro-ui-0911v2
