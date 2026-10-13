#!/bin/bash
# Checks k8s-new-project, on any machine with bash and git:
#   bash k8s-template.test.sh
# (k8s-add-project and k8s-up-project are checked in k8s-up-project.test.sh, k8s-launch in k8s-launch.test.sh.)
set -u
here=$(cd "$(dirname "$0")" && pwd)
fails=0
ok() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false
new() { bash "$here/k8s-new-project" "$@" >"$tmp/out" 2>&1; }
git init -q -b main "$tmp/full"; git init -q -b main "$tmp/web"; git init -q -b main "$tmp/own"; mkdir "$tmp/bad"

ok "a project with a backend is written" 'new "$tmp/full" my-app my-app.remservers.me 10.43.0.84 10.43.0.85'
ok "... with every file it needs" '[[ -e "$tmp/full/frontend/Dockerfile" && -e "$tmp/full/frontend/nginx.conf" && -e "$tmp/full/backend/Dockerfile" && -e "$tmp/full/k8s/namespace.yaml" && -e "$tmp/full/k8s/web.yaml" && -e "$tmp/full/k8s/api.yaml" && -e "$tmp/full/nginx-site.conf" && -e "$tmp/full/.github/workflows/image.yml" ]]'
ok "a web-only project is written" 'new "$tmp/web" my-site my-site.remservers.me 10.43.0.86'
ok "... without the backend's files or lines" '[[ ! -e "$tmp/web/backend" && ! -e "$tmp/web/k8s/api.yaml" ]] && ! grep -rq "api" "$tmp/web/.github/workflows/image.yml" "$tmp/web/nginx-site.conf"'
ok "\"-\" in place of the api address also means web only" 'git init -q "$tmp/dash" && new "$tmp/dash" dash dash.remservers.me 10.43.0.87 - && [[ ! -e "$tmp/dash/k8s/api.yaml" ]]'
ok "nothing is left unfilled" '! grep -rqE "PROJECT|REPO|SITE_NAME|WEB_(IP|PORT|HEALTH|USER|MEM)|API_(IP|PORT|HEALTH|USER|MEM)|# api:" "$tmp/full" "$tmp/web" --exclude-dir=.git'
ok "the names landed where they belong" 'grep -q "clusterIP: 10.43.0.85" "$tmp/full/k8s/api.yaml" && grep -q "namespace: my-app" "$tmp/full/k8s/web.yaml" && grep -q "ghcr.io/remuriin/my-app-web:main" "$tmp/full/k8s/web.yaml" && grep -q "server_name my-app.remservers.me;" "$tmp/full/nginx-site.conf"'
ok "the template's own values are the default" 'grep -q "containerPort: 8080" "$tmp/full/k8s/web.yaml" && grep -q "path: /healthz" "$tmp/full/k8s/web.yaml" && grep -q "memory: 64Mi" "$tmp/full/k8s/web.yaml" && ! grep -q runAsUser "$tmp/full/k8s/web.yaml" && grep -q "containerPort: 3000" "$tmp/full/k8s/api.yaml" && grep -q "runAsUser: 1000" "$tmp/full/k8s/api.yaml" && grep -q "memory: 256Mi" "$tmp/full/k8s/api.yaml"'

# running it again
before=$(cd "$tmp/full" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 cat | cksum)
ok "a second run succeeds and says every file was kept" 'new "$tmp/full" my-app my-app.remservers.me 10.43.0.84 10.43.0.85 && ! grep -q "^wrote" "$tmp/out" && grep -q "^kept k8s/web.yaml" "$tmp/out"'
ok "... and changed nothing" '[[ "$(cd "$tmp/full" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 cat | cksum)" == "$before" ]]'

# a project with its own Dockerfile
mkdir -p "$tmp/own/frontend"; printf 'FROM node:24\nUSER node\n' > "$tmp/own/frontend/Dockerfile"; owndocker=$(cat "$tmp/own/frontend/Dockerfile")
ok "a project with its own Dockerfile is written, with its own values" 'new "$tmp/own" own own.remservers.me 10.43.0.88 web-port=3000 web-health=/api/ok web-user=1001 web-mem=256'
ok "... its Dockerfile is untouched and it gets none of the template's web files" '[[ "$(cat "$tmp/own/frontend/Dockerfile")" == "$owndocker" && ! -e "$tmp/own/frontend/nginx.conf" && ! -e "$tmp/own/frontend/.dockerignore" ]]'
ok "... and its values are in its cluster file" 'grep -q "containerPort: 3000" "$tmp/own/k8s/web.yaml" && grep -q "targetPort: 3000" "$tmp/own/k8s/web.yaml" && grep -q "path: /api/ok" "$tmp/own/k8s/web.yaml" && grep -q "runAsUser: 1001" "$tmp/own/k8s/web.yaml" && grep -q "memory: 256Mi" "$tmp/own/k8s/web.yaml"'

# a backend that arrives later
git -C "$tmp/web" add -A; git -C "$tmp/web" commit -q -m launched
echo "# mine" >> "$tmp/web/nginx-site.conf"
ok "backend added, but a shared file has uncommitted changes: refused" '! new "$tmp/web" my-site my-site.remservers.me 10.43.0.86 10.43.0.89 && grep -q "not committed" "$tmp/out"'
git -C "$tmp/web" checkout -q nginx-site.conf
ok "backend added to a committed project: its files are written, the two shared files written again" 'new "$tmp/web" my-site my-site.remservers.me 10.43.0.86 10.43.0.89 && grep -q "^wrote k8s/api.yaml" "$tmp/out" && grep -q "^rewrote nginx-site.conf" "$tmp/out" && grep -q "^rewrote .github/workflows/image.yml" "$tmp/out" && grep -q "^kept k8s/web.yaml" "$tmp/out"'
ok "... and they now have the backend's part" 'grep -q "location /api" "$tmp/web/nginx-site.conf" && grep -q "my-site-api:" "$tmp/web/.github/workflows/image.yml" && grep -q "api \$GITHUB_SHA" "$tmp/web/.github/workflows/image.yml"'

# --render: the VPS's use
mkdir "$tmp/r"
ok "--render needs no repository and writes only the cluster files and the site" 'new --render "$tmp/r" my-app my-app.remservers.me 10.43.0.84 10.43.0.85 && [[ "$(cd "$tmp/r" && find . -type f | sort | tr "\n" " ")" == "./k8s/api.yaml ./k8s/namespace.yaml ./k8s/web.yaml ./nginx-site.conf " ]]'

# what is refused
ok "an address outside the range is refused" '! new "$tmp/bad" ok a.remservers.me 10.43.0.10 && ! new "$tmp/bad" ok a.remservers.me 8.8.8.8'
ok "the same address twice is refused" '! new "$tmp/bad" ok a.remservers.me 10.43.0.90 10.43.0.90'
ok "a bad project or site name is refused" '! new "$tmp/bad" "Bad Name" a.remservers.me 10.43.0.90 && ! new "$tmp/bad" ok "a b" 10.43.0.90'
ok "a folder that is not a repository is refused" '! new "$tmp/bad" ok a.remservers.me 10.43.0.90'
ok "a port a non-root program cannot use, root as the user, and too little memory are refused" 'git init -q "$tmp/k" && ! new "$tmp/k" ok a.remservers.me 10.43.0.90 web-port=80 && ! new "$tmp/k" ok a.remservers.me 10.43.0.90 web-user=0 && ! new "$tmp/k" ok a.remservers.me 10.43.0.90 web-mem=8 && ! new "$tmp/k" ok a.remservers.me 10.43.0.90 10.43.0.91 api-mem=64'
ok "a health address or a setting that could carry anything else is refused" '! new "$tmp/k" ok a.remservers.me 10.43.0.90 "web-health=/x y" && ! new "$tmp/k" ok a.remservers.me 10.43.0.90 "web-health=/x|rm" && ! new "$tmp/k" ok a.remservers.me 10.43.0.90 "unknown=1"'
ok "... and nothing was written for any of those" '[[ -z "$(ls "$tmp/bad")" && -z "$(ls "$tmp/k")" ]]'

[[ $fails -eq 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
