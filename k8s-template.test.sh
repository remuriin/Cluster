#!/bin/bash
# Checks k8s-new-project, on any machine with bash and git:
#   bash k8s-template.test.sh
# (k8s-launch, which runs it, is checked in k8s-launch.test.sh.)
set -u
here=$(cd "$(dirname "$0")" && pwd)
fails=0
ok() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false
new() { bash "$here/k8s-new-project" "$@" >"$tmp/out" 2>&1; }
T1=main-0123456789abcdef0123456789abcdef01234567-1791975494
for d in full web own bad k fleet; do git init -q -b main "$tmp/$d"; done
rm -rf "$tmp/bad/.git"

# --- repo: the project's own files ---
ok "a project with a backend gets its workflow and both Dockerfiles" 'new repo "$tmp/full" my-app api && [[ -e "$tmp/full/frontend/Dockerfile" && -e "$tmp/full/frontend/nginx.conf" && -e "$tmp/full/backend/Dockerfile" && -e "$tmp/full/.github/workflows/image.yml" ]]'
ok "... and no cluster files any more: those live in Fleet" '[[ ! -e "$tmp/full/k8s" && ! -e "$tmp/full/nginx-site.conf" ]]'
ok "the workflow builds both images with the tag Flux sorts by, and deploys nothing itself" 'grep -q "my-app-web:main-\${{ github.sha }}-\${{ steps.ts.outputs.ts }}" "$tmp/full/.github/workflows/image.yml" && grep -q "my-app-api:main-" "$tmp/full/.github/workflows/image.yml" && ! grep -q "^  deploy:" "$tmp/full/.github/workflows/image.yml"'
ok "a web-only project gets no backend files or lines" 'new repo "$tmp/web" my-site && [[ ! -e "$tmp/web/backend" ]] && ! grep -q "api" "$tmp/web/.github/workflows/image.yml"'
ok "nothing is left unfilled" '! grep -rqE "PROJECT|REPO|# api:" "$tmp/full" "$tmp/web" --exclude-dir=.git'
before=$(cd "$tmp/full" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 cat | cksum)
ok "a second run keeps every file and changes nothing" 'new repo "$tmp/full" my-app api && ! grep -q "^wrote" "$tmp/out" && [[ "$(cd "$tmp/full" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 cat | cksum)" == "$before" ]]'
mkdir -p "$tmp/own/frontend"; printf 'FROM node:24\nUSER node\n' > "$tmp/own/frontend/Dockerfile"; owndocker=$(cat "$tmp/own/frontend/Dockerfile")
ok "a project's own Dockerfile is untouched, and it gets none of the template's web files" 'new repo "$tmp/own" own && [[ "$(cat "$tmp/own/frontend/Dockerfile")" == "$owndocker" && ! -e "$tmp/own/frontend/nginx.conf" ]]'

# a backend that arrives later
git -C "$tmp/web" add -A; git -C "$tmp/web" commit -q -m launched
echo "# mine" >> "$tmp/web/.github/workflows/image.yml"
ok "backend added, but the workflow has uncommitted changes: refused" '! new repo "$tmp/web" my-site api && grep -q "not committed" "$tmp/out"'
git -C "$tmp/web" checkout -q .github/workflows/image.yml
ok "backend added to a committed project: its files are written, the workflow written again" 'new repo "$tmp/web" my-site api && grep -q "^wrote backend/Dockerfile" "$tmp/out" && grep -q "^rewrote .github/workflows/image.yml" "$tmp/out" && grep -q "my-site-api:" "$tmp/web/.github/workflows/image.yml"'

# --- fleet: the project's folder in Fleet ---
F=$tmp/fleet
ok "a web-only project's Fleet folder and its line for Flux are written" 'new fleet "$F" my-site MySite "$T1" && [[ "$(cd "$F" && find apps clusters -type f | sort | tr "\n" " ")" == "apps/my-site/images.yaml apps/my-site/kustomization.yaml apps/my-site/namespace.yaml apps/my-site/web.yaml clusters/rem-vm/app-my-site.yaml " ]]'
ok "the namespace is app-<name>, marked with its repository" 'grep -q "name: app-my-site" "$F/apps/my-site/namespace.yaml" && grep -q "remservers.me/repo: remuriin/MySite" "$F/apps/my-site/namespace.yaml"'
ok "the pod starts with the given image, marked for Flux, and its Service has no fixed address" 'grep -qF "image: ghcr.io/remuriin/my-site-web:$T1 # {\"\$imagepolicy\": \"flux-system:app-my-site-web\"}" "$F/apps/my-site/web.yaml" && ! grep -q clusterIP "$F/apps/my-site/web.yaml"'
ok "web only: nothing about a backend or settings" '! grep -qE "app-my-site-api|api\.yaml|secretGenerator" "$F/apps/my-site/images.yaml" "$F/apps/my-site/kustomization.yaml"'
ok "Flux applies apps/<name>, can open encrypted settings, and removes it all when the files go" 'grep -q "path: ./apps/my-site" "$F/clusters/rem-vm/app-my-site.yaml" && grep -q "provider: sops" "$F/clusters/rem-vm/app-my-site.yaml" && grep -q "prune: true" "$F/clusters/rem-vm/app-my-site.yaml" && ! grep -q "deletionPolicy" "$F/clusters/rem-vm/app-my-site.yaml"'
ok "the template's own values are the default" 'grep -q "containerPort: 8080" "$F/apps/my-site/web.yaml" && grep -q "path: /healthz" "$F/apps/my-site/web.yaml" && grep -q "memory: 64Mi" "$F/apps/my-site/web.yaml" && ! grep -q runAsUser "$F/apps/my-site/web.yaml"'
git -C "$F" add -A; git -C "$F" commit -q -m my-site
ok "backend and settings added later: the backend's file is written, the two lists written again" 'new fleet "$F" my-site MySite "$T1" main env && grep -q "^wrote apps/my-site/api.yaml" "$tmp/out" && grep -q "^rewrote apps/my-site/images.yaml" "$tmp/out" && grep -q "^rewrote apps/my-site/kustomization.yaml" "$tmp/out" && grep -q "^kept apps/my-site/web.yaml" "$tmp/out"'
ok "... the backend waits for its first build, and the settings are generated into a Secret" 'grep -q "my-site-api:main # {" "$F/apps/my-site/api.yaml" && grep -q "app-my-site-api" "$F/apps/my-site/images.yaml" && grep -q "secretGenerator" "$F/apps/my-site/kustomization.yaml" && grep -q "envs:" "$F/apps/my-site/kustomization.yaml"'
ok "nothing is left unfilled in Fleet" '! grep -rqE "PROJECT|REPO|_TAG|(WEB|API)_(PORT|HEALTH|USER|MEM)|# (api|env):(begin|end)" "$F/apps" "$F/clusters"'
ok "own values reach the Fleet files" 'new fleet "$F" other Other "$T1" "$T1" web-port=3000 web-health=/api/ok web-user=1001 web-mem=256 api-port=4000 && grep -q "containerPort: 3000" "$F/apps/other/web.yaml" && grep -q "targetPort: 3000" "$F/apps/other/web.yaml" && grep -q "path: /api/ok" "$F/apps/other/web.yaml" && grep -q "runAsUser: 1001" "$F/apps/other/web.yaml" && grep -q "memory: 256Mi" "$F/apps/other/web.yaml" && grep -q "containerPort: 4000" "$F/apps/other/api.yaml"'

# --- what is refused ---
ok "a bad project name is refused" '! new repo "$tmp/k" "Bad Name" && ! new fleet "$tmp/k" "Bad Name" R "$T1"'
ok "a folder that is not a repository is refused" '! new repo "$tmp/bad" ok'
ok "an image tag that is not one of main is refused" '! new fleet "$tmp/k" ok R latest && ! new fleet "$tmp/k" ok R "main-abc-1" && ! new fleet "$tmp/k" ok R "$T1" "x;y"'
ok "settings without a backend are refused" '! new fleet "$tmp/k" ok R "$T1" env'
ok "a port a non-root program cannot use, root as the user, and too little memory are refused" '! new repo "$tmp/k" ok web-port=80 && ! new repo "$tmp/k" ok web-user=0 && ! new repo "$tmp/k" ok web-mem=8 && ! new repo "$tmp/k" ok api api-mem=64'
ok "a health address or a setting that could carry anything else is refused" '! new repo "$tmp/k" ok "web-health=/x y" && ! new repo "$tmp/k" ok "web-health=/x|rm" && ! new repo "$tmp/k" ok "unknown=1"'
ok "... and nothing was written for any of those" '[[ -z "$(ls "$tmp/bad")" && -z "$(ls "$tmp/k")" ]]'

[[ $fails -eq 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
