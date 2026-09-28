#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="${0##*/}"
CONFIG_FILE="${GITHUB_REPO_CONFIG:-$HOME/.config/github-repo-manager/config.env}"
DEFAULT_BRANCH_FALLBACK="main"
ASSUME_YES=0
ASKPASS_FILE=""

cleanup() {
  if [[ -n "${ASKPASS_FILE}" && -f "${ASKPASS_FILE}" ]]; then
    rm -f "${ASKPASS_FILE}"
  fi
}
trap cleanup EXIT

err() {
  printf '%s\n' "$*" >&2
}

die() {
  err "$*"
  exit 1
}

usage() {
  cat <<USAGE
GitHub repo manager

Config:
  init-config [path]      Write a config template and exit.
  Config file defaults to ~/.config/github-repo-manager/config.env

Commands:
  list                    List repos for the configured owner.
  create <dir> [repo] [visibility]
                          Create a repo and point a local folder at it.
  push <dir> [repo] [branch] [visibility]
                          Ensure repo exists, point the local folder at it, and push.
  rename <dir> <new-repo>  Rename the GitHub repo and sync local origin.
  sync-name <dir>         Rename the GitHub repo to match the local folder name.
  private <repo>           Set an existing repository to private.
  verify <repo>            Show repository name, visibility, and URL.
  delete <repo> [--yes]    Delete a GitHub repo.

Examples:
  ${SCRIPT_NAME} init-config
  ${SCRIPT_NAME} list
  ${SCRIPT_NAME} create /home/user/github/myapp myapp private
  ${SCRIPT_NAME} push /home/user/github/myapp
  ${SCRIPT_NAME} rename /home/user/github/myapp myapp-new
  ${SCRIPT_NAME} sync-name /home/user/github/myapp
  ${SCRIPT_NAME} private myapp
  ${SCRIPT_NAME} verify myapp
  ${SCRIPT_NAME} delete myapp --yes
USAGE
}

write_config_template() {
  local path="${1:-$CONFIG_FILE}"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<'CFG'
# GitHub repo manager config
# Fill these values in before using the script.

# Personal access token with repo permissions.
GITHUB_TOKEN=""

# Optional token file. Used when GITHUB_TOKEN is empty.
# GITHUB_TOKEN_FILE="/home/user/Downloads/codex/github_token.txt"

# GitHub account or organization name.
GITHUB_OWNER="nano-rex"

# user = /user/repos API, org = /orgs/<org>/repos API.
GITHUB_OWNER_TYPE="user"

# Default visibility for new repositories.
DEFAULT_VISIBILITY="public"

# Default branch name used when initializing a local git repo.
DEFAULT_BRANCH="main"
CFG
  chmod 600 "$path" 2>/dev/null || true
  printf 'Wrote config template to %s\n' "$path"
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Missing config: $CONFIG_FILE. Run '$SCRIPT_NAME init-config'."
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  if [[ -z "${GITHUB_TOKEN:-}" && -n "${GITHUB_TOKEN_FILE:-}" ]]; then
    [[ -r "$GITHUB_TOKEN_FILE" ]] || die "Token file is not readable: $GITHUB_TOKEN_FILE"
    GITHUB_TOKEN="$(tr -d '\r\n' < "$GITHUB_TOKEN_FILE")"
  fi
  : "${GITHUB_TOKEN:?GITHUB_TOKEN or GITHUB_TOKEN_FILE is required in $CONFIG_FILE}"
  : "${GITHUB_OWNER:?GITHUB_OWNER is required in $CONFIG_FILE}"
  GITHUB_OWNER_TYPE="${GITHUB_OWNER_TYPE:-user}"
  DEFAULT_VISIBILITY="${DEFAULT_VISIBILITY:-public}"
  DEFAULT_BRANCH="${DEFAULT_BRANCH:-$DEFAULT_BRANCH_FALLBACK}"
}

require_commands() {
  local cmd

  for cmd in git curl python3; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
  done
}

make_askpass() {
  ASKPASS_FILE="$(mktemp)"
  python3 - "$ASKPASS_FILE" "$GITHUB_TOKEN" <<'PY'
import pathlib
import shlex
import sys

path = pathlib.Path(sys.argv[1])
token = sys.argv[2]
quoted = shlex.quote(token)
path.write_text(
    "#!/usr/bin/env bash\n"
    "case \"$1\" in\n"
    "  *Username*) printf '%s\\n' 'x-access-token' ;;\n"
    f"  *) printf '%s\\n' {quoted} ;;\n"
    "esac\n",
    encoding="utf-8",
)
path.chmod(0o700)
PY
}

git_env() {
  make_askpass
  export GIT_ASKPASS="$ASKPASS_FILE"
  export GIT_TERMINAL_PROMPT=0
}

gh_api() {
  local method="$1"
  local url="$2"
  local data="${3:-}"

  local args=(
    -fsSL
    -H "Authorization: Bearer ${GITHUB_TOKEN}"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )

  if [[ "$method" != "GET" ]]; then
    args+=( -X "$method" -H "Content-Type: application/json" -d "$data" )
  fi

  curl "${args[@]}" "$url"
}

repo_api_base() {
  printf 'https://api.github.com/repos/%s' "$GITHUB_OWNER"
}

repo_api_url() {
  printf '%s/%s\n' "$(repo_api_base)" "$1"
}

list_api_url() {
  if [[ "$GITHUB_OWNER_TYPE" == "org" ]]; then
    printf 'https://api.github.com/orgs/%s/repos?per_page=100&type=all&sort=updated&page=%s' "$GITHUB_OWNER" "$1"
  else
    printf 'https://api.github.com/user/repos?per_page=100&affiliation=owner&sort=updated&page=%s' "$1"
  fi
}

repo_exists() {
  local repo_name="$1"
  gh_api GET "$(repo_api_base)/${repo_name}" >/dev/null 2>&1
}

create_repo() {
  local repo_name="$1"
  local visibility="${2:-$DEFAULT_VISIBILITY}"
  local endpoint data

  if [[ "$GITHUB_OWNER_TYPE" == "org" ]]; then
    endpoint="https://api.github.com/orgs/${GITHUB_OWNER}/repos"
  else
    endpoint="https://api.github.com/user/repos"
  fi

  data="$(python3 - "$repo_name" "$visibility" <<'PY'
import json
import sys

repo_name = sys.argv[1]
visibility = sys.argv[2]
print(json.dumps({
    "name": repo_name,
    "private": visibility == "private",
    "auto_init": False,
}))
PY
)"

  gh_api POST "$endpoint" "$data" >/dev/null
  printf 'Created %s/%s (%s)\n' "$GITHUB_OWNER" "$repo_name" "$visibility"
}

ensure_repo_exists() {
  local repo_name="$1"
  local visibility="${2:-$DEFAULT_VISIBILITY}"

  if repo_exists "$repo_name"; then
    return 0
  fi

  create_repo "$repo_name" "$visibility"
}

ensure_local_git_repo() {
  local dir="$1"
  local branch="${2:-$DEFAULT_BRANCH}"

  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$dir" init -b "$branch" >/dev/null
  fi
}

set_origin_url() {
  local dir="$1"
  local owner="$2"
  local repo_name="$3"
  local url="https://github.com/${owner}/${repo_name}.git"

  if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    git -C "$dir" remote set-url origin "$url"
  else
    git -C "$dir" remote add origin "$url"
  fi
}

current_branch() {
  local dir="$1"
  local branch

  branch="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    branch="$DEFAULT_BRANCH"
  fi
  printf '%s\n' "$branch"
}

repo_name_from_dir() {
  local dir="$1"
  basename "${dir%/}"
}

repo_from_origin() {
  local origin="$1"
  python3 - "$origin" <<'PY'
import re
import sys

origin = sys.argv[1]
patterns = [
    r'^git@github\.com:(?P<owner>[^/]+)/(?P<repo>[^/]+?)(?:\.git)?$',
    r'^https?://(?:[^@/]+@)?github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+?)(?:\.git)?$',
]
for pattern in patterns:
    match = re.match(pattern, origin)
    if match:
        print(match.group('owner'))
        print(match.group('repo'))
        break
else:
    sys.exit(1)
PY
}

local_repo_owner_and_name() {
  local dir="$1"
  local origin owner repo_name
  local -a parsed

  if origin="$(git -C "$dir" remote get-url origin 2>/dev/null)"; then
    if mapfile -t parsed < <(repo_from_origin "$origin"); then
      owner="${parsed[0]}"
      repo_name="${parsed[1]}"
      printf '%s\t%s\n' "$owner" "$repo_name"
      return 0
    fi
  fi

  printf '%s\t%s\n' "$GITHUB_OWNER" "$(repo_name_from_dir "$dir")"
}

push_local_repo() {
  local dir="$1"
  local repo_name="${2:-}"
  local branch="${3:-}"
  local visibility="${4:-$DEFAULT_VISIBILITY}"
  local owner="$GITHUB_OWNER"

  [[ -d "$dir" ]] || die "Local folder not found: $dir"
  ensure_local_git_repo "$dir" "$DEFAULT_BRANCH"

  if [[ -z "$repo_name" ]]; then
    repo_name="$(local_repo_owner_and_name "$dir" | cut -f2)"
  fi
  if [[ -z "$branch" ]]; then
    branch="$(current_branch "$dir")"
  fi

  ensure_repo_exists "$repo_name" "$visibility"
  set_origin_url "$dir" "$owner" "$repo_name"

  if ! git -C "$dir" rev-parse --verify HEAD >/dev/null 2>&1; then
    die "${dir} has no commits yet. Create at least one commit before pushing."
  fi

  git_env
  git -C "$dir" push -u origin "$branch"
}

create_local_repo() {
  local dir="$1"
  local repo_name="${2:-}"
  local visibility="${3:-$DEFAULT_VISIBILITY}"
  local owner="$GITHUB_OWNER"

  [[ -d "$dir" ]] || die "Local folder not found: $dir"
  ensure_local_git_repo "$dir" "$DEFAULT_BRANCH"

  if [[ -z "$repo_name" ]]; then
    repo_name="$(repo_name_from_dir "$dir")"
  fi

  ensure_repo_exists "$repo_name" "$visibility"
  set_origin_url "$dir" "$owner" "$repo_name"
  printf 'Pointed %s at %s/%s\n' "$dir" "$owner" "$repo_name"
}

rename_remote_repo() {
  local dir="$1"
  local new_repo_name="$2"
  local owner old_repo
  local origin
  local -a parsed

  [[ -d "$dir" ]] || die "Local folder not found: $dir"
  ensure_local_git_repo "$dir" "$DEFAULT_BRANCH"

  if origin="$(git -C "$dir" remote get-url origin 2>/dev/null)"; then
    if mapfile -t parsed < <(repo_from_origin "$origin"); then
      owner="${parsed[0]}"
      old_repo="${parsed[1]}"
    else
      owner="$GITHUB_OWNER"
      old_repo="$(repo_name_from_dir "$dir")"
    fi
  else
    owner="$GITHUB_OWNER"
    old_repo="$(repo_name_from_dir "$dir")"
  fi

  if [[ "$old_repo" == "$new_repo_name" ]]; then
    printf 'Repo already named %s\n' "$new_repo_name"
    set_origin_url "$dir" "$owner" "$new_repo_name"
    return 0
  fi

  local data
  data="$(python3 - "$new_repo_name" <<'PY'
import json
import sys

print(json.dumps({"name": sys.argv[1]}))
PY
)"

  gh_api PATCH "$(repo_api_base)/${old_repo}" "$data" >/dev/null
  set_origin_url "$dir" "$owner" "$new_repo_name"
  printf 'Renamed %s/%s -> %s/%s\n' "$owner" "$old_repo" "$owner" "$new_repo_name"
}

set_private_repo() {
  local repo_name="$1"

  gh_api PATCH "$(repo_api_url "$repo_name")" '{"private":true}' >/dev/null
  printf 'Set %s/%s to private\n' "$GITHUB_OWNER" "$repo_name"
}

verify_repo() {
  local repo_name="$1"

  gh_api GET "$(repo_api_url "$repo_name")" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
for key in ("full_name", "private", "html_url"):
    print(f"{key} {json.dumps(data[key])}")
'
}

sync_name_from_dir() {
  local dir="$1"
  rename_remote_repo "$dir" "$(repo_name_from_dir "$dir")"
}

delete_repo() {
  local repo_name="$1"

  if [[ "$ASSUME_YES" != "1" ]]; then
    printf 'Type %s to confirm deletion: ' "$repo_name" >&2
    local confirm
    read -r confirm
    [[ "$confirm" == "$repo_name" ]] || die "Deletion cancelled"
  fi

  gh_api DELETE "$(repo_api_base)/${repo_name}" >/dev/null
  printf 'Deleted %s/%s\n' "$GITHUB_OWNER" "$repo_name"
}

list_repos() {
  local page=1
  local total=0
  local url count tmp

  printf '%-32s %-8s %-16s %s\n' "REPO" "VIS" "BRANCH" "URL"

  while :; do
    url="$(list_api_url "$page")"
    tmp="$(mktemp)"
    gh_api GET "$url" >"$tmp"

    count="$(python3 - "$tmp" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    data = json.load(handle)
print(len(data))
PY
)"

    if [[ "$count" == "0" ]]; then
      rm -f "$tmp"
      break
    fi

    python3 - "$tmp" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    data = json.load(handle)

for repo in data:
    visibility = 'private' if repo.get('private') else 'public'
    print(f"{repo.get('name', '')}\t{visibility}\t{repo.get('default_branch', '')}\t{repo.get('html_url', '')}")
PY

    total=$((total + count))
    rm -f "$tmp"
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done

  printf 'Total: %s\n' "$total"
}

main() {
  local cmd="${1:-}"

  case "$cmd" in
    init-config)
      write_config_template "${2:-$CONFIG_FILE}"
      ;;
    list)
      require_commands
      load_config
      list_repos
      ;;
    create)
      require_commands
      load_config
      [[ $# -ge 2 ]] || die "Usage: $SCRIPT_NAME create <dir> [repo] [visibility]"
      create_local_repo "${2}" "${3:-}" "${4:-$DEFAULT_VISIBILITY}"
      ;;
    push)
      require_commands
      load_config
      [[ $# -ge 2 ]] || die "Usage: $SCRIPT_NAME push <dir> [repo] [branch] [visibility]"
      push_local_repo "${2}" "${3:-}" "${4:-}" "${5:-$DEFAULT_VISIBILITY}"
      ;;
    rename)
      require_commands
      load_config
      [[ $# -ge 3 ]] || die "Usage: $SCRIPT_NAME rename <dir> <new-repo>"
      rename_remote_repo "${2}" "${3}"
      ;;
    sync-name)
      require_commands
      load_config
      [[ $# -ge 2 ]] || die "Usage: $SCRIPT_NAME sync-name <dir>"
      sync_name_from_dir "${2}"
      ;;
    private)
      require_commands
      load_config
      [[ $# -eq 2 ]] || die "Usage: $SCRIPT_NAME private <repo>"
      set_private_repo "${2}"
      ;;
    verify)
      require_commands
      load_config
      [[ $# -eq 2 ]] || die "Usage: $SCRIPT_NAME verify <repo>"
      verify_repo "${2}"
      ;;
    delete)
      require_commands
      load_config
      [[ $# -ge 2 ]] || die "Usage: $SCRIPT_NAME delete <repo> [--yes]"
      if [[ "${3:-}" == "--yes" ]]; then
        ASSUME_YES=1
      fi
      delete_repo "${2}"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      die "Unknown command: $cmd"
      ;;
  esac
}

main "$@"
