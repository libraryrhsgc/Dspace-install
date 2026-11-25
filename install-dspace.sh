#!/usr/bin/env bash
# =====================================================================
#  DSpace 9.x full installer  (Oracle Cloud VM - Ubuntu 22.04 / 24.04)
#  Stack: Java 17 + PostgreSQL + Solr 9 + Tomcat 10.1 + Node 20 + Nginx
#  Run:   sudo bash install-dspace.sh
# =====================================================================
set -euo pipefail

############################ CONFIG ############################
# Har value env variable se override ho sakti hai, jaise:
#   sudo PUBLIC_HOST=1.2.3.4 ADMIN_EMAIL=a@b.com ADMIN_PASS='Secret@123' bash install-dspace.sh
# Jo value nahi doge wo install ke time puchhi jayegi (IP, email, password).
DSPACE_VERSION="${DSPACE_VERSION:-9.1}"      # backend + frontend dono ka same version
SOLR_VERSION="${SOLR_VERSION:-9.9.0}"
TOMCAT_VERSION="${TOMCAT_VERSION:-10.1.34}"
MAVEN_VERSION="${MAVEN_VERSION:-3.9.9}"

# --- Ye install ke time puchhe jayenge (ya env se do) ---
PUBLIC_HOST="${PUBLIC_HOST:-}"      # public IP ya domain
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ADMIN_PASS="${ADMIN_PASS:-}"
ENABLE_SSL="${ENABLE_SSL:-}"        # sirf domain ho tab: yes/no
ADMIN_FIRST="${ADMIN_FIRST:-Admin}"
ADMIN_LAST="${ADMIN_LAST:-User}"

# --- PORTS ---
HTTP_PORT="${HTTP_PORT:-80}"          # Nginx (public)
HTTPS_PORT="${HTTPS_PORT:-443}"       # Nginx SSL (public)
UI_PORT="${UI_PORT:-4000}"            # DSpace Angular frontend (sirf localhost)
TOMCAT_PORT="${TOMCAT_PORT:-8080}"    # DSpace backend /server (sirf localhost)
SOLR_PORT="${SOLR_PORT:-8983}"        # Solr (sirf localhost)
PG_PORT="${PG_PORT:-5432}"            # PostgreSQL (sirf localhost)

# --- Database ---
DB_NAME="${DB_NAME:-dspace}"
DB_USER="${DB_USER:-dspace}"
DB_PASS="${DB_PASS:-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')}"

# --- Paths ---
DSPACE_DIR="${DSPACE_DIR:-/opt/dspace}"
SRC_DIR="${SRC_DIR:-/opt/dspace-src}"
UI_DIR="${UI_DIR:-/opt/dspace-angular}"
TOMCAT_DIR="${TOMCAT_DIR:-/opt/tomcat}"
DSPACE_USER="${DSPACE_USER:-dspace}"
############################################################################

die(){ echo -e "\033[1;31mERROR: $*\033[0m" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Root se chalao: sudo bash $0"

# curl chahiye (IP detect + downloads)
command -v curl >/dev/null || { apt-get update -y && apt-get install -y curl; }

# curl ... | sudo bash se chalane par stdin pipe hota hai, isliye keyboard /dev/tty se padhte hain
have_tty(){ { : </dev/tty; } 2>/dev/null; }

ask(){  # ask VAR "sawal" "default"
  local __var="$1" __q="$2" __def="${3:-}" __ans=""
  if have_tty; then read -r -p "${__q}${__def:+ [$__def]}: " __ans </dev/tty || true; fi
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

# ---- Public IP / domain ----
if [[ -z "$PUBLIC_HOST" ]]; then
  DETECTED_IP="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  have_tty || die "Non-interactive mode me PUBLIC_HOST env variable do."
  ask PUBLIC_HOST "VM ka public IP ya domain" "$DETECTED_IP"
fi
PUBLIC_HOST="${PUBLIC_HOST#http://}"; PUBLIC_HOST="${PUBLIC_HOST#https://}"; PUBLIC_HOST="${PUBLIC_HOST%%/*}"
[[ -n "$PUBLIC_HOST" ]] || die "PUBLIC_HOST khali nahi ho sakta."

# ---- SSL: sirf domain ke liye ----
if [[ "$PUBLIC_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  ENABLE_SSL="no"      # IP par SSL certificate nahi milta
elif [[ -z "$ENABLE_SSL" ]]; then
  ask ENABLE_SSL "Domain mila hai. Free SSL - Let's Encrypt - lagana hai? DNS pehle VM par point hona chahiye - yes/no" "no"
fi
[[ "$ENABLE_SSL" == "yes" ]] || ENABLE_SSL="no"

# ---- Admin email ----
if [[ -z "$ADMIN_EMAIL" ]]; then
  have_tty || die "Non-interactive mode me ADMIN_EMAIL env variable do."
  ask ADMIN_EMAIL "DSpace admin email" ""
fi
[[ "$ADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "Email sahi nahi hai: $ADMIN_EMAIL"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-$ADMIN_EMAIL}"

# ---- Admin password ----
if [[ -z "$ADMIN_PASS" ]]; then
  have_tty || die "Non-interactive mode me ADMIN_PASS env variable do."
  while true; do
    read -r -s -p "DSpace admin password - kam se kam 8 characters: " P1 </dev/tty; echo
    read -r -s -p "Password dobara likho: " P2 </dev/tty; echo
    if [[ ${#P1} -ge 8 && "$P1" == "$P2" ]]; then ADMIN_PASS="$P1"; break; fi
    echo "Password match nahi hua ya 8 se chhota hai. Dobara try karo."
  done
fi
[[ ${#ADMIN_PASS} -ge 8 ]] || die "Password kam se kam 8 characters ka hona chahiye."

echo
echo "-------- Install summary --------"
echo "Host / IP : $PUBLIC_HOST   SSL: $ENABLE_SSL"
echo "Admin     : $ADMIN_EMAIL"
echo "DSpace    : $DSPACE_VERSION   Ports: ${HTTP_PORT}/${HTTPS_PORT} public"
echo "---------------------------------"
if have_tty; then
  ask GO "Install shuru karein? y/n" "y"
  [[ "$GO" =~ ^[Yy] ]] || die "Cancelled."
fi

if [[ "$ENABLE_SSL" == "yes" ]]; then PROTO="https"; PUB_PORT="$HTTPS_PORT"; SSL_BOOL="true"
else PROTO="http"; PUB_PORT="$HTTP_PORT"; SSL_BOOL="false"; fi
BASE_URL="${PROTO}://${PUBLIC_HOST}"
export DEBIAN_FRONTEND=noninteractive

log(){ echo -e "\n\033[1;32m==> $*\033[0m"; }

# ---------------------------------------------------------------- 1. Swap
log "1/13 Swap check - Angular build ko RAM chahiye"
MEM_MB=$(free -m | awk '/Mem:/{print $2}')
if [[ $MEM_MB -lt 6000 ]] && ! swapon --show | grep -q swap; then
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ---------------------------------------------------------------- 2. Packages
log "2/13 System packages"
apt-get update -y
apt-get install -y openjdk-17-jdk ant git curl wget unzip tar nginx \
  postgresql postgresql-contrib iptables-persistent netfilter-persistent \
  build-essential python3 lsof openssl ca-certificates gnupg

JAVA_HOME_DIR="$(dirname "$(dirname "$(readlink -f "$(which javac)")")")"

# ---------------------------------------------------------------- 3. Maven
log "3/13 Maven ${MAVEN_VERSION}"
if [[ ! -d /opt/maven ]]; then
  wget -q "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" -O /tmp/maven.tgz
  mkdir -p /opt/maven && tar xzf /tmp/maven.tgz -C /opt/maven --strip-components=1
  ln -sf /opt/maven/bin/mvn /usr/local/bin/mvn
fi

# ---------------------------------------------------------------- 4. Node
log "4/13 Node.js 20 + yarn"
if ! command -v node >/dev/null || [[ "$(node -v | cut -d. -f1 | tr -d v)" -lt 20 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
npm install -g yarn

# ---------------------------------------------------------------- 5. User
log "5/13 dspace user + directories"
id "$DSPACE_USER" &>/dev/null || useradd -m -s /bin/bash "$DSPACE_USER"
mkdir -p "$DSPACE_DIR" "$SRC_DIR" "$UI_DIR"
chown -R "$DSPACE_USER":"$DSPACE_USER" "$DSPACE_DIR" "$SRC_DIR" "$UI_DIR"

# ---------------------------------------------------------------- 6. PostgreSQL
log "6/13 PostgreSQL - port ${PG_PORT}"
PG_CONF="$(sudo -u postgres psql -tAc 'SHOW config_file')"
sed -i -E "s/^#?port\s*=.*/port = ${PG_PORT}/" "$PG_CONF"
sed -i -E "s/^#?listen_addresses\s*=.*/listen_addresses = 'localhost'/" "$PG_CONF"
systemctl restart postgresql
sudo -u postgres psql -p "$PG_PORT" -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
  sudo -u postgres psql -p "$PG_PORT" -c "CREATE USER ${DB_USER};"
sudo -u postgres psql -p "$PG_PORT" -c "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"
sudo -u postgres psql -p "$PG_PORT" -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || \
  sudo -u postgres psql -p "$PG_PORT" -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UNICODE';"
sudo -u postgres psql -p "$PG_PORT" -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

# ---------------------------------------------------------------- 7. Solr
log "7/13 Solr ${SOLR_VERSION} - port ${SOLR_PORT}, localhost only"
if [[ ! -d /opt/solr && ! -f /etc/systemd/system/solr.service && ! -f /etc/init.d/solr ]]; then
  rm -rf /tmp/solr-install && mkdir -p /tmp/solr-install && cd /tmp/solr-install
  # Solr badi file hai aur archive.apache.org dheere chalta hai.
  # /var/tmp me cache rakhte hain, aur wget -c se adhoori download wahin se aage badhti hai.
  SOLR_TGZ="/var/tmp/solr-${SOLR_VERSION}.tgz"
  wget -c --tries=5 --progress=dot:giga "https://archive.apache.org/dist/solr/solr/${SOLR_VERSION}/solr-${SOLR_VERSION}.tgz" -O "$SOLR_TGZ"
  # installer ko file ka naam solr-VERSION.tgz hi chahiye
  cp "$SOLR_TGZ" "/tmp/solr-install/solr-${SOLR_VERSION}.tgz"
  tar xzf "solr-${SOLR_VERSION}.tgz" "solr-${SOLR_VERSION}/bin/install_solr_service.sh" --strip-components=2
  bash ./install_solr_service.sh "solr-${SOLR_VERSION}.tgz" -p "$SOLR_PORT" -n
  cd /tmp
fi
grep -q 'DSpace settings' /etc/default/solr.in.sh || cat >> /etc/default/solr.in.sh <<EOF

# --- DSpace settings ---
SOLR_JETTY_HOST="127.0.0.1"
SOLR_OPTS="\$SOLR_OPTS -Dsolr.config.lib.enabled=true"
EOF

# ---------------------------------------------------------------- 8. Tomcat
log "8/13 Tomcat ${TOMCAT_VERSION} - port ${TOMCAT_PORT}, localhost only"
if [[ ! -d "$TOMCAT_DIR" ]]; then
  wget -q "https://archive.apache.org/dist/tomcat/tomcat-10/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz" -O /tmp/tomcat.tgz
  mkdir -p "$TOMCAT_DIR" && tar xzf /tmp/tomcat.tgz -C "$TOMCAT_DIR" --strip-components=1
  rm -rf "$TOMCAT_DIR"/webapps/{ROOT,docs,examples,host-manager,manager}
fi
# connector port + sirf localhost par bind
sed -i -E "s|<Connector port=\"[0-9]+\" protocol=\"HTTP/1.1\"|<Connector port=\"${TOMCAT_PORT}\" address=\"127.0.0.1\" protocol=\"HTTP/1.1\"|" "$TOMCAT_DIR/conf/server.xml"
# Nginx ke peeche sahi scheme/IP ke liye
grep -q RemoteIpValve "$TOMCAT_DIR/conf/server.xml" || \
  sed -i 's|</Host>|  <Valve className="org.apache.catalina.valves.RemoteIpValve" />\n      </Host>|' "$TOMCAT_DIR/conf/server.xml"
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
Environment="CATALINA_OPTS=-Xms512m -Xmx1024m -Dfile.encoding=UTF-8"
ExecStart=${TOMCAT_DIR}/bin/startup.sh
ExecStop=${TOMCAT_DIR}/bin/shutdown.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------- 9. DSpace backend
log "9/13 DSpace ${DSPACE_VERSION} backend download + local.cfg"
if [[ ! -f "$SRC_DIR/pom.xml" ]]; then
  wget -q "https://github.com/DSpace/DSpace/archive/refs/tags/dspace-${DSPACE_VERSION}.tar.gz" -O /tmp/dspace.tgz
  tar xzf /tmp/dspace.tgz -C "$SRC_DIR" --strip-components=1
fi
cat > "$SRC_DIR/dspace/config/local.cfg" <<EOF
dspace.dir = ${DSPACE_DIR}
dspace.server.url = ${BASE_URL}/server
dspace.ui.url = ${BASE_URL}
dspace.name = DSpace Repository

db.url = jdbc:postgresql://localhost:${PG_PORT}/${DB_NAME}
db.username = ${DB_USER}
db.password = ${DB_PASS}

solr.server = http://localhost:${SOLR_PORT}/solr
EOF
chown -R "$DSPACE_USER":"$DSPACE_USER" "$SRC_DIR"

log "10/13 Backend build - Maven + Ant - 10-20 min lag sakte hain"
# Maven/Ant ko kaafi heap do, warna "Java heap space" error aata hai (war banate waqt)
MEM_NOW=$(free -m | awk '/Mem:/{print $2}')
MVN_HEAP=$(( MEM_NOW * 6 / 10 )); [[ $MVN_HEAP -lt 2048 ]] && MVN_HEAP=2048; [[ $MVN_HEAP -gt 4096 ]] && MVN_HEAP=4096
echo "Maven heap: ${MVN_HEAP}m (RAM ${MEM_NOW}m)"
sudo -u "$DSPACE_USER" env JAVA_HOME="$JAVA_HOME_DIR" MAVEN_OPTS="-Xmx${MVN_HEAP}m" ANT_OPTS="-Xmx${MVN_HEAP}m" bash -c "
  cd '$SRC_DIR' && mvn -U clean package -DskipTests &&
  cd dspace/target/dspace-installer && ant fresh_install"

# Solr cores copy karke Solr start
cp -r "$DSPACE_DIR"/solr/* /var/solr/data/
chown -R solr:solr /var/solr/data
systemctl daemon-reload
systemctl enable --now solr
sleep 15

# Tomcat me backend deploy
ln -sfn "$DSPACE_DIR/webapps/server" "$TOMCAT_DIR/webapps/server"
chown -R "$DSPACE_USER":"$DSPACE_USER" "$DSPACE_DIR"

sudo -u "$DSPACE_USER" "$DSPACE_DIR/bin/dspace" database migrate
sudo -u "$DSPACE_USER" "$DSPACE_DIR/bin/dspace" create-administrator \
  -e "$ADMIN_EMAIL" -f "$ADMIN_FIRST" -l "$ADMIN_LAST" -p "$ADMIN_PASS" -c en || true

systemctl enable --now tomcat
log "Tomcat start ho raha hai, 40 sec wait..."
sleep 40

# ---------------------------------------------------------------- 11. Frontend
log "11/13 DSpace Angular frontend - port ${UI_PORT}"
if [[ ! -f "$UI_DIR/package.json" ]]; then
  wget -q "https://github.com/DSpace/dspace-angular/archive/refs/tags/dspace-${DSPACE_VERSION}.tar.gz" -O /tmp/ui.tgz
  tar xzf /tmp/ui.tgz -C "$UI_DIR" --strip-components=1
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
sudo -u "$DSPACE_USER" bash -c "
  cd '$UI_DIR' &&
  export NODE_OPTIONS=--max-old-space-size=4096 &&
  yarn install --frozen-lockfile &&
  yarn build:prod"

cat > /etc/systemd/system/dspace-ui.service <<EOF
[Unit]
Description=DSpace Angular UI
After=network.target tomcat.service

[Service]
Type=simple
User=${DSPACE_USER}
WorkingDirectory=${UI_DIR}
Environment=NODE_ENV=production
ExecStart=$(which node) dist/server/main.js
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now dspace-ui

# ---------------------------------------------------------------- 12. Nginx
log "12/13 Nginx reverse proxy - port ${HTTP_PORT}"
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
    }
}
EOF
ln -sf /etc/nginx/sites-available/dspace /etc/nginx/sites-enabled/dspace
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable --now nginx && systemctl reload nginx

if [[ "$ENABLE_SSL" == "yes" ]]; then
  apt-get install -y certbot python3-certbot-nginx
  certbot --nginx -d "$PUBLIC_HOST" -m "$CERTBOT_EMAIL" --agree-tos -n --redirect
fi

# ---------------------------------------------------------------- 13. Firewall
log "13/13 Firewall - iptables - sirf public ports kholo"
for P in 22 "$HTTP_PORT" "$HTTPS_PORT"; do
  iptables -C INPUT -p tcp --dport "$P" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport "$P" -j ACCEPT
done
netfilter-persistent save

# Search index build
sudo -u "$DSPACE_USER" "$DSPACE_DIR/bin/dspace" index-discovery -b || true

cat > /root/dspace-install-info.txt <<EOF
DSpace URL     : ${BASE_URL}
Backend API    : ${BASE_URL}/server
Admin login    : ${ADMIN_EMAIL} / ${ADMIN_PASS}
DB             : ${DB_NAME} / ${DB_USER} / ${DB_PASS}   (port ${PG_PORT})
Ports (local)  : UI ${UI_PORT}, Tomcat ${TOMCAT_PORT}, Solr ${SOLR_PORT}
Services       : tomcat, solr, dspace-ui, nginx, postgresql
EOF
chmod 600 /root/dspace-install-info.txt

log "DONE!  Browser me kholo: ${BASE_URL}"
echo "Details: /root/dspace-install-info.txt"
echo "IMPORTANT: Oracle Cloud console > VCN > Security List me ingress rule add karo: TCP ${HTTP_PORT} aur ${HTTPS_PORT} (0.0.0.0/0)"
