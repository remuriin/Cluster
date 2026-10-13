#!/bin/bash
# Checks k8s-up-project and k8s-add-project without a VPS: pretend kubectl, nginx, systemctl and
# certbot stand in for the real ones, and every file they would touch lives in a throwaway folder.
#   bash k8s-up-project.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
fails=0
ok() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export K8S_TEST_ROOT=$T
mkdir -p "$T/bin" "$T/etc/nginx/sites-available" "$T/etc/nginx/sites-enabled" "$T/home/deploy/.ssh" "$T/kube"
export PATH="$T/bin:$PATH"

. "$here/k8s-test-tools.sh"
vps_tools "$T/bin"

up() { bash "$here/k8s-up-project" "$@"; }
calls() { cat "$T/calls.log" 2>/dev/null; }
reset_calls() { : > "$T/calls.log"; }
SITE=my-app.remservers.me
REPO=remuriin/MyApp

# --- bad values stop before any tool runs ---
reset_calls
ok "a bad project name is refused" '! up check "My App" $REPO $SITE >/dev/null 2>&1 && ! up check ../x $REPO $SITE >/dev/null 2>&1'
ok "the cluster's own namespaces are refused" '! up check kube-system $REPO $SITE >/dev/null 2>&1 && ! up apply default $REPO $SITE 10.43.0.84 - keep </dev/null >/dev/null 2>&1'
ok "a bad repository or site name is refused" '! up check my-app "remuriin/My App" $SITE >/dev/null 2>&1 && ! up check my-app $REPO "a;b" >/dev/null 2>&1'
ok "... and no tool was called for any of those" '[[ -z "$(calls)" ]]'
ok "an address outside the range is refused" '! up apply my-app $REPO $SITE 8.8.8.8 - keep </dev/null >/dev/null 2>&1 && ! up apply my-app $REPO $SITE 10.43.0.84 10.43.0.10 keep </dev/null >/dev/null 2>&1'
ok "a setting that is not allowed is refused" '! up apply my-app $REPO $SITE 10.43.0.84 - keep "web-port=80" </dev/null >/dev/null 2>&1 && ! up apply my-app $REPO $SITE 10.43.0.84 - keep "web-user=0" </dev/null >/dev/null 2>&1 && ! up apply my-app $REPO $SITE 10.43.0.84 - keep "web-health=/x;rm" </dev/null >/dev/null 2>&1'
ok "... and nothing was created" '[[ ! -d "$T/kube/my-app" && -z "$(ls "$T/etc/nginx/sites-available")" ]]'

# --- check only looks, and picks the next free addresses ---
mkdir -p "$T/kube/rem-raas/service" "$T/kube/rem-servers/service"
echo 10.43.0.80 > "$T/kube/rem-raas/service/web"; echo 10.43.0.83 > "$T/kube/rem-raas/service/management"
echo 10.43.0.81 > "$T/kube/rem-servers/service/web"; echo 10.43.0.82 > "$T/kube/rem-servers/service/api"
reset_calls
out=$(up check my-app $REPO $SITE)
ok "check: a new project, no key yet, the next two free addresses" '[[ "$out" == *"state=new"* && "$out" == *"key=no"* && "$out" == *"web=10.43.0.84"* && "$out" == *"api=10.43.0.85"* && "$out" == *"secret=no"* && "$out" == *"api-pod=no"* ]]'
ok "check made only reading calls" '! calls | grep -Eq "apply|create|annotate|rollout|nginx|certbot|systemctl"'
ok "a namespace made by hand (rem-raas) cannot be taken over" '! up check rem-raas $REPO $SITE >/dev/null 2>&1'
echo "server { server_name portal.remservers.me; }" > "$T/etc/nginx/sites-available/rem-servers"
ok "a site name another site already uses is refused" '! up check my-app $REPO portal.remservers.me >/dev/null 2>&1'
ok "... but a longer name that only ends the same is not confused with it" 'up check my-app $REPO my-portal.remservers.me >/dev/null 2>&1'
echo "server { server_name old.remservers.me; }" > "$T/etc/nginx/sites-available/my-app"
ok "an nginx site set up by hand under the project's name is refused" '! up check my-app $REPO $SITE >/dev/null 2>&1'
rm "$T/etc/nginx/sites-available/my-app"

# --- apply, web only ---
reset_calls
out=$(up apply my-app $REPO $SITE 10.43.0.84 - keep </dev/null 2>&1); code=$?
ok "apply, web only: succeeds" '[[ $code -eq 0 ]]'
ok "namespace created and marked as this repository's" '[[ "$(cat "$T/kube/my-app/owner")" == "$REPO" ]]'
ok "the web pod and its address exist; no backend pod, no settings" '[[ -e "$T/kube/my-app/deployment/web" && "$(cat "$T/kube/my-app/service/web")" == 10.43.0.84 && ! -e "$T/kube/my-app/deployment/api" && ! -e "$T/kube/my-app/secret/backend-env" ]]'
ok "the nginx site is written, switched on, tested, reloaded, then given its certificate, in that order" 'grep -q "server_name $SITE;" "$T/etc/nginx/sites-available/my-app" && [[ -e "$T/etc/nginx/sites-enabled/my-app" ]] && [[ "$(calls | grep -E "^(nginx|systemctl|certbot)" | cut -d" " -f1 | tr "\n" " ")" == "nginx systemctl certbot " ]]'
ok "the certificate was asked for this site, without questions, with the redirect" 'calls | grep -q "certbot --nginx -n -d $SITE --reinstall --redirect"'
ok "the site has no /api part" '! grep -q "location /api" "$T/etc/nginx/sites-available/my-app"'

# --- running it again changes nothing ---
reset_calls
up apply my-app $REPO $SITE 10.43.0.84 - keep </dev/null >/dev/null 2>&1
ok "a second run applies nothing, writes no site, asks for no certificate" '! calls | grep -Eq "kubectl (-n my-app )?(apply|create|annotate)|nginx|systemctl|certbot"'
ok "another repository cannot apply to this namespace" '! up apply my-app remuriin/Other $SITE 10.43.0.84 - keep </dev/null >/dev/null 2>&1'

# --- a backend arrives later ---
reset_calls; rm -f "$T/secret-received"
out=$(printf 'DB_PASSWORD=SENTINEL-9f3a7c21\nPORT=3000\n' | up apply my-app $REPO $SITE 10.43.0.84 10.43.0.85 keep 2>&1); code=$?
ok "backend added: succeeds" '[[ $code -eq 0 ]]'
ok "the backend pod, its address and its settings exist" '[[ -e "$T/kube/my-app/deployment/api" && "$(cat "$T/kube/my-app/service/api")" == 10.43.0.85 && -e "$T/kube/my-app/secret/backend-env" ]]'
ok "the settings reached the cluster" 'grep -q "SENTINEL-9f3a7c21" "$T/secret-received"'
ok "... and appear in no output and on no command line" '[[ "$out" != *SENTINEL* ]] && ! calls | grep -q SENTINEL'
ok "the web pod was not applied again" '! calls | grep -q "web.yaml"'
ok "the site gained /api and got its certificate back" 'grep -q "location /api" "$T/etc/nginx/sites-available/my-app" && grep -q ssl_certificate "$T/etc/nginx/sites-available/my-app"'

# --- settings on a later run ---
reset_calls; rm -f "$T/secret-received"
up apply my-app $REPO $SITE 10.43.0.84 10.43.0.85 keep </dev/null >/dev/null 2>&1
ok "no settings handed in: the existing ones are left alone" '! calls | grep -q "create secret" && [[ -e "$T/kube/my-app/secret/backend-env" ]]'
printf 'DB_PASSWORD=other\n' | up apply my-app $REPO $SITE 10.43.0.84 10.43.0.85 keep >/dev/null 2>&1
ok "settings handed in with \"keep\": still left alone" '[[ ! -e "$T/secret-received" ]]'
reset_calls
printf 'DB_PASSWORD=other\n' | up apply my-app $REPO $SITE 10.43.0.84 10.43.0.85 replace >/dev/null 2>&1
ok "with \"replace\": stored, and the backend restarted to read them" 'grep -q "DB_PASSWORD=other" "$T/secret-received" && calls | grep -q "rollout restart deployment/api"'
reset_calls
out=$(printf 'GOOD=1\nthis line is a SECRETVALUE-77 with no name\n' | up apply my-app $REPO $SITE 10.43.0.84 10.43.0.85 replace 2>&1); code=$?
ok "a line that is not NAME=value fails without repeating the line" '[[ $code -eq 1 && "$out" != *SECRETVALUE* ]]'

# --- a project with a backend from the start, and its own settings for the pods ---
reset_calls
up apply two $REPO two.remservers.me 10.43.0.90 10.43.0.91 keep api-port=4000 api-health=/api/health web-port=3000 web-user=1001 web-mem=256 </dev/null >/dev/null 2>&1
ok "a new project with a backend and no settings gets an empty set" '[[ -e "$T/kube/two/secret/backend-env" && -e "$T/kube/two/deployment/api" && -e "$T/kube/two/deployment/web" ]]'

# --- nginx refuses the file ---
touch "$T/nginx-fails"; reset_calls
out=$(up apply three $REPO three.remservers.me 10.43.0.92 - keep </dev/null 2>&1); code=$?
ok "nginx refusing a new site: it fails, the file is gone, nothing was reloaded, no certificate asked" '[[ $code -eq 1 && ! -e "$T/etc/nginx/sites-available/three" && ! -e "$T/etc/nginx/sites-enabled/three" ]] && ! calls | grep -Eq "systemctl|certbot"'
before=$(cat "$T/etc/nginx/sites-available/two")
sed -i '/location \/api/,/}/d' "$T/etc/nginx/sites-available/two"; edited=$(cat "$T/etc/nginx/sites-available/two")
up apply two $REPO two.remservers.me 10.43.0.90 10.43.0.91 keep </dev/null >/dev/null 2>&1
ok "nginx refusing a rewritten site: the old file is put back as it was" '[[ "$(cat "$T/etc/nginx/sites-available/two")" == "$edited" ]]'
rm "$T/nginx-fails"

# --- the certificate fails ---
touch "$T/certbot-fails"; reset_calls
out=$(up apply four $REPO four.remservers.me 10.43.0.93 - keep </dev/null 2>&1); code=$?
ok "a failed certificate: exit 3, with everything else in place" '[[ $code -eq 3 && -e "$T/kube/four/deployment/web" && -e "$T/etc/nginx/sites-available/four" ]]'
rm "$T/certbot-fails"
up apply four $REPO four.remservers.me 10.43.0.93 - keep </dev/null >/dev/null 2>&1; code=$?
ok "... and the next run only asks for the certificate" '[[ $code -eq 0 ]] && grep -q ssl_certificate "$T/etc/nginx/sites-available/four"'

# --- check on a project that exists ---
out=$(up check my-app $REPO $SITE)
ok "check on its own project: its addresses, its settings, its backend pod" '[[ "$out" == *"state=own"* && "$out" == *"web=10.43.0.84"* && "$out" == *"api=10.43.0.85"* && "$out" == *"secret=yes"* && "$out" == *"api-pod=yes"* ]]'
out=$(up check four $REPO four.remservers.me)
ok "check on a web-only project offers the next free address for a backend" '[[ "$out" == *"web=10.43.0.93"* && "$out" == *"api=10.43.0.86"* ]]'

# --- k8s-add-project ---
add() { bash "$here/k8s-add-project" "$@"; }
out=$(add my-app 2>&1)
line=$(cat "$T/home/deploy/.ssh/authorized_keys")
ok "add-project prints a whole private key" '[[ "$out" == *"BEGIN OPENSSH PRIVATE KEY"* && "$out" == *"END OPENSSH PRIVATE KEY"* ]]'
ok "the key is pinned to its namespace" '[[ "$line" == "restrict,command=\"sudo /usr/local/sbin/k8s-deploy my-app\" ssh-ed25519 "* ]]'
ok "check now reports the key" '[[ "$(up check my-app $REPO $SITE)" == *"key=yes"* ]]'
ok "a second key for the same namespace is refused" '! add my-app >/dev/null 2>&1'
add my-app-2 >/dev/null 2>&1
ok "my-app-2 is a different namespace" '[[ $(wc -l < "$T/home/deploy/.ssh/authorized_keys") -eq 2 ]]'
add --replace my-app >/dev/null 2>&1
ok "--replace swaps the key: still one line for my-app, a different key, my-app-2 untouched" '[[ $(grep -c "k8s-deploy my-app\"" "$T/home/deploy/.ssh/authorized_keys") -eq 1 && $(wc -l < "$T/home/deploy/.ssh/authorized_keys") -eq 2 && "$(grep "k8s-deploy my-app\"" "$T/home/deploy/.ssh/authorized_keys")" != "$line" ]]'
ok "a bad name and the cluster's own namespaces are refused" '! add "x y" >/dev/null 2>&1 && ! add ../x >/dev/null 2>&1 && ! add kube-system >/dev/null 2>&1 && ! add --replace default >/dev/null 2>&1'

[[ $fails -eq 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
