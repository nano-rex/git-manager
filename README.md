# git-manager

`git-manager` is a small Bash utility for creating, linking, renaming, listing, verifying, and deleting GitHub repositories from a local folder.

## Script

- `push-github-repo.sh` is the single entry point
- It expects a GitHub personal access token with repo permissions
- It uses the GitHub REST API plus local `git`

## Requirements

- `bash`
- `git`
- `curl`
- `python3`

## Setup

1. Create the config file:

```bash
./push-github-repo.sh init-config
```

2. Edit `~/.config/github-repo-manager/config.env` and set:

- `GITHUB_TOKEN`
- `GITHUB_OWNER`
- `GITHUB_OWNER_TYPE` (`user` or `org`)
- `DEFAULT_VISIBILITY`
- `DEFAULT_BRANCH`

Instead of storing the token in the config, set `GITHUB_TOKEN_FILE` to a
readable token file. The token is used for API and Git authentication but is
never written into the remote URL.

3. Make sure the script is executable:

```bash
chmod +x push-github-repo.sh
```

## Commands

```bash
./push-github-repo.sh list
./push-github-repo.sh create /home/user/github/myapp myapp private
./push-github-repo.sh push /home/user/github/myapp
./push-github-repo.sh rename /home/user/github/myapp myapp-new
./push-github-repo.sh sync-name /home/user/github/myapp
./push-github-repo.sh private myapp
./push-github-repo.sh verify myapp
./push-github-repo.sh delete myapp --yes
```

## Behavior

- `create` ensures the repo exists and points the local directory at the GitHub remote
- `push` ensures the repo exists, sets `origin`, and pushes the current branch
- `rename` renames the remote repo and updates local `origin`
- `sync-name` renames the remote repo to match the local folder name
- `private` changes an existing repository to private
- `verify` prints the repository identity, visibility, and URL
- `delete` asks for confirmation unless `--yes` is passed

## Notes

- The tool initializes a local Git repository if the folder is not already a repo.
- `push` requires at least one commit before it can push.
- If `origin` already exists, the script tries to reuse the owner/repo name from that remote when it can parse it.

## Android Repo Repair Commands

Commands requested during the Graphene Plus/Zero source work:

```bash
cd /home/user/Downloads/codex/github/graphene-plus/android-source
repo init -u https://android.googlesource.com/platform/manifest -b android-12.1.0_r26
mkdir -p .repo/local_manifests
cp /home/user/Downloads/codex/github/graphene-plus/manifests/graphene-plus-android12.1.xml .repo/local_manifests/graphene-plus-android12.1.xml
REPO_JOBS=4 repo sync -c -j4 frameworks/base
```

Retry if the targeted sync stalls:

```bash
cd /home/user/Downloads/codex/github/graphene-plus/android-source
repo sync -c -j1 --force-sync --no-clone-bundle --no-tags frameworks/base
```

## Config File Example

```bash
GITHUB_TOKEN="ghp_your_token_here"
GITHUB_OWNER="your-account"
GITHUB_OWNER_TYPE="user"
DEFAULT_VISIBILITY="public"
DEFAULT_BRANCH="main"
```
