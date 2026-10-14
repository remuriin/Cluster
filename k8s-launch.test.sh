#!/bin/bash
# Checks k8s-launch from end to end without GitHub, without the cluster and without the VPS.
# A pretend gh, sops and curl stand in for the real ones; GitHub's repositories and Fleet are folders.
# Everything lives in a throwaway folder.
#   bash k8s-launch.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
fails=0
ok() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi; }

T=$(mktemp -d); trap '[[ -n "${KEEP:-}" ]] && echo "kept $T" || rm -rf "$T"' EXIT
export K8S_TEST_ROOT=$T
mkdir -p "$T/bin" "$T/gh" "$T/remotes/remuriin" "$T/home/.fleet"
export PATH="$T/bin:$PATH" HOME=$T/home
export K8S_GIT_BASE=$T/remotes K8S_GITHUB_OWNER=remuriin K8S_FLEET=$T/fleet
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
# line endings are left alone, so the tests behave the same on Windows and on Linux
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false
printf 'TOKEN-SENTINEL-4b1d' > "$HOME/.fleet/webhook-token"

# Fleet, as the PC has it: the age public key and the shared webhook's path, and its own pretend GitHub
F=$T/fleet
git init -q --bare "$T/fleet-origin.git"
git init -q -b main "$F"
printf 'creation_rules:\n  - age: age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq\n' > "$F/.sops.yaml"
echo "/hook/$(printf 'a%.0s' {1..64})" > "$F/projects-hook"
mkdir -p "$F/apps/rem-servers" "$F/clusters/rem-vm"
printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: rem-servers\n' > "$F/apps/rem-servers/namespace.yaml"
git -C "$F" add -A; git -C "$F" commit -q -m fleet; git -C "$F" remote add origin "$T/fleet-origin.git"; git -C "$F" push -q -u origin main

cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
# nothing in a launch may log in to the VPS any more
echo "ssh $*" >> "$K8S_TEST_ROOT/ssh.log"; exit 255
EOF
cat > "$T/bin/sops" <<'EOF'
#!/bin/bash
# like the real one with dotenv: every value encrypted, names kept, a few lines of its own at the end
echo "sops $*" >> "$K8S_TEST_ROOT/sops.log"
[[ ! -e "$K8S_TEST_ROOT/sops-fails" ]] || exit 1
in=${!#}
while IFS= read -r line; do
  [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
  echo "${line%%=*}=ENC[AES256_GCM,data:x,type:str]"
done < "$in"
echo "sops_version=3.13.3"
# like the real one, every run gives a different result
echo "sops_lastmodified=$RANDOM$RANDOM"
EOF
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
# the launcher switches Git Bash's path rewriting off for the real gh (a Windows program); this
# pretend one is a script that calls git with a folder, so it switches it back on for itself
unset MSYS_NO_PATHCONV
G=$K8S_TEST_ROOT/gh
echo "gh $*" >> "$K8S_TEST_ROOT/gh.log"
case "$1 $2" in
  "api user") if [[ -e "$K8S_TEST_ROOT/gh-other-account" ]]; then echo someone-else; else echo remuriin; fi ;;
  "api repos/"*)
    r=${2#repos/}; r=${r%/hooks}
    if [[ "$*" == *"config[url]="* ]]; then
      for a in "$@"; do [[ "$a" != "config[secret]=@"* ]] || cp "${a#"config[secret]=@"}" "$G/hook-secret"; done
      echo "$r" >> "$G/hooks"
    else
      ! grep -qx "$r" "$G/hooks" 2>/dev/null || echo "https://flux.remservers.me/hook/x"
    fi ;;
  "repo view") [[ -d "$K8S_TEST_ROOT/remotes/$3.git" ]] || exit 1
               [[ "$*" != *visibility* ]] || { if [[ -e "$K8S_TEST_ROOT/repo-private" ]]; then echo PRIVATE; else echo PUBLIC; fi; } ;;
  "repo create") git init -q --bare "$K8S_TEST_ROOT/remotes/$3.git" ;;
  "variable set") echo "$3=$(cat)" >> "$G/variables" ;;
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
  *http_code*) printf 200 ;;
esac
EOF
# no real waiting in the tests
printf '#!/bin/bash\n' > "$T/bin/sleep"
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
        # Windows line endings, as an editor on the PC may save it
        printf '# the database\r\nDB_PASSWORD=SENTINEL-9f3a7c21\r\nPORT=3000\r\n' > "$p/backend/.env" ;;
      own-web) printf 'FROM node:24\nUSER node\nCMD ["node","server.js"]\n' > "$p/frontend/Dockerfile" ;;
    esac
  done
}
launch() { bash "$here/k8s-launch" "$@" > "$T/out" 2>&1; }
out() { cat "$T/out"; }
logs() { cat "$T/gh.log" "$T/curl.log" "$T/sops.log" 2>/dev/null; }
fleetcount() { git -C "$T/fleet-origin.git" rev-list --count main; }
changed() { logs | grep -Eq "repo create|variable set|config\[url\]|sops -e" || [[ $(fleetcount) -gt $fleetbase ]]; }
reset() { rm -f "$T"/gh.log "$T"/curl.log "$T"/sops.log; fleetbase=$(fleetcount); }
fleetbase=$(fleetcount)

# --- every check that fails leaves everything as it was ---
# the answers, in order: repository name (Enter: the folder's), project name, go ahead
project p1
reset; printf '\np1\ny\n' | launch "$T/p1/nowhere"
ok "a folder that does not exist is refused" '[[ $? -ne 0 ]]'
mkdir "$T/empty"; reset; launch "$T/empty" </dev/null
ok "a project without frontend/ is refused" 'out | grep -q "no frontend/"'
mkdir -p "$T/odd/frontend"; echo '{"scripts":{"build":"next build"}}' > "$T/odd/frontend/package.json"; echo '{}' > "$T/odd/frontend/package-lock.json"
reset; launch "$T/odd" </dev/null
ok "a web app of an unknown stack without a Dockerfile stops, naming the Dockerfile" 'out | grep -q "Add a Dockerfile"'
reset; printf '\nBad_Name\ny\n' | launch "$T/p1"
ok "a bad project name is refused" 'out | grep -q "lowercase letters"'
for n in kube-system rag portal flux-system rem-raas-clients flux; do
  reset; printf '\n%s\ny\n' "$n" | launch "$T/p1"
  ok "the taken name $n is refused" 'out | grep -q "is taken"'
done
reset; printf '\nrem-servers\ny\n' | launch "$T/p1"
ok "a name already in Fleet is refused" 'out | grep -qE "is taken|already in Fleet"'
touch "$T/gh-other-account"; reset; printf '\np1\ny\n' | launch "$T/p1"; rm "$T/gh-other-account"
ok "gh logged in as someone else is refused" 'out | grep -q "not logged in as remuriin"'
touch "$T/dns-wrong"; reset; printf '\np1\ny\n' | launch "$T/p1"; rm "$T/dns-wrong"
ok "a site name that does not lead to the VPS is refused" 'out | grep -q "does not lead to the VPS"'
echo x > "$F/stray"; reset; printf '\np1\ny\n' | launch "$T/p1"; rm "$F/stray"
ok "a Fleet folder with uncommitted changes is refused" 'out | grep -q "Fleet folder has changes"'
git -C "$F" rm -q projects-hook; git -C "$F" commit -qm "no hook"; git -C "$F" push -q
reset; printf '\np1\ny\n' | launch "$T/p1"
ok "a Fleet without the shared webhook path is refused" 'out | grep -q "projects-hook"'
git -C "$F" revert --no-edit HEAD >/dev/null; git -C "$F" push -q; fleetbase=$(fleetcount)
mv "$HOME/.fleet/webhook-token" "$T/wt"; reset; printf '\np1\ny\n' | launch "$T/p1"; mv "$T/wt" "$HOME/.fleet/webhook-token"
ok "a missing webhook secret is refused before anything is done" 'out | grep -q "webhook secret"'
reset; printf '\np1\nn\n' | launch "$T/p1"
ok "answering no at the end stops" 'out | grep -q "stopped"'
ok "none of those created a repository, a webhook, a Fleet commit or anything else" '! changed && [[ ! -d "$T/remotes/remuriin/p1.git" && ! -e "$F/apps/p1" ]]'
ok "nothing ever tried to log in to the VPS" '[[ ! -e "$T/ssh.log" ]]'

# --- the guard before the first commit ---
project s1; echo "key" > "$T/s1/frontend/server.pem"
reset; printf '\ns1\ny\n' | launch "$T/s1"
ok "a key file in the project stops the launch, naming the file" 'out | grep -q "frontend/server.pem" && ! changed'
project s2 backend; echo 'const pw = "SENTINEL-9f3a7c21"' > "$T/s2/backend/src/db.ts"
reset; printf '\ns2\ny\n' | launch "$T/s2"
ok "a setting's value pasted into source stops it, naming the setting and the file, not the value" 'out | grep -q "DB_PASSWORD" && out | grep -q "backend/src/db.ts" && ! out | grep -q SENTINEL && ! changed'
project s4 backend; printf 'GOOD=1\nthis is not a setting SECRETVALUE-77\n' > "$T/s4/backend/.env"
reset; printf '\ns4\ny\n' | launch "$T/s4"
ok "a settings line that is not NAME=value is reported by its number only" 'out | grep -q "line(s) 2" && ! out | grep -q SECRETVALUE && ! changed'

# --- the first launch of a web-only project ---
reset; printf '\np1\ny\n' | launch "$T/p1"; code=$?
ok "first launch, web only: succeeds and says it is live" '[[ $code -eq 0 ]] && out | grep -q "Live: https://p1.remservers.me"'
ok "the repository was created and holds the project and its workflow, no cluster files" 'git -C "$T/remotes/remuriin/p1.git" ls-tree -r --name-only main | tr "\n" " " | grep -q ".github/workflows/image.yml .gitignore frontend/.dockerignore frontend/Dockerfile frontend/nginx.conf" && ! git -C "$T/remotes/remuriin/p1.git" ls-tree -r --name-only main | grep -qE "^k8s/|nginx-site"'
ok "no .env was committed" '! git -C "$T/remotes/remuriin/p1.git" ls-tree -r --name-only main | grep -q "\.env"'
ok "the workflow pushes the tag Flux sorts by, and has no deploy job" 'grep -q "p1-web:main-\${{ github.sha }}-\${{ steps.ts.outputs.ts }}" "$T/p1/.github/workflows/image.yml" && ! grep -q "^  deploy:" "$T/p1/.github/workflows/image.yml"'
ok "the build values went to GitHub as variables, and only the VITE_ ones" '[[ "$(sort "$T/gh/variables" | tr "\n" " ")" == "VITE_API_URL=https://x.remservers.me/api VITE_NAME=Demo " ]]'
ok "... and into the Dockerfile and the workflow" 'grep -q "^ARG VITE_NAME$" "$T/p1/frontend/Dockerfile" && grep -q "^            VITE_NAME=\${{ vars.VITE_NAME }}$" "$T/p1/.github/workflows/image.yml"'
ok "the webhook was made, with the shared path, and the secret was read from its file" 'grep -qx "remuriin/p1" "$T/gh/hooks" && grep -q "config\[url\]=https://flux.remservers.me/hook/aaaa" "$T/gh.log" && grep -q TOKEN-SENTINEL "$T/gh/hook-secret"'
ok "... and the secret is in no output and no log" '! grep -q TOKEN-SENTINEL "$T/out" "$T/gh.log" "$T/curl.log"'
tag=main-$(git -C "$T/p1" rev-parse HEAD)-$(git -C "$T/p1" show -s --format=%ct HEAD)
ok "Fleet got the project's folder and its line for Flux, in one pushed commit" '(for x in apps/p1/images.yaml apps/p1/kustomization.yaml apps/p1/namespace.yaml apps/p1/web.yaml clusters/rem-vm/app-p1.yaml; do git -C "$T/fleet-origin.git" ls-tree -r --name-only main | grep -qx "$x" || exit 1; done) &&[[ "$(git -C "$T/fleet-origin.git" log -1 --format=%s main)" == "launch p1 (remuriin/p1)" ]]'
ok "the web pod starts with the image the pipeline built, with the marker for Flux" 'grep -qF "image: ghcr.io/remuriin/p1-web:$tag # {\"\$imagepolicy\": \"flux-system:app-p1-web\"}" "$F/apps/p1/web.yaml"'
ok "its namespace is app-p1, marked with the repository" 'grep -q "name: app-p1" "$F/apps/p1/namespace.yaml" && grep -q "remservers.me/repo: remuriin/p1" "$F/apps/p1/namespace.yaml"'
ok "web only: no backend file, no settings, no backend image to watch" '[[ ! -e "$F/apps/p1/api.yaml" && ! -e "$F/apps/p1/backend.env" ]] && ! grep -qE "app-p1-api|api\.yaml" "$F/apps/p1/images.yaml" "$F/apps/p1/kustomization.yaml" && ! grep -q secretGenerator "$F/apps/p1/kustomization.yaml"'
ok "nothing is left unfilled in Fleet" '! grep -rqE "PROJECT|REPO|_TAG|WEB_(PORT|HEALTH|USER|MEM)|# (api|env):(begin|end)" "$F/apps/p1" "$F/clusters/rem-vm/app-p1.yaml"'

# --- running it again ---
before=$(git -C "$T/p1" rev-parse HEAD); fbefore=$(fleetcount)
reset; launch "$T/p1" <<<"y"; code=$?
ok "a second run asks nothing but the go-ahead, knows the project, and succeeds" '[[ $code -eq 0 ]] && out | grep -q "launched before as p1"'
ok "it commits nothing, pushes nothing, makes no webhook and says nothing changed" '[[ "$(git -C "$T/p1" rev-parse HEAD)" == "$before" && $(fleetcount) -eq $fbefore ]] && ! logs | grep -Eq "repo create|config\[url\]|sops -e" && out | grep -q "Nothing changed"'

# --- a backend is added later ---
mkdir -p "$T/p1/backend/src"; echo '{"scripts":{"build":"tsc"}}' > "$T/p1/backend/package.json"; echo '{}' > "$T/p1/backend/package-lock.json"
printf 'DB_PASSWORD=SENTINEL-9f3a7c21\n' > "$T/p1/backend/.env"
reset; launch "$T/p1" <<<"y"; code=$?
ok "backend added: succeeds, and stops for the commits" '[[ $code -eq 0 ]] && out | grep -q "The commits are yours" && [[ "$(git -C "$T/p1" rev-parse HEAD)" == "$before" && $(fleetcount) -eq $fbefore ]]'
ok "the project got the backend's Dockerfile and the workflow its part, keeping the build values" '[[ -e "$T/p1/backend/Dockerfile" ]] && grep -q "p1-api:main-" "$T/p1/.github/workflows/image.yml" && grep -q "^            VITE_NAME=\${{ vars.VITE_NAME }}$" "$T/p1/.github/workflows/image.yml"'
ok "Fleet got the backend's file, waiting for its first build, and the lists gained its part" 'grep -q "p1-api:main # {" "$F/apps/p1/api.yaml" && grep -q "app-p1-api" "$F/apps/p1/images.yaml" && grep -q -- "- api.yaml" "$F/apps/p1/kustomization.yaml" && grep -q secretGenerator "$F/apps/p1/kustomization.yaml"'
ok "the settings were encrypted into Fleet, names kept, values not" 'grep -q "^DB_PASSWORD=ENC\[" "$F/apps/p1/backend.env" && ! grep -rq SENTINEL "$F"'
ok "... and the plain settings are in no output, no log, and no leftover file" '! grep -q SENTINEL "$T/out" "$T/gh.log" "$T/curl.log" "$T/sops.log" && ! ls -d "$HOME"/.fleet/tmp.* >/dev/null 2>&1'
ok "the web app's own files were not touched" 'git -C "$T/p1" diff --quiet HEAD -- frontend && git -C "$F" diff --quiet HEAD -- apps/p1/web.yaml apps/p1/namespace.yaml'
git -C "$T/p1" add -A; git -C "$T/p1" commit -q -m backend; git -C "$T/p1" push -q
git -C "$F" add -A; git -C "$F" commit -q -m "p1 backend"; git -C "$F" push -q
ok "the backend's settings file was not committed by that" '! git -C "$T/p1" ls-files | grep -q "\.env"'

# --- settings on later runs ---
printf 'DB_PASSWORD=changed-value-123456\n' > "$T/p1/backend/.env"
reset; launch "$T/p1" <<<"y"
ok "a changed settings file is not encrypted again by a plain run" '! grep -q "sops -e" "$T/sops.log" 2>/dev/null'
reset; launch "$T/p1" --settings <<<"y"
ok "with --settings it is, and the commit is left to you" 'grep -q "sops -e" "$T/sops.log" && git -C "$F" status --short | grep -q "apps/p1/backend.env"'
git -C "$F" checkout -q -- apps/p1/backend.env

# --- a project with a backend from the start, and its own Dockerfile for the web app ---
project p2 backend own-web
dockerfile=$(cat "$T/p2/frontend/Dockerfile")
reset; printf '\np2\n3000\n/\n1000\n256\ny\n' | launch "$T/p2"; code=$?
ok "own Dockerfile and a backend from the start: succeeds" '[[ $code -eq 0 ]] && out | grep -q "Live:"'
ok "the project's own Dockerfile is unchanged, and it got no template files beside it" '[[ "$(cat "$T/p2/frontend/Dockerfile")" == "$dockerfile" && ! -e "$T/p2/frontend/nginx.conf" ]]'
ok "the four answers reached its Fleet file" 'grep -q "containerPort: 3000" "$F/apps/p2/web.yaml" && grep -q "runAsUser: 1000" "$F/apps/p2/web.yaml" && grep -q "memory: 256Mi" "$F/apps/p2/web.yaml"'
ok "both pods start with the image the pipeline built" 'grep -q "p2-web:main-[0-9a-f]\{40\}-[0-9]* # {" "$F/apps/p2/web.yaml" && grep -q "p2-api:main-[0-9a-f]\{40\}-[0-9]* # {" "$F/apps/p2/api.yaml"'
ok "settings saved with Windows line endings are encrypted cleanly" 'grep -q "^DB_PASSWORD=ENC\[" "$F/apps/p2/backend.env" && ! grep -q $'"'"'\r'"'"' "$F/apps/p2/backend.env"'
ok "the settings file stayed out of the project's commit" '! git -C "$T/remotes/remuriin/p2.git" ls-tree -r --name-only main | grep -q "\.env"'
reset; launch "$T/p2" <<<"y"
ok "run again: the four answers are read back from Fleet, not asked" '[[ $? -eq 0 ]] && out | grep -q "Nothing changed"'

# --- an existing repository ---
project p3; git -C "$T/p3" init -q -b main; git -C "$T/p3" add -A; git -C "$T/p3" commit -q -m first
git init -q --bare "$T/remotes/remuriin/p3.git"; git -C "$T/p3" remote add origin "$T/remotes/remuriin/p3.git"; git -C "$T/p3" push -q -u origin main
touch "$T/repo-private"; reset; printf 'p3\ny\n' | launch "$T/p3"; rm "$T/repo-private"
ok "a private repository is refused" 'out | grep -q "not a public repository" && ! changed'
echo wip > "$T/p3/frontend/src/unfinished.ts"
reset; printf 'p3\ny\n' | launch "$T/p3"; code=$?
ok "an existing repository: first launch succeeds" '[[ $code -eq 0 ]]'
ok "... and only the new files were committed, not the unfinished work" '! git -C "$T/remotes/remuriin/p3.git" ls-tree -r --name-only main | grep -q unfinished && git -C "$T/remotes/remuriin/p3.git" ls-tree -r --name-only main | grep -q ".github/workflows/image.yml"'

# --- the pipeline fails, then is fixed ---
project p4; touch "$T/run-fails"
reset; printf '\np4\ny\n' | launch "$T/p4"; code=$?; rm "$T/run-fails"
ok "a failed pipeline run is reported with its address, and Fleet is not touched" '[[ $code -ne 0 ]] && out | grep -q "actions/runs/77" && [[ ! -e "$F/apps/p4" ]]'
reset; printf 'p4\ny\n' | launch "$T/p4"; code=$?
ok "run again after the fix: it goes on from the push and launches" '[[ $code -eq 0 ]] && out | grep -q "Live: https://p4.remservers.me" && [[ -e "$F/apps/p4/web.yaml" ]]'

ok "no argument handed to gh was rewritten into a Windows path" '! grep -Eq "config\[url\]=[A-Z]:" "$T/gh.log"'
ok "no launch ever tried to log in to the VPS" '[[ ! -e "$T/ssh.log" ]]'

[[ $fails -eq 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
