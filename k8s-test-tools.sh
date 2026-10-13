#!/bin/bash
# The pretend VPS tools the tests share. Sourced, not run:
#   . k8s-test-tools.sh; vps_tools <folder>
# puts a pretend kubectl, nginx, systemctl and certbot into <folder>. They keep their "cluster" and
# their log under $K8S_TEST_ROOT, and never touch anything outside it.
vps_tools() {
  mkdir -p "$1"
# --- the pretend tools. Each writes what it was asked to do into calls.log. ---
cat > "$1/kubectl" <<'EOF'
#!/bin/bash
# a tiny stand-in cluster: objects are empty files under $K8S_TEST_ROOT/kube/<namespace>/<kind>/<name>
K=$K8S_TEST_ROOT/kube
echo "kubectl $*" >> "$K8S_TEST_ROOT/calls.log"
ns=
if [[ "$1" == -n ]]; then ns=$2; shift 2; fi
case "$1 $2" in
  "get namespace") [[ -d "$K/$3" ]] || exit 1; [[ "$*" == *jsonpath* ]] && cat "$K/$3/owner" 2>/dev/null; exit 0 ;;
  "get services") cat "$K"/*/service/* 2>/dev/null; exit 0 ;;
  "get service") [[ -e "$K/$ns/service/$3" ]] || exit 1; [[ "$*" == *jsonpath* ]] && tr -d '\n' < "$K/$ns/service/$3"; exit 0 ;;
  "get secret"|"get deployment") [[ -e "$K/$ns/$2/$3" ]]; exit ;;
  "annotate namespace") printf %s "${4#*=}" > "$K/$3/owner"; exit 0 ;;
  "rollout restart") exit 0 ;;
  "create secret")
    if [[ "$*" == *--dry-run* ]]; then
      # like the real one: blank lines and # comments are skipped; any other line that is not
      # NAME=value is an error that repeats the line
      while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* || "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { echo "error: \"$line\" is not a valid key" >&2; exit 1; }
        echo "$line" >> "$K8S_TEST_ROOT/secret-received"
      done
      echo "SECRET-YAML"; exit 0
    fi
    mkdir -p "$K/$ns/secret"; : > "$K/$ns/secret/backend-env"; exit 0 ;;
  "apply -f")
    if [[ "$3" == - ]]; then grep -q SECRET-YAML || exit 1; mkdir -p "$K/$ns/secret"; : > "$K/$ns/secret/backend-env"; exit 0; fi
    kind=$(awk '/^kind:/{print $2; exit}' "$3"); name=$(awk '/^  name:/{print $2; exit}' "$3"); n=$(awk '/^  namespace:/{print $2; exit}' "$3")
    if [[ "$kind" == Namespace ]]; then mkdir -p "$K/$name"; exit 0; fi
    mkdir -p "$K/$n/deployment" "$K/$n/service"; : > "$K/$n/deployment/$name"
    awk '/clusterIP:/{print $2}' "$3" > "$K/$n/service/$name"; exit 0 ;;
esac
echo "pretend kubectl: not handled: $*" >&2; exit 1
EOF
cat > "$1/nginx" <<'EOF'
#!/bin/bash
echo "nginx $*" >> "$K8S_TEST_ROOT/calls.log"
[[ ! -e "$K8S_TEST_ROOT/nginx-fails" ]]
EOF
cat > "$1/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$K8S_TEST_ROOT/calls.log"
EOF
cat > "$1/certbot" <<'EOF'
#!/bin/bash
echo "certbot $*" >> "$K8S_TEST_ROOT/calls.log"
[[ ! -e "$K8S_TEST_ROOT/certbot-fails" ]] || exit 1
# like the real one, it edits the site file of the name it was given
site=; while [[ $# -gt 0 ]]; do [[ "$1" == -d ]] && site=$2; shift; done
f=$(grep -l "server_name $site;" "$K8S_TEST_ROOT"/etc/nginx/sites-available/*)
echo "    ssl_certificate /etc/letsencrypt/live/$site/fullchain.pem; # managed by Certbot" >> "$f"
EOF
chmod +x "$1/"*
}
