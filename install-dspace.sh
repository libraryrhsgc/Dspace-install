#!/usr/bin/env bash
# =====================================================================
#  DSpace 9 - one-command installer
#  Ubuntu 22.04 / 24.04 (x86 or ARM), e.g. an Oracle Cloud VM
#
#  Stack : Java 17, PostgreSQL, Solr 9, Tomcat 10.1, Node 20, Angular UI, Nginx
#
#  Usage : sudo bash install-dspace.sh
#          The script asks for IP/domain, admin email and password,
#          then keeps running in the background (safe if SSH disconnects).
#          Watch progress with:  tail -f /root/dspace-install.log
#
#  No questions (automation):
#    sudo PUBLIC_HOST=1.2.3.4 ADMIN_EMAIL=a@b.com ADMIN_PASS='Strong@123' bash install-dspace.sh
#  Run in foreground instead of background:  DETACH=no
# =====================================================================
set -Eeuo pipefail

SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/libraryrhsgc/Dspace-install/main/install-dspace.sh}"
LOG_FILE="${LOG_FILE:-/root/dspace-install.log}"

############################ SETTINGS ############################
DSPACE_VERSION="${DSPACE_VERSION:-9.1}"
SOLR_VERSION="${SOLR_VERSION:-9.9.0}"
TOMCAT_VERSION="${TOMCAT_VERSION:-10.1.34}"
MAVEN_VERSION="${MAVEN_VERSION:-3.9.9}"

PUBLIC_HOST="${PUBLIC_HOST:-}"        # public IP or domain (asked if empty)
ADMIN_EMAIL="${ADMIN_EMAIL:-}"        # asked if empty
ADMIN_PASS="${ADMIN_PASS:-}"          # asked if empty (min 8 chars)
ENABLE_SSL="${ENABLE_SSL:-}"          # yes/no - only for a domain
ADMIN_FIRST="${ADMIN_FIRST:-Admin}"
ADMIN_LAST="${ADMIN_LAST:-User}"

HTTP_PORT="${HTTP_PORT:-80}"          # Nginx (public)
HTTPS_PORT="${HTTPS_PORT:-443}"       # Nginx SSL (public)
UI_PORT="${UI_PORT:-4000}"            # Angular UI (localhost only)
TOMCAT_PORT="${TOMCAT_PORT:-8080}"    # Backend /server (localhost only)
SOLR_PORT="${SOLR_PORT:-8983}"        # Solr (localhost only)
PG_PORT="${PG_PORT:-5432}"            # PostgreSQL (localhost only)

DB_NAME="${DB_NAME:-dspace}"
DB_USER="${DB_USER:-dspace}"
DB_PASS="${DB_PASS:-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')}"

DSPACE_DIR="${DSPACE_DIR:-/opt/dspace}"
SRC_DIR="${SRC_DIR:-/opt/dspace-src}"
UI_DIR="${UI_DIR:-/opt/dspace-angular}"
TOMCAT_DIR="${TOMCAT_DIR:-/opt/tomcat}"
DSPACE_USER="${DSPACE_USER:-dspace}"
###################################################################

SELF_PATH="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true)"   # resolve before any cd
STEP="start"
die(){ echo -e "\033[1;31mERROR: $*\033[0m" >&2; exit 1; }
warn(){ echo -e "\033[1;33mWARNING: $*\033[0m" >&2; }
log(){ STEP="$*"; echo -e "\n\033[1;32m==> $*\033[0m"; }
trap 'echo -e "\n\033[1;31mFAILED during: ${STEP} (line ${LINENO}). Fix the problem and run the script again - finished steps are skipped.\033[0m" >&2' ERR

[[ $EUID -eq 0 ]] || die "Run as root:  sudo bash $0"
cd /tmp

have_tty(){ { : </dev/tty; } 2>/dev/null; }
ask(){  # ask VAR "question" "default"
  local __var="$1" __q="$2" __def="${3:-}" __ans=""
  if have_tty; then read -r -p "${__q}${__def:+ [$__def]}: " __ans </dev/tty || true; fi
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

# ======================= 1. QUESTIONS (before detaching) =======================
if [[ "${DSPACE_DETACHED:-}" != "1" ]]; then
  command -v curl >/dev/null || { apt-get update -y && apt-get install -y curl; }

  if [[ -z "$PUBLIC_HOST" ]]; then
    have_tty || die "No keyboard available - pass PUBLIC_HOST, ADMIN_EMAIL and ADMIN_PASS as environment variables."
    DETECTED_IP="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
    ask PUBLIC_HOST "Public IP or domain of this server" "$DETECTED_IP"
  fi
  PUBLIC_HOST="${PUBLIC_HOST#http://}"; PUBLIC_HOST="${PUBLIC_HOST#https://}"; PUBLIC_HOST="${PUBLIC_HOST%%/*}"
  [[ -n "$PUBLIC_HOST" ]] || die "Public IP/domain cannot be empty."

  if [[ "$PUBLIC_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ENABLE_SSL="no"                      # an IP cannot get an SSL certificate
  elif [[ -z "$ENABLE_SSL" ]]; then
    ask ENABLE_SSL "Domain detected. Enable free SSL (Let's Encrypt)? DNS must already point here. yes/no" "no"
  fi
  [[ "$ENABLE_SSL" == "yes" ]] || ENABLE_SSL="no"

  if [[ -z "$ADMIN_EMAIL" ]]; then
    have_tty || die "Pass ADMIN_EMAIL as an environment variable."
    ask ADMIN_EMAIL "Admin email" ""
  fi
  [[ "$ADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "Invalid email: $ADMIN_EMAIL"

  if [[ -z "$ADMIN_PASS" ]]; then
    have_tty || die "Pass ADMIN_PASS as an environment variable."
    while true; do
      read -r -s -p "Admin password (min 8 characters): " P1 </dev/tty; echo
      read -r -s -p "Repeat password: " P2 </dev/tty; echo
      if [[ ${#P1} -ge 8 && "$P1" == "$P2" ]]; then ADMIN_PASS="$P1"; break; fi
      echo "Passwords do not match or are shorter than 8 characters. Try again."
    done
  fi
  [[ ${#ADMIN_PASS} -ge 8 ]] || die "Password must be at least 8 characters."

  echo
  echo "-------- Install summary --------"
  echo "Address : $PUBLIC_HOST   (SSL: $ENABLE_SSL)"
  echo "Admin   : $ADMIN_EMAIL"
  echo "DSpace  : $DSPACE_VERSION"
  echo "---------------------------------"
  if have_tty; then
    ask GO "Start installation? y/n" "y"
    [[ "$GO" =~ ^[Yy] ]] || die "Cancelled."
  fi

  # ---- run in the background so an SSH disconnect cannot stop it ----
  if [[ "${DETACH:-yes}" != "no" ]]; then
    SELF="$SELF_PATH"
    if [[ ! -f "$SELF" || "$SELF" != *.sh ]]; then      # started via: curl ... | sudo bash
      SELF=/root/install-dspace.sh
      curl -fsSL "$SCRIPT_URL" -o "$SELF" || die "Could not download the script from $SCRIPT_URL"
    fi
    export PUBLIC_HOST ADMIN_EMAIL ADMIN_PASS ENABLE_SSL ADMIN_FIRST ADMIN_LAST \
           DSPACE_VERSION SOLR_VERSION TOMCAT_VERSION MAVEN_VERSION \
           HTTP_PORT HTTPS_PORT UI_PORT TOMCAT_PORT SOLR_PORT PG_PORT \
           DB_NAME DB_USER DB_PASS DSPACE_DIR SRC_DIR UI_DIR TOMCAT_DIR DSPACE_USER LOG_FILE
    : > "$LOG_FILE"
    DSPACE_DETACHED=1 setsid nohup bash "$SELF" >> "$LOG_FILE" 2>&1 < /dev/null &
    echo
    echo "Installation started in the background (takes 30-60+ minutes)."
    echo "It keeps running even if you close this terminal."
    echo
    echo "  Watch progress :  tail -f $LOG_FILE"
    echo "  Finished when  :  the log shows  ==> DONE"
    exit 0
  fi
fi

# ======================= 2. MAIN INSTALL =======================
export DEBIAN_FRONTEND=noninteractive
APT=(-y -o DPkg::Lock::Timeout=600)
if [[ "$ENABLE_SSL" == "yes" ]]; then PROTO="https"; PUB_PORT="$HTTPS_PORT"; SSL_BOOL="true"
else PROTO="http"; PUB_PORT="$HTTP_PORT"; SSL_BOOL="false"; fi
BASE_URL="${PROTO}://${PUBLIC_HOST}"
[[ "$PUB_PORT" == "80" || "$PUB_PORT" == "443" ]] && PORT_SUFFIX="" || PORT_SUFFIX=":${PUB_PORT}"
BASE_URL="${BASE_URL}${PORT_SUFFIX}"

RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
clamp(){ local v=$1 lo=$2 hi=$3; (( v<lo )) && v=$lo; (( v>hi )) && v=$hi; echo "$v"; }
MVN_HEAP=$(clamp $(( RAM_MB*60/100 )) 2048 4096)
NODE_HEAP=$(clamp $(( RAM_MB*70/100 )) 2048 4096)
if   (( RAM_MB >= 6000 )); then TOMCAT_HEAP=2048
elif (( RAM_MB >= 3500 )); then TOMCAT_HEAP=1024
else TOMCAT_HEAP=640; fi

wait_http(){  # wait_http URL TRIES  - success on 200/301/302/401
  local url="$1" tries="${2:-60}" code="" i
  for ((i=0; i<tries; i++)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)"
    if [[ "$code" =~ ^(200|301|302|401)$ ]]; then return 0; fi
    sleep 5
  done
  return 1
}

# ---------------------------------------------------------------- 1
log "1/12 Checking the server"
echo "RAM: ${RAM_MB} MB   Disk free: $(df -BG --output=avail / | tail -1 | tr -d ' ')"
(( RAM_MB >= 3500 )) || warn "Less than 4 GB RAM. DSpace will install but be slow. 4 GB+ is recommended."

if ss -ltnpH "sport = :${HTTP_PORT}" 2>/dev/null | grep -qv '"nginx"'; then
  die "Port ${HTTP_PORT} is already used by another program (Apache/Koha?). Free it or set HTTP_PORT. Details: $(ss -ltnpH "sport = :${HTTP_PORT}" | head -1)"
fi

SWAP_MB=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
if (( RAM_MB < 6000 && SWAP_MB < 4096 )); then
  echo "Creating 6 GB swap (needed for the builds)..."
  SWF=/swapfile_dspace
  if [[ ! -f "$SWF" ]]; then
    fallocate -l 6G "$SWF" 2>/dev/null || dd if=/dev/zero of="$SWF" bs=1M count=6144 status=none
    chmod 600 "$SWF"; mkswap "$SWF" >/dev/null
  fi
  swapon "$SWF" 2>/dev/null || true
  grep -q "$SWF" /etc/fstab || echo "$SWF none swap sw 0 0" >> /etc/fstab
fi

# ---------------------------------------------------------------- 2
log "2/12 System packages"
apt-get update "${APT[@]}"
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt-get install "${APT[@]}" openjdk-17-jdk ant git curl wget unzip tar nginx \
  postgresql postgresql-contrib iptables-persistent netfilter-persistent \
  build-essential python3 openssl ca-certificates gnupg iproute2
JAVA_HOME_DIR="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"

# ---------------------------------------------------------------- 3
log "3/12 Maven ${MAVEN_VERSION}, Node.js 20, yarn"
if [[ ! -x /opt/maven/bin/mvn ]]; then
  wget -q "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" -O /tmp/maven.tgz
  mkdir -p /opt/maven && tar xzf /tmp/maven.tgz -C /opt/maven --strip-components=1
  rm -f /tmp/maven.tgz
fi
ln -sf /opt/maven/bin/mvn /usr/local/bin/mvn
if ! command -v node >/dev/null || (( $(node -v | cut -d. -f1 | tr -d v) < 20 )); then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install "${APT[@]}" nodejs
fi
command -v yarn >/dev/null || npm install -g yarn

# ---------------------------------------------------------------- 4
log "4/12 User and folders"
id "$DSPACE_USER" &>/dev/null || useradd -m -s /bin/bash "$DSPACE_USER"
mkdir -p "$DSPACE_DIR" "$SRC_DIR" "$UI_DIR"
chown -R "$DSPACE_USER":"$DSPACE_USER" "$DSPACE_DIR" "$SRC_DIR" "$UI_DIR"

# ---------------------------------------------------------------- 5
log "5/12 PostgreSQL (port ${PG_PORT})"
PG_CONF="$(ls /etc/postgresql/*/main/postgresql.conf | head -1)"
sed -i -E "s/^#?port\s*=.*/port = ${PG_PORT}/" "$PG_CONF"
sed -i -E "s/^#?listen_addresses\s*=.*/listen_addresses = 'localhost'/" "$PG_CONF"
systemctl enable postgresql >/dev/null 2>&1 || true
systemctl restart postgresql
for _ in $(seq 1 30); do sudo -u postgres psql -p "$PG_PORT" -c '\q' 2>/dev/null && break; sleep 2; done
if ! sudo -u postgres psql -p "$PG_PORT" -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
  sudo -u postgres psql -p "$PG_PORT" -c "CREATE USER ${DB_USER};"
fi
sudo -u postgres psql -p "$PG_PORT" -c "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"
if ! sudo -u postgres psql -p "$PG_PORT" -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  sudo -u postgres psql -p "$PG_PORT" -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UNICODE';"
fi
sudo -u postgres psql -p "$PG_PORT" -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

# ---------------------------------------------------------------- 6
log "6/12 Solr ${SOLR_VERSION} (port ${SOLR_PORT}, localhost only)"
if [[ ! -d /opt/solr && ! -f /etc/systemd/system/solr.service && ! -f /etc/init.d/solr ]]; then
  rm -rf /tmp/solr-install && mkdir -p /tmp/solr-install
  SOLR_TGZ="/var/tmp/solr-${SOLR_VERSION}.tgz"       # cached, so a re-run does not download again
  echo "Downloading Solr (about 300 MB, can be slow - it resumes if interrupted)..."
  wget -c --tries=10 --retry-connrefused --progress=dot:giga \
       "https://archive.apache.org/dist/solr/solr/${SOLR_VERSION}/solr-${SOLR_VERSION}.tgz" -O "$SOLR_TGZ"
  cp "$SOLR_TGZ" "/tmp/solr-install/solr-${SOLR_VERSION}.tgz"   # installer needs this exact file name
  ( cd /tmp/solr-install \
    && tar xzf "solr-${SOLR_VERSION}.tgz" "solr-${SOLR_VERSION}/bin/install_solr_service.sh" --strip-components=2 \
    && bash ./install_solr_service.sh "solr-${SOLR_VERSION}.tgz" -p "$SOLR_PORT" -n )
  rm -rf /tmp/solr-install
fi
if ! grep -q 'DSpace settings' /etc/default/solr.in.sh; then
  cat >> /etc/default/solr.in.sh <<EOF

# --- DSpace settings ---
SOLR_JETTY_HOST="127.0.0.1"
SOLR_HEAP="512m"
SOLR_OPTS="\$SOLR_OPTS -Dsolr.config.lib.enabled=true"
EOF
fi

# ---------------------------------------------------------------- 7
log "7/12 Tomcat ${TOMCAT_VERSION} (port ${TOMCAT_PORT}, localhost only)"
if [[ ! -x "$TOMCAT_DIR/bin/catalina.sh" ]]; then
  wget -q "https://archive.apache.org/dist/tomcat/tomcat-10/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz" -O /tmp/tomcat.tgz
  mkdir -p "$TOMCAT_DIR" && tar xzf /tmp/tomcat.tgz -C "$TOMCAT_DIR" --strip-components=1
  rm -f /tmp/tomcat.tgz
  rm -rf "$TOMCAT_DIR"/webapps/{ROOT,docs,examples,host-manager,manager}
fi
sed -i -E "s|<Connector port=\"[0-9]+\"( address=\"[^\"]*\")? protocol=\"HTTP/1.1\"|<Connector port=\"${TOMCAT_PORT}\" address=\"127.0.0.1\" protocol=\"HTTP/1.1\"|" "$TOMCAT_DIR/conf/server.xml"
if ! grep -q RemoteIpValve "$TOMCAT_DIR/conf/server.xml"; then
  sed -i 's|</Host>|  <Valve className="org.apache.catalina.valves.RemoteIpValve" />\n      </Host>|' "$TOMCAT_DIR/conf/server.xml"
fi
# deploy the DSpace backend as /server straight from /opt/dspace/webapps/server
rm -rf "$TOMCAT_DIR/webapps/server"
mkdir -p "$TOMCAT_DIR/conf/Catalina/localhost"
cat > "$TOMCAT_DIR/conf/Catalina/localhost/server.xml" <<EOF
<Context docBase="${DSPACE_DIR}/webapps/server" reloadable="false" />
EOF
chown -R "$DSPACE_USER":"$DSPACE_USER" "$TOMCAT_DIR"

cat > /etc/systemd/system/tomcat.service <<EOF
[Unit]
Description=Apache Tomcat (DSpace backend)
After=network.target postgresql.service solr.service

[Service]
Type=forking
User=${DSPACE_USER}
Group=${DSPACE_USER}
Environment="JAVA_HOME=${JAVA_HOME_DIR}"
Environment="CATALINA_HOME=${TOMCAT_DIR}"
Environment="CATALINA_PID=${TOMCAT_DIR}/temp/tomcat.pid"
Environment="CATALINA_OPTS=-Xms256m -Xmx${TOMCAT_HEAP}m -Dfile.encoding=UTF-8"
ExecStart=${TOMCAT_DIR}/bin/startup.sh
ExecStop=${TOMCAT_DIR}/bin/shutdown.sh
Restart=on-failure
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------- 8
log "8/12 DSpace ${DSPACE_VERSION} backend (Maven build - 15-40 minutes)"
if [[ ! -f "$SRC_DIR/pom.xml" ]]; then
  wget -q "https://github.com/DSpace/DSpace/archive/refs/tags/dspace-${DSPACE_VERSION}.tar.gz" -O /tmp/dspace.tgz
  tar xzf /tmp/dspace.tgz -C "$SRC_DIR" --strip-components=1
  rm -f /tmp/dspace.tgz
fi
cat > "$SRC_DIR/dspace/config/local.cfg" <<EOF
dspace.dir = ${DSPACE_DIR}
dspace.server.url = ${BASE_URL}/server
dspace.ui.url = ${BASE_URL}
dspace.server.ssr.url = http://localhost:${TOMCAT_PORT}/server
dspace.name = DSpace Repository

db.url = jdbc:postgresql://localhost:${PG_PORT}/${DB_NAME}
db.username = ${DB_USER}
db.password = ${DB_PASS}

solr.server = http://localhost:${SOLR_PORT}/solr
EOF
chown -R "$DSPACE_USER":"$DSPACE_USER" "$SRC_DIR"

if [[ -x "$DSPACE_DIR/bin/dspace" && -d "$DSPACE_DIR/webapps/server" ]]; then
  echo "Backend already built - skipping the build."
  cp "$SRC_DIR/dspace/config/local.cfg" "$DSPACE_DIR/config/local.cfg"
  chown "$DSPACE_USER":"$DSPACE_USER" "$DSPACE_DIR/config/local.cfg"
else
  echo "Maven heap: ${MVN_HEAP} MB"
  cat > /tmp/dspace-backend-build.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$SRC_DIR"
mvn -U clean package -DskipTests
cd dspace/target/dspace-installer
ant fresh_install
EOF
  chmod 755 /tmp/dspace-backend-build.sh
  sudo -H -u "$DSPACE_USER" env JAVA_HOME="$JAVA_HOME_DIR" SRC_DIR="$SRC_DIR" \
       MAVEN_OPTS="-Xmx${MVN_HEAP}m" ANT_OPTS="-Xmx${MVN_HEAP}m" bash /tmp/dspace-backend-build.sh
  rm -f /tmp/dspace-backend-build.sh
fi
[[ -x "$DSPACE_DIR/bin/dspace" ]] || die "Backend build failed: $DSPACE_DIR/bin/dspace is missing."
chown -R "$DSPACE_USER":"$DSPACE_USER" "$DSPACE_DIR"

# ---------------------------------------------------------------- 9
log "9/12 Starting Solr, database setup, Tomcat"
cp -r "$DSPACE_DIR"/solr/* /var/solr/data/
chown -R solr:solr /var/solr/data
systemctl daemon-reload
systemctl enable solr tomcat >/dev/null 2>&1 || true
systemctl restart solr
wait_http "http://localhost:${SOLR_PORT}/solr/search/admin/ping" 60 || warn "Solr core 'search' did not answer yet - check: systemctl status solr"

sudo -H -u "$DSPACE_USER" "$DSPACE_DIR/bin/dspace" database migrate
if ! sudo -H -u "$DSPACE_USER" "$DSPACE_DIR/bin/dspace" create-administrator \
      -e "$ADMIN_EMAIL" -f "$ADMIN_FIRST" -l "$ADMIN_LAST" -p "$ADMIN_PASS" -c en; then
  warn "Admin creation failed (it may already exist). Create manually: sudo -u $DSPACE_USER $DSPACE_DIR/bin/dspace create-administrator"
fi

systemctl restart tomcat
echo "Waiting for the backend to start (can take a few minutes on small servers)..."
wait_http "http://localhost:${TOMCAT_PORT}/server/api" 120 || warn "Backend not ready yet - check: tail -f ${TOMCAT_DIR}/logs/catalina.out"

# ---------------------------------------------------------------- 10
log "10/12 DSpace Angular frontend (build - 20-60 minutes)"
if [[ ! -f "$UI_DIR/package.json" ]]; then
  wget -q "https://github.com/DSpace/dspace-angular/archive/refs/tags/dspace-${DSPACE_VERSION}.tar.gz" -O /tmp/ui.tgz
  tar xzf /tmp/ui.tgz -C "$UI_DIR" --strip-components=1
  rm -f /tmp/ui.tgz
fi
mkdir -p "$UI_DIR/config"
cat > "$UI_DIR/config/config.prod.yml" <<EOF
ui:
  ssl: false
  host: 127.0.0.1
  port: ${UI_PORT}
  nameSpace: /

rest:
  ssl: ${SSL_BOOL}
  host: ${PUBLIC_HOST}
  port: ${PUB_PORT}
  nameSpace: /server
  ssrBaseUrl: http://localhost:${TOMCAT_PORT}/server
EOF
chown -R "$DSPACE_USER":"$DSPACE_USER" "$UI_DIR"

if [[ -f "$UI_DIR/dist/server/main.js" ]]; then
  echo "Frontend already built - skipping the build."
else
  echo "Node heap: ${NODE_HEAP} MB"
  cat > /tmp/dspace-ui-build.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$UI_DIR"
export NODE_OPTIONS="--max-old-space-size=${NODE_HEAP} --dns-result-order=ipv4first"
yarn config set registry https://registry.npmjs.org
ok=0
for i in 1 2 3 4 5; do
  if yarn install --frozen-lockfile --network-timeout 600000 --network-concurrency 4; then ok=1; break; fi
  echo "yarn install failed (try $i of 5), retrying in 20 seconds..."; sleep 20
done
[[ $ok -eq 1 ]] || { echo "yarn install failed 5 times"; exit 1; }
# ng-bootstrap needs this package; install it by hand if yarn skipped it
if [[ ! -f node_modules/@popperjs/core/package.json ]]; then
  echo "@popperjs/core is missing - installing it manually"
  PKG="$(cd /tmp && npm pack @popperjs/core@2.11.8 --silent)"
  mkdir -p node_modules/@popperjs/core
  tar xzf "/tmp/$PKG" -C node_modules/@popperjs/core --strip-components=1
fi
yarn build:prod
[[ -f dist/server/main.js ]] || { echo "Frontend build output is missing"; exit 1; }
EOF
  chmod 755 /tmp/dspace-ui-build.sh
  sudo -H -u "$DSPACE_USER" env UI_DIR="$UI_DIR" NODE_HEAP="$NODE_HEAP" bash /tmp/dspace-ui-build.sh
  rm -f /tmp/dspace-ui-build.sh
fi
[[ -f "$UI_DIR/dist/server/main.js" ]] || die "Frontend build failed: dist/server/main.js is missing."

cat > /etc/systemd/system/dspace-ui.service <<EOF
[Unit]
Description=DSpace Angular UI
After=network.target tomcat.service

[Service]
Type=simple
User=${DSPACE_USER}
WorkingDirectory=${UI_DIR}
Environment=NODE_ENV=production
Environment=NODE_OPTIONS=--max-old-space-size=1024
ExecStart=$(command -v node) dist/server/main.js
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable dspace-ui >/dev/null 2>&1 || true
systemctl restart dspace-ui

# ---------------------------------------------------------------- 11
log "11/12 Nginx (port ${HTTP_PORT})"
cat > /etc/nginx/sites-available/dspace <<EOF
server {
    listen ${HTTP_PORT};
    server_name ${PUBLIC_HOST};
    client_max_body_size 2G;

    location /server/ {
        proxy_pass http://127.0.0.1:${TOMCAT_PORT}/server/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }

    location / {
        proxy_pass http://127.0.0.1:${UI_PORT}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }
}
EOF
ln -sf /etc/nginx/sites-available/dspace /etc/nginx/sites-enabled/dspace
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

if [[ "$ENABLE_SSL" == "yes" ]]; then
  apt-get install "${APT[@]}" certbot python3-certbot-nginx
  certbot --nginx -d "$PUBLIC_HOST" -m "$ADMIN_EMAIL" --agree-tos -n --redirect \
    || warn "SSL setup failed. Check that the domain points to this server, then run: certbot --nginx -d $PUBLIC_HOST"
fi

# ---------------------------------------------------------------- 12
log "12/12 Firewall and final check"
for P in 22 "$HTTP_PORT" "$HTTPS_PORT"; do
  iptables -C INPUT -p tcp --dport "$P" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport "$P" -j ACCEPT
done
netfilter-persistent save >/dev/null 2>&1 || true
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 22/tcp >/dev/null; ufw allow "${HTTP_PORT}/tcp" >/dev/null; ufw allow "${HTTPS_PORT}/tcp" >/dev/null
fi

API_OK="no"; UI_OK="no"
wait_http "http://localhost:${TOMCAT_PORT}/server/api" 36 && API_OK="yes"
wait_http "http://localhost:${UI_PORT}/" 36 && UI_OK="yes"

(sudo -H -u "$DSPACE_USER" "$DSPACE_DIR/bin/dspace" index-discovery -b >/dev/null 2>&1 || true)

INFO=/root/dspace-install-info.txt
cat > "$INFO" <<EOF
DSpace address : ${BASE_URL}
Backend API    : ${BASE_URL}/server
Admin login    : ${ADMIN_EMAIL}  (the password you entered)
Database       : ${DB_NAME} / ${DB_USER} / ${DB_PASS}  (port ${PG_PORT})
Services       : tomcat solr dspace-ui nginx postgresql
Logs           : ${TOMCAT_DIR}/logs/catalina.out , journalctl -u dspace-ui
EOF
chmod 600 "$INFO"

echo
if [[ "$API_OK" == "yes" && "$UI_OK" == "yes" ]]; then
  log "DONE - open ${BASE_URL}"
else
  log "DONE (with warnings) - backend ready: ${API_OK}, frontend ready: ${UI_OK}"
  echo "Services may still be starting. Wait 2-3 minutes, then check:"
  echo "  systemctl is-active tomcat solr dspace-ui nginx postgresql"
fi
echo "Details saved in: ${INFO}"
echo "IMPORTANT: in your cloud firewall (Oracle: VCN > Security List) allow TCP ${HTTP_PORT} and ${HTTPS_PORT}."
