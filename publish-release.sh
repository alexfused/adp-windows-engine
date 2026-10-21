#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Publish the Windows engines on GitHub. It creates a PUBLIC repository and a public release: run it only when
# Alex has said to, and run it with --dry-run first.
#   1. checks, all of them in a dry run too; there is no option to skip one:
#      - gh is logged in as the repository's owner, and that account's id is PUBLISH_GIT_ID, so the commit carries
#        the account's no-reply address (PUBLISH_GIT_EMAIL), never a personal one
#      - release.conf: CONFIRM_SCRIPTS_LICENCE is "yes" and LICENSE is the MIT licence
#      - tools/verify.sh passes (hashes, manifests, sources rebuilt and compared, licences, secrets)
#      - engine guard (tools/engine-guard.py): each engine archive is unpacked and the actual code signature of
#        every Mach-O file and .app is read. Refused: an identifier equal to ADP Monitor's, a file that ADP
#        Monitor's root-helper requirement accepts (read again from ADP Monitor's source, and shown to accept
#        ADP Monitor.app), and any /opt/homebrew, /usr/local, /opt/local, /Users/ or /tmp path in a Mach-O or PE
#        file that tools/path-scan.allow does not explain
#      - no personal path in any file of the repository as it will be pushed, or in any release file
#   2. repository REPO, public: created if missing; the files in PUBLISHED are committed to main as
#      PUBLISH_GIT_NAME <PUBLISH_GIT_EMAIL> and pushed (a new commit only when they changed)
#   3. release TAG at that commit: created as a draft if missing; each file of downloads/release/SHA256SUMS, and
#      SHA256SUMS itself, uploaded unless GitHub already has it with the same SHA-256 (tools/release-plan.py)
#   4. the draft is published, then every URL in the two manifests is checked to answer 200 with the right size
# Rerunnable: an existing repository, commit, release or finished asset is kept. It never overwrites an asset:
# one with other content stops the run before any upload. The only thing it deletes is an asset whose earlier
# upload did not finish (GitHub state not "uploaded"), which it then uploads again.
# Usage: publish-release.sh [--dry-run]
#   --dry-run   every check, then the plan: reads GitHub (gh api, gh repo view, a clone if the repository
#               exists) and changes nothing there; writes only under downloads/publish/
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/release.conf"
DRY=
for a in "$@"; do
    case $a in
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '3,27p' "$0"; exit 0 ;;
        *) echo "unknown option $a" >&2; exit 2 ;;
    esac
done
REL="$ROOT/downloads/release"
PUB="$ROOT/downloads/publish"
STAGE="$PUB/repo"
mkdir -p "$PUB"
OWNER="${REPO%%/*}"
# Files and folders of this folder that go into the public repository (downloads/ never does).
PUBLISHED=(README.md NOTICE.md THIRD-PARTY-LICENSES.md LICENSE RELEASE-NOTES.md components.json release.conf
           publish-release.sh .gitignore tools arm64 x86_64 overlay manifests licenses)
log() { printf '==> %s\n' "$*"; }
# A step that changes GitHub: "creating ..." in a real run, "would: creating ..." in a dry run.
act() { if [[ -n $DRY ]]; then printf '==> would: %s\n' "$*"; else log "$@"; fi; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
run() { if [[ -n $DRY ]]; then printf 'would run:'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }
# git over https with gh's login, without touching the user's git configuration.
g() { git -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"; }
# Commits as the GitHub account's no-reply identity, whatever the environment or git configuration says.
gc() { env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
       git -c user.name="$PUBLISH_GIT_NAME" -c user.email="$PUBLISH_GIT_EMAIL" "$@"; }
stage_files() {   # copy PUBLISHED into $1 (keeping its .git), as it will be committed
    find "$1" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
    for f in "${PUBLISHED[@]}"; do rsync -a --exclude .DS_Store --exclude __pycache__ "$ROOT/$f" "$1/"; done
}

# ------------------------------------------------------------------ 1. checks
for c in gh git python3 shasum curl rsync codesign tar; do command -v "$c" > /dev/null || die "$c is not installed"; done
login=$(gh api user --jq .login 2>/dev/null) || die "gh is not logged in (gh auth login)"
[[ "$login" == "$OWNER" ]] || die "gh is logged in as $login, the repository belongs to $OWNER"
[[ "$login" == "$PUBLISH_GIT_NAME" ]] || die "release.conf: PUBLISH_GIT_NAME $PUBLISH_GIT_NAME is not the gh account $login"
uid=$(gh api user --jq .id)
[[ "$uid" == "$PUBLISH_GIT_ID" && "$PUBLISH_GIT_EMAIL" == "$uid+$login@users.noreply.github.com" ]] \
    || die "release.conf: PUBLISH_GIT_EMAIL $PUBLISH_GIT_EMAIL is not the no-reply address of $login (id $uid)"
log "gh: $login (id $uid); commits as $PUBLISH_GIT_NAME <$PUBLISH_GIT_EMAIL>"
[[ -f "$REL/SHA256SUMS" ]] || die "no downloads/release/SHA256SUMS: run tools/build-assets.sh"
for f in "${PUBLISHED[@]}"; do [[ -e "$ROOT/$f" ]] || die "missing $f"; done

[[ "${CONFIRM_SCRIPTS_LICENCE:-no}" == yes ]] || die "release.conf: CONFIRM_SCRIPTS_LICENCE is not yes (Alex's decision)"
[[ "$(head -1 "$ROOT/LICENSE")" == "MIT License" ]] || die "LICENSE is not the MIT licence"
log "licence: this repository's own files are MIT (LICENSE)"

log "running tools/verify.sh"
"$ROOT/tools/verify.sh" > "$PUB/verify.log" 2>&1 || { grep '^FAIL' "$PUB/verify.log" >&2 || true; die "tools/verify.sh failed: see downloads/publish/verify.log"; }
grep -c '^ok' "$PUB/verify.log" | xargs printf '    %s checks passed (downloads/publish/verify.log)\n'

log "engine guard: actual signatures, root helper requirement, build and personal paths"
archives=()
for f in "$(basename "$ARM64_ARCHIVE")" "$(basename "$X86_64_ARCHIVE")"; do archives+=("$REL/$f"); done
ADP_GUARD_NEED_SOURCE=1 python3 -I "$ROOT/tools/engine-guard.py" archives "$PUB/guard" "${archives[@]}" \
    || die "the engine guard refused a release (reports: downloads/publish/guard/)"

log "repository files: no personal paths"
preview="$PUB/preview"; mkdir -p "$preview"; stage_files "$preview"
python3 -I "$ROOT/tools/engine-guard.py" personal "$preview" > "$PUB/personal.log" \
    || { cat "$PUB/personal.log" >&2; die "a file to be published names a personal path"; }
log "checks passed: $(find "$preview" -type f | wc -l | tr -d ' ') repository files ($(du -sh "$preview" | cut -f1)), $(wc -l < "$REL/SHA256SUMS" | tr -d ' ') release files + SHA256SUMS"

# ------------------------------------------------------------------ 2. repository
if vis=$(gh repo view "$REPO" --json visibility --jq .visibility 2>/dev/null); then
    [[ "$vis" == PUBLIC ]] || die "$REPO exists but is $vis; change it on GitHub yourself if it should be public"
    log "repository $REPO exists (public)"
    repo_exists=1
else
    act "creating public repository $REPO"
    run gh repo create "$REPO" --public --disable-wiki \
        --description "Windows engines (Wine) for ADP Monitor: the builds, their licences and their source"
    repo_exists=$([[ -n $DRY ]] && echo "" || echo 1)
fi

commit=
if [[ -n "$repo_exists" ]]; then
    if [[ -d "$STAGE/.git" ]]; then
        g -C "$STAGE" fetch -q origin
    else
        rm -rf "$STAGE"; mkdir -p "$(dirname "$STAGE")"
        g clone -q "https://github.com/$REPO.git" "$STAGE"
    fi
    # Start from what GitHub has (a commit left over from a failed earlier run is dropped and made again).
    if git -C "$STAGE" rev-parse -q --verify origin/main > /dev/null; then
        git -C "$STAGE" checkout -q -f -B main origin/main
    else
        git -C "$STAGE" symbolic-ref HEAD refs/heads/main
        git -C "$STAGE" update-ref -d refs/heads/main 2> /dev/null || true
    fi
    stage_files "$STAGE"
    git -C "$STAGE" add -A
    changed=
    if git -C "$STAGE" rev-parse -q --verify HEAD > /dev/null && git -C "$STAGE" diff --cached --quiet; then
        log "repository files are up to date"
    else
        changed=1
        act "committing $(git -C "$STAGE" diff --cached --name-only | wc -l | tr -d ' ') changed files as $PUBLISH_GIT_NAME <$PUBLISH_GIT_EMAIL>"
        run gc -C "$STAGE" commit -q -m "Windows engines release $TAG"
        if [[ -z $DRY ]]; then
            who=$(git -C "$STAGE" log -1 --format='%an <%ae>|%cn <%ce>')
            [[ "$who" == "$PUBLISH_GIT_NAME <$PUBLISH_GIT_EMAIL>|$PUBLISH_GIT_NAME <$PUBLISH_GIT_EMAIL>" ]] \
                || die "the new commit is by $who, not the no-reply identity: not pushed"
        fi
    fi
    commit=$(git -C "$STAGE" rev-parse -q --verify HEAD || true)
    remote=$(git -C "$STAGE" rev-parse -q --verify origin/main || true)
    if [[ -n $DRY && -n $changed ]]; then
        log "would push the new commit to main"
    elif [[ -n "$commit" && "$commit" != "$remote" ]]; then
        log "pushing main ($commit)"
        run g -C "$STAGE" push -q -u origin main
    fi
else
    log "would clone the new repository, commit as $PUBLISH_GIT_NAME <$PUBLISH_GIT_EMAIL> and push to main:"
    log "    $(find "$preview" -type f | wc -l | tr -d ' ') files: ${PUBLISHED[*]}"
fi

# ------------------------------------------------------------------ 3. release and assets
rid=
if [[ -n "$repo_exists" ]]; then
    rid=$(gh api "repos/$REPO/releases?per_page=100" --paginate --jq ".[] | select(.tag_name == \"$TAG\") | .id" | head -1)
fi
if [[ -z "$rid" ]]; then
    act "creating draft release $TAG"
    run gh release create "$TAG" -R "$REPO" --draft --title "$RELEASE_TITLE" \
        --notes-file "$ROOT/RELEASE-NOTES.md" --target "${commit:-main}"
    [[ -n $DRY ]] || rid=$(gh api "repos/$REPO/releases?per_page=100" --paginate \
        --jq ".[] | select(.tag_name == \"$TAG\") | .id" | head -1)
    [[ -n $DRY || -n "$rid" ]] || die "release $TAG was not created"
else
    log "release $TAG exists (id $rid)"
fi

assets="$PUB/assets.json"
if [[ -n "$rid" ]]; then gh api "repos/$REPO/releases/$rid/assets?per_page=100" --paginate --slurp > "$assets"
else echo "[]" > "$assets"; fi
plan=$(python3 -I "$ROOT/tools/release-plan.py" "$REL" "$assets") || {
    echo "$plan" | grep '^conflict' >&2
    die "GitHub already has a different file under the same name: nothing uploaded"
}
echo "$plan" | awk -F'\t' '{n[$1]++} END {for (k in n) printf "    %s: %d\n", k, n[k]}'
up_bytes=0
while IFS=$'\t' read -r action name id; do
    case $action in
        replace)
            act "re-uploading $name (earlier upload did not finish)"
            run gh api -X DELETE "repos/$REPO/releases/assets/$id"
            run gh release upload "$TAG" "$REL/$name" -R "$REPO"
            up_bytes=$((up_bytes + $(stat -f %z "$REL/$name"))) ;;
        upload)
            act "uploading $name ($(du -h "$REL/$name" | cut -f1))"
            run gh release upload "$TAG" "$REL/$name" -R "$REPO"
            up_bytes=$((up_bytes + $(stat -f %z "$REL/$name"))) ;;
    esac
done <<< "$plan"
log "$( [[ -n $DRY ]] && echo "would upload" || echo "uploaded"): $up_bytes bytes"

if [[ -z $DRY ]]; then
    gh api "repos/$REPO/releases/$rid/assets?per_page=100" --paginate --slurp > "$assets"
    left=$(python3 -I "$ROOT/tools/release-plan.py" "$REL" "$assets" | grep -v -E '^(skip|extra)' || true)
    [[ -z "$left" ]] || { echo "$left" >&2; die "some files are still not on GitHub with the right SHA-256 (listed above)"; }
    log "all $(( $(wc -l < "$REL/SHA256SUMS") + 1 )) files are on GitHub with matching SHA-256"
fi

# ------------------------------------------------------------------ 4. publish and check
draft=true
[[ -n "$rid" ]] && draft=$(gh api "repos/$REPO/releases/$rid" --jq .draft)
if [[ "$draft" == true ]]; then
    act "publishing release $TAG"
    run gh release edit "$TAG" -R "$REPO" --draft=false
else
    log "release $TAG is already published"
fi
if [[ -n $DRY ]]; then
    log "after publishing, it would check that each url in manifests/ answers 200 with the right size"
    log "dry run: nothing was changed on GitHub"
    exit 0
fi

log "checking the public download URLs"
bad=0
while IFS=$'\t' read -r url bytes; do
    read -r got len < <(curl -sIL -o /dev/null -w '%{http_code} %header{content-length}\n' "$url" || echo "000 0")
    if [[ "$got" == 200 && "$len" == "$bytes" ]]; then :; else echo "  $url: HTTP $got, $len bytes (want $bytes)"; bad=1; fi
done < <(python3 -I -c '
import json, sys
for p in sys.argv[1:]:
    m = json.load(open(p))
    for a in [m["archive"], m["notices"]] + m["sourceFiles"]:
        print(a["url"] + "\t" + str(a["bytes"]))
' "$ROOT/manifests/$ARM64_ENGINE.manifest.json" "$ROOT/manifests/$X86_64_ENGINE.manifest.json")
curl -sfL "$BASE_URL/SHA256SUMS" | cmp -s - "$REL/SHA256SUMS" || { echo "  SHA256SUMS on GitHub differs from the local one"; bad=1; }
[[ $bad == 0 ]] || die "some public URLs do not serve the expected files (listed above)"
log "done: https://github.com/$REPO/releases/tag/$TAG"
