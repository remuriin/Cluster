#!/bin/bash
# Checks k8s-launch from end to end without GitHub and without a VPS. A pretend gh, ssh and curl
# stand in for the real ones. The pretend ssh runs the real VPS scripts (k8s-up-project,
# k8s-add-project) on this machine, against the pretend kubectl, nginx and certbot, so the two
# halves are tested together. Everything lives in a throwaway folder.
#   bash k8s-launch.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
fails=0
ok() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export K8S_TEST_ROOT=$T
mkdir -p "$T/bin" "$T/gh" "$T/remotes/remuriin" "$T/etc/nginx/sites-available" "$T/etc/nginx/sites-enabled" "$T/home/deploy/.ssh" "$T/kube"
. "$here/k8s-test-tools.sh"
vps_tools "$T/bin"
export PATH="$T/bin:$PATH"
export K8S_GIT_BASE=$T/remotes K8S_GITHUB_OWNER=remuriin K8S_VPS=ubuntu@140.245.60.8 K8S_SSH_KEY=$T/key
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
# line endings are left alone, so the tests behave the same on Windows and on Linux
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false
: > "$T/key"

# the Cluster repository as the PC and the VPS both have it: a copy with its own pretend GitHub
C=$T/cluster
mkdir -p "$C"; cp -r "$here"/k8s-* "$here"/README.md "$C"/
git -C "$C" init -q -b main; git -C "$C" add -A; git -C "$C" commit -q -m cluster
git init -q --bare "$T/cluster-origin.git"; git -C "$C" remote add origin "$T/cluster-origin.git"; git -C "$C" push -q -u origin main

cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
# the last argument is the command for the VPS; it is logged, and run here against the pretend tools
cmd=${!#}
echo "$cmd" >> "$K8S_TEST_ROOT/ssh.log"
[[ ! -e "$K8S_TEST_ROOT/vps-down" ]] || exit 255
if [[ "$cmd" == *"git pull"* ]]; then
  if [[ -e "$K8S_TEST_ROOT/vps-stale" ]]; then echo 0000000000000000000000000000000000000000; else git -C "$K8S_TEST_ROOT/cluster" rev-parse HEAD; fi
  exit 0
fi
eval "${cmd//sudo bash \/opt\/cluster\//bash $K8S_TEST_ROOT/cluster/}"
EOF
cat > "$T/bin/ssh-agent" <<'EOF'
#!/bin/bash
[[ "${1:-}" == -k ]] || echo "true;"
EOF
cat > "$T/bin/ssh-add" <<'EOF'
#!/bin/bash
echo "ssh-add $*" >> "$K8S_TEST_ROOT/ssh.log"
EOF
cat > "$T/bin/ssh-keygen" <<'EOF'
#!/bin/bash
# "-y" is how the launcher asks whether the key opens without a passphrase; anything else is real
for a in "$@"; do [[ "$a" != -y ]] || { [[ -e "$K8S_TEST_ROOT/key-has-no-passphrase" ]]; exit; }; done
exec /usr/bin/ssh-keygen "$@"
EOF
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
# the launcher switches Git Bash's path rewriting off for the real gh (a Windows program); this
# pretend one is a script that calls git with a folder, so it switches it back on for itself
unset MSYS_NO_PATHCONV
G=$K8S_TEST_ROOT/gh
echo "gh $*" >> "$K8S_TEST_ROOT/gh.log"
slug=; for ((i = 1; i <= $#; i++)); do [[ "${!i}" != -R ]] || { j=$((i + 1)); slug=${!j}; }; done
case "$1 $2" in
  "api user") if [[ -e "$K8S_TEST_ROOT/gh-other-account" ]]; then echo someone-else; else echo remuriin; fi ;;
  "repo view") [[ -d "$K8S_TEST_ROOT/remotes/$3.git" ]] || exit 1
               [[ "$*" != *visibility* ]] || { if [[ -e "$K8S_TEST_ROOT/repo-private" ]]; then echo PRIVATE; else echo PUBLIC; fi; } ;;
  "repo create") git init -q --bare "$K8S_TEST_ROOT/remotes/$3.git" ;;
  "variable set") echo "$3=$(cat)" >> "$G/variables" ;;
  "secret list") cat "$G/secrets" 2>/dev/null || true ;;
  "secret set") cat > "$G/deploy-key"; echo "$3	Updated" >> "$G/secrets" ;;
  "run list") echo 77 ;;
  "run watch") [[ ! -e "$K8S_TEST_ROOT/run-fails" ]] ;;
  *) echo "pretend gh: not handled: $*" >&2; exit 1 ;;
esac
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$K8S_TEST_ROOT/curl.log"
case "$*" in
  *remote_ip*) if [[ -e "$K8S_TEST_ROOT/dns-wrong" ]]; then printf 104.21.92.164; else printf 140.245.60.8; fi ;;
  *ghcr.io/token*) printf '{"token":"t"}' ;;
  *http_code*) printf 200 ;;
esac
EOF
chmod +x "$T/bin/"*

# a project the way it is before a launch: a Vite app, not yet a repository
project() { # $1 folder, then: backend, own-web
  local p=$T/$1; shift
  mkdir -p "$p/frontend/src"
  echo '{"scripts":{"build":"vite build"},"devDependencies":{"vite":"^8"}}' > "$p/frontend/package.json"
  echo '{}' > "$p/frontend/package-lock.json"
  echo 'console.log("hi")' > "$p/frontend/src/main.ts"
  printf 'VITE_API_URL=https://x.remservers.me/api\nVITE_NAME=Demo\nOTHER=ignored\n' > "$p/frontend/.env"
  for extra in "$@"; do
    case $extra in
      backend)
        mkdir -p "$p/backend/src"
        echo '{"scripts":{"build":"tsc"}}' > "$p/backend/package.json"; echo '{}' > "$p/backend/package-lock.json"
        echo 'export {}' > "$p/backend/src/server.ts"
        printf '# the database\nDB_PASSWORD=SENTINEL-9f3a7c21\nPORT=3000\n' > "$p/backend/.env" ;;
      own-web) printf 'FROM node:24\nUSER node\nCMD ["node","server.js"]\n' > "$p/frontend/Dockerfile" ;;
    esac
  done
}
launch() { bash "$C/k8s-launch" "$@" > "$T/out" 2>&1; }
out() { cat "$T/out"; }
logs() { cat "$T/ssh.log" "$T/gh.log" "$T/calls.log" "$T/curl.log" 2>/dev/null; }
changed() { logs | grep -Eq "repo create|secret set|variable set|k8s-add-project|k8s-up-project apply|kubectl .*(apply|create)"; }
reset() { rm -f "$T"/ssh.log "$T"/gh.log "$T"/calls.log "$T"/curl.log; }

# --- every check that fails leaves everything as it was ---
project p1
reset; printf 'p1\n\n\ny\n' | launch "$T/p1/nowhere"
ok "a folder that does not exist is refused" '[[ $? -ne 0 ]]'
mkdir "$T/empty"; reset; launch "$T/empty" </dev/null
ok "a project without frontend/ is refused" 'out | grep -q "no frontend/"'
mkdir -p "$T/odd/frontend"; echo '{"scripts":{"build":"next build"}}' > "$T/odd/frontend/package.json"; echo '{}' > "$T/odd/frontend/package-lock.json"
reset; launch "$T/odd" </dev/null
ok "a web app of an unknown stack without a Dockerfile stops, naming the Dockerfile" 'out | grep -q "Add a Dockerfile"'
reset; printf 'Bad_Name\n\n\ny\n' | launch "$T/p1"
ok "a bad project name is refused" 'out | grep -q "lowercase letters"'
reset; printf 'kube-system\n\n\ny\n' | launch "$T/p1"
ok "one of the cluster's own names is refused" 'out | grep -q "own names"'
touch "$T/gh-other-account"; reset; printf 'p1\n\n\ny\n' | launch "$T/p1"; rm "$T/gh-other-account"
ok "gh logged in as someone else is refused" 'out | grep -q "not logged in as remuriin"'
touch "$T/key-has-no-passphrase"; reset; printf 'p1\n\n\ny\n' | launch "$T/p1"; rm "$T/key-has-no-passphrase"
ok "an SSH key without a passphrase is refused" 'out | grep -q "has no passphrase"'
touch "$T/vps-stale"; reset; printf 'p1\n\n\ny\n' | launch "$T/p1"; rm "$T/vps-stale"
ok "a VPS with another version of the scripts is refused" 'out | grep -q "does not have this version"'
touch "$T/dns-wrong"; reset; printf 'p1\n\n\ny\n' | launch "$T/p1"; rm "$T/dns-wrong"
ok "a site name that does not lead to the VPS is refused" 'out | grep -q "does not lead to the VPS"'
echo x >> "$C/README.md"; reset; printf 'p1\n\n\ny\n' | launch "$T/p1"; git -C "$C" checkout -q README.md
ok "uncommitted changes in the Cluster folder are refused" 'out | grep -q "not committed"'
reset; printf 'p1\n\n\nn\n' | launch "$T/p1"
ok "answering no at the end stops" 'out | grep -q "stopped"'
ok "none of those created a repository, a key, a pod or anything else" '! changed && [[ ! -d "$T/remotes/remuriin/p1.git" && ! -d "$T/kube/p1" && ! -e "$T/p1/k8s" ]]'

# --- the guard before the first commit ---
project s1; echo "key" > "$T/s1/frontend/server.pem"
reset; printf 's1\n\n\ny\n' | launch "$T/s1"
ok "a key file in the project stops the launch, naming the file" 'out | grep -q "frontend/server.pem" && ! changed'
project s2 backend; echo 'const pw = "SENTINEL-9f3a7c21"' > "$T/s2/backend/src/db.ts"
reset; printf 's2\n\n\ny\n' | launch "$T/s2"
ok "a setting's value pasted into source stops it, naming the setting and the file, not the value" 'out | grep -q "DB_PASSWORD" && out | grep -q "backend/src/db.ts" && ! out | grep -q SENTINEL && ! changed'
project s3; printf -- '-----BEGIN RSA PRIVATE KEY-----\nabc\n' > "$T/s3/frontend/src/notes.txt"
reset; printf 's3\n\n\ny\n' | launch "$T/s3"
ok "a private key inside a file stops it" 'out | grep -q "hold a private key" && ! changed'
project s4 backend; printf 'GOOD=1\nthis is not a setting SECRETVALUE-77\n' > "$T/s4/backend/.env"
reset; printf 's4\n\n\ny\n' | launch "$T/s4"
ok "a settings line that is not NAME=value is reported by its number only" 'out | grep -q "line(s) 2" && ! out | grep -q SECRETVALUE && ! changed'

# --- the first launch of a web-only project ---
reset; printf 'p1\n\n\ny\n' | launch "$T/p1"; code=$?
ok "first launch, web only: succeeds and says it is live" '[[ $code -eq 0 ]] && out | grep -q "Live: https://p1.remservers.me"'
ok "the repository was created public and holds one commit with the project and the cluster files" '[[ $(git -C "$T/remotes/remuriin/p1.git" rev-list --count main) -eq 1 ]] && git -C "$T/remotes/remuriin/p1.git" ls-tree -r --name-only main | tr "\n" " " | grep -q ".github/workflows/image.yml .gitignore frontend/.dockerignore frontend/Dockerfile frontend/nginx.conf frontend/package-lock.json frontend/package.json frontend/src/main.ts k8s/namespace.yaml k8s/web.yaml nginx-site.conf"'
ok "no .env was committed" '! git -C "$T/remotes/remuriin/p1.git" ls-tree -r --name-only main | grep -q "\.env"'
ok "the build values went to GitHub as variables, and only the VITE_ ones" '[[ "$(sort "$T/gh/variables" | tr "\n" " ")" == "VITE_API_URL=https://x.remservers.me/api VITE_NAME=Demo " ]]'
ok "... and into the Dockerfile and the workflow" 'grep -q "^ARG VITE_API_URL$" "$T/p1/frontend/Dockerfile" && grep -q "^ARG VITE_NAME$" "$T/p1/frontend/Dockerfile" && grep -q "^          build-args: |$" "$T/p1/.github/workflows/image.yml" && grep -q "^            VITE_NAME=\${{ vars.VITE_NAME }}$" "$T/p1/.github/workflows/image.yml" && ! grep -q "#   VITE_API_URL" "$T/p1/.github/workflows/image.yml"'
ok "the deploy key GitHub received is a whole private key, pinned on the VPS to this namespace" 'grep -q "BEGIN OPENSSH PRIVATE KEY" "$T/gh/deploy-key" && grep -q "END OPENSSH PRIVATE KEY" "$T/gh/deploy-key" && grep -q "k8s-deploy p1\"" "$T/home/deploy/.ssh/authorized_keys"'
ok "... and it is in no output, no log and no file of the project" '! grep -rq "PRIVATE KEY" "$T/out" "$T/ssh.log" "$T/gh.log" "$T/calls.log" "$T/p1"'
ok "the VPS was handed values only: project, repository, site, address, no backend, keep" 'grep -q "k8s-up-project apply p1 remuriin/p1 p1.remservers.me 10.43.0.80 - keep" "$T/ssh.log"'
ok "the pod, the site and the certificate exist" '[[ -e "$T/kube/p1/deployment/web" ]] && grep -q ssl_certificate "$T/etc/nginx/sites-available/p1"'
ok "the pods were created before the push (so the first run is green)" '[[ $(grep -n "apply -f" "$T/calls.log" | head -1 | cut -d: -f1) -gt 0 ]] && out | grep -q "the run is green"'
ok "every login to the VPS was made without a way to ask for a password" '[[ $(grep -c "ssh-add -t 900" "$T/ssh.log") -eq 1 ]]'

# --- running it again ---
before=$(git -C "$T/p1" rev-parse HEAD)
reset; launch "$T/p1" <<<"y"; code=$?
ok "a second run asks nothing but the go-ahead and succeeds" '[[ $code -eq 0 ]] && out | grep -q "launched before"'
ok "it commits nothing, pushes nothing, makes no key and applies nothing" '[[ "$(git -C "$T/p1" rev-parse HEAD)" == "$before" ]] && ! logs | grep -Eq "repo create|secret set|k8s-add-project|kubectl .*(apply -f|create secret)|certbot"'
ok "... and says nothing changed" 'out | grep -q "Nothing changed in the project"'

# --- a backend is added later ---
mkdir -p "$T/p1/backend/src"; echo '{"scripts":{"build":"tsc"}}' > "$T/p1/backend/package.json"; echo '{}' > "$T/p1/backend/package-lock.json"
printf 'DB_PASSWORD=SENTINEL-9f3a7c21\n' > "$T/p1/backend/.env"
reset; rm -f "$T/secret-received"; launch "$T/p1" <<<"y"; code=$?
ok "backend added: succeeds, and stops for the commit" '[[ $code -eq 0 ]] && out | grep -q "The commit is yours" && [[ "$(git -C "$T/p1" rev-parse HEAD)" == "$before" ]]'
ok "the backend's files were written; the workflow and the site gained its part" '[[ -e "$T/p1/backend/Dockerfile" && -e "$T/p1/k8s/api.yaml" ]] && grep -q "p1-api:" "$T/p1/.github/workflows/image.yml" && grep -q "location /api" "$T/p1/nginx-site.conf"'
ok "the workflow kept its build values after being written again" 'grep -q "^            VITE_NAME=\${{ vars.VITE_NAME }}$" "$T/p1/.github/workflows/image.yml"'
ok "the backend pod exists on the VPS, the web pod was not applied again" '[[ -e "$T/kube/p1/deployment/api" ]] && ! grep -q "web.yaml" "$T/calls.log"'
ok "the settings reached the cluster" 'grep -q "SENTINEL-9f3a7c21" "$T/secret-received"'
ok "... and are in no output and no log" '! grep -q SENTINEL "$T/out" "$T/ssh.log" "$T/gh.log" "$T/calls.log" "$T/curl.log"'
ok "the web app's own files were not touched" 'git -C "$T/p1" diff --quiet HEAD -- frontend k8s/web.yaml k8s/namespace.yaml'
git -C "$T/p1" add -A; git -C "$T/p1" commit -q -m backend; git -C "$T/p1" push -q
ok "the backend's settings file was not committed by that" '! git -C "$T/p1" ls-files | grep -q "\.env"'

# --- settings on later runs ---
printf 'DB_PASSWORD=changed-value-123456\n' > "$T/p1/backend/.env"
reset; rm -f "$T/secret-received"; launch "$T/p1" <<<"y"
ok "a changed settings file is not sent by a plain run" '[[ ! -e "$T/secret-received" ]]'
reset; launch "$T/p1" --settings <<<"y"
ok "with --settings it is sent, and the backend restarted" 'grep -q "changed-value-123456" "$T/secret-received" && grep -q "rollout restart deployment/api" "$T/calls.log"'

# --- a project with a backend from the start, and its own Dockerfile for the web app ---
project p2 backend own-web
dockerfile=$(cat "$T/p2/frontend/Dockerfile")
reset; printf 'p2\n\n\n3000\n/\n1000\n256\ny\n' | launch "$T/p2"; code=$?
ok "own Dockerfile and a backend from the start: succeeds" '[[ $code -eq 0 ]] && out | grep -q "Live:"'
ok "the project's own Dockerfile is unchanged, and it got no template files beside it" '[[ "$(cat "$T/p2/frontend/Dockerfile")" == "$dockerfile" && ! -e "$T/p2/frontend/nginx.conf" ]]'
ok "the four answers reached its cluster file and the VPS" 'grep -q "containerPort: 3000" "$T/p2/k8s/web.yaml" && grep -q "runAsUser: 1000" "$T/p2/k8s/web.yaml" && grep -q "memory: 256Mi" "$T/p2/k8s/web.yaml" && grep -q "web-port=3000 web-health=/ web-user=1000 web-mem=256" "$T/ssh.log"'
ok "it got the next free addresses" 'grep -q "clusterIP: 10.43.0.82" "$T/p2/k8s/web.yaml" && grep -q "clusterIP: 10.43.0.83" "$T/p2/k8s/api.yaml"'
ok "the settings file stayed out of the commit" '! git -C "$T/remotes/remuriin/p2.git" ls-tree -r --name-only main | grep -q "\.env"'
reset; launch "$T/p2" <<<"y"
ok "run again: the four answers are read back from the project, not asked" '[[ $? -eq 0 ]] && grep -q "web-port=3000 web-health=/ web-user=1000 web-mem=256" "$T/ssh.log"'

# --- things that can be wrong with an existing repository ---
project p3; git -C "$T/p3" init -q -b main; git -C "$T/p3" add -A; git -C "$T/p3" commit -q -m first
git init -q --bare "$T/remotes/remuriin/p3.git"; git -C "$T/p3" remote add origin "$T/remotes/remuriin/p3.git"; git -C "$T/p3" push -q -u origin main
touch "$T/repo-private"; reset; printf 'p3\n\ny\n' | launch "$T/p3"; rm "$T/repo-private"
ok "a private repository is refused" 'out | grep -q "not a public repository" && ! changed'
echo wip > "$T/p3/frontend/src/unfinished.ts"
reset; printf 'p3\n\ny\n' | launch "$T/p3"; code=$?
ok "an existing repository: first launch succeeds" '[[ $code -eq 0 ]]'
ok "... and only the cluster files were committed, not the unfinished work" '! git -C "$T/remotes/remuriin/p3.git" ls-tree -r --name-only main | grep -q unfinished && git -C "$T/remotes/remuriin/p3.git" ls-tree -r --name-only main | grep -q "k8s/web.yaml"'

# --- the pipeline fails ---
project p4; touch "$T/run-fails"
reset; printf 'p4\n\n\ny\n' | launch "$T/p4"; code=$?; rm "$T/run-fails"
ok "a failed pipeline run is reported with its address and how to re-run it" '[[ $code -ne 0 ]] && out | grep -q "actions/runs/77" && out | grep -q "rerun 77 --failed"'

# --- a slash at the start of a value reaches gh as it is ---
ok "no argument handed to gh was rewritten into a Windows path" '! grep -Eq "[A-Z]:[/\\\\]" "$T/gh.log"'

[[ $fails -eq 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
