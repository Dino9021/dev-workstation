#!/bin/sh
# Refresh the GitNexus index after every commit - macOS.
#
# Master copy: graph-servers/post-commit.sh in the dev-workstation repo
# Installed to: <repo-root>/.git/hooks/post-commit  (by install.sh)
#
# The macOS sibling of graph-servers/post-commit (which calls `powershell`, Windows
# only). It calls the sh refresher in ~/.claude/hooks. The refresh detaches itself, so
# `git commit` returns at once, and this hook always exits 0.
#
# code-review-graph is deliberately NOT refreshed here - its watch daemon already
# indexed these files seconds after each save.
#
# NOTE: .git/hooks/ is NOT version-controlled. A fresh clone will not have this
# hook - re-install it there.
repo="$(git rev-parse --show-toplevel)"
hook_sh="$HOME/.claude/hooks/graph-refresh.sh"

if [ ! -f "$hook_sh" ]; then
  echo "post-commit: graph-refresh.sh not installed, skipping GitNexus refresh" >&2
  exit 0
fi

/bin/sh "$hook_sh" --which gitnexus --repo "$repo" --detach >/dev/null 2>&1

exit 0
