# DSpace 9 One-Click Installer (Ubuntu / Oracle Cloud VM)

Ek script se poora DSpace install hota hai:
Java 17, PostgreSQL, Solr 9, Tomcat 10.1, Node 20, Angular UI, Nginx, firewall.

## Requirements
- Ubuntu 22.04 ya 24.04 (x86 ya ARM), root/sudo access
- Minimum 2 vCPU aur 4 GB RAM recommended (kam RAM par script khud swap banati hai)
- Cloud firewall me TCP 80 aur 443 allow hona chahiye (Oracle: VCN > Security List > Ingress Rule)

## Install (GitHub se)

Option 1: clone karke
```bash
git clone https://github.com/libraryrhsgc/Dspace-install.git
cd Dspace-install
sudo bash install-dspace.sh
```

Option 2: seedha one-liner
```bash
curl -fsSL https://raw.githubusercontent.com/libraryrhsgc/Dspace-install/main/install-dspace.sh | sudo bash
```

Script install ke time khud puchhegi:
1. VM ka public IP ya domain (IP apne aap detect karke dikhati hai)
2. Admin email
3. Admin password (hidden input, 2 baar)

## Bina sawal ke (automation)
```bash
sudo PUBLIC_HOST=1.2.3.4 ADMIN_EMAIL=admin@example.com ADMIN_PASS='Strong@123' \
  bash install-dspace.sh
```

## Optional settings (env variables)
| Variable | Default | Matlab |
|---|---|---|
| `HTTP_PORT` / `HTTPS_PORT` | 80 / 443 | Nginx public ports |
| `UI_PORT` | 4000 | Angular UI (localhost) |
| `TOMCAT_PORT` | 8080 | Backend /server (localhost) |
| `SOLR_PORT` | 8983 | Solr (localhost) |
| `PG_PORT` | 5432 | PostgreSQL (localhost) |
| `ENABLE_SSL` | no | Domain ho to `yes` (Let's Encrypt) |
| `DSPACE_VERSION` | 9.1 | DSpace version |

## Install ke baad
- Site: `http://<IP>` , Admin panel: login karke Menu > Admin
- Details: `/root/dspace-install-info.txt`
- Services: `systemctl status tomcat solr dspace-ui nginx postgresql`
- Logs: `journalctl -u dspace-ui -f` aur `/opt/tomcat/logs/catalina.out`
