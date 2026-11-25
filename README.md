# DSpace 9 One-Click Installer

Ubuntu / Oracle Cloud VM par ek script se poora **DSpace 9** install karta hai.

**Kya install hota hai:** Java 17, PostgreSQL, Solr 9, Tomcat 10.1, Node 20, Angular UI, Nginx aur firewall rules.

## Requirements

| Cheez | Zaroorat |
|---|---|
| OS | Ubuntu 22.04 ya 24.04 (x86 ya ARM) |
| Access | root / sudo |
| RAM | 4 GB ya zyada recommended (kam ho to script swap banati hai, par build dheera hoga) |
| Disk | 20 GB free |
| Cloud firewall | TCP **80** aur **443** allow (Oracle: VCN > Security List > Ingress Rule) |

> 1 GB RAM wali VM par DSpace ka build lagbhag nahi chalta. Oracle ki free Ampere (ARM) VM best hai.

## Install

### Tarika 1: Prompts ke saath (tmux me)
```bash
sudo apt-get install -y tmux
sudo tmux new -s dspace
```
Tmux ke andar:
```bash
curl -fsSL https://raw.githubusercontent.com/libraryrhsgc/Dspace-install/main/install-dspace.sh -o install-dspace.sh
bash install-dspace.sh 2>&1 | tee ~/dspace-install.log
```
Script khud puchhegi:
1. VM ka public IP ya domain (IP apne aap detect hokar dikhta hai, Enter dabao)
2. Admin email
3. Admin password (hidden, 2 baar, kam se kam 8 characters)

Tmux se bahar nikalne ke liye `Ctrl+B` phir `D`. Wapas judne ke liye `sudo tmux attach -t dspace`.

### Tarika 2: Background me (SSH disconnect hone par bhi chalta hai)
Saari values pehle deni hoti hain:
```bash
curl -fsSL https://raw.githubusercontent.com/libraryrhsgc/Dspace-install/main/install-dspace.sh -o /root/install-dspace.sh
PUBLIC_HOST=1.2.3.4 ADMIN_EMAIL=admin@example.com ADMIN_PASS='Strong@123' \
setsid nohup bash /root/install-dspace.sh > /root/dspace-install.log 2>&1 < /dev/null &
```
Progress dekhne ke liye:
```bash
tail -f /root/dspace-install.log
```
(`Ctrl+C` se sirf log dekhna band hota hai, install nahi rukta.)

> Password command ke saath shell history me save ho jata hai. Install ke baad `history -c && history -w` chala do.

### Naya version na aa raha ho to
File update karne ke baad GitHub 3-5 minute tak purana version (cache) de sakta hai. Link ke end me `?$(date +%s)` lagao aur poora link double quotes me likho:
```bash
curl -fsSL "https://raw.githubusercontent.com/libraryrhsgc/Dspace-install/main/install-dspace.sh?$(date +%s)" -o install-dspace.sh
```
Download ke baad check karo ki naya version aaya:
```bash
bash -n install-dspace.sh && echo SYNTAX_OK
grep -c 'MAVEN_OPTS' install-dspace.sh
```
`SYNTAX_OK` dikhe aur `grep` ka jawab `1` ya usse zyada aaye to file naye version ki hai.

## Kitna time lagta hai
Lagbhag **30-60 minute**. Sabse lambe steps:
- **Step 7:** Solr download (~300 MB, `archive.apache.org` dheere chalta hai)
- **Step 10:** Maven + Ant backend build
- **Step 11:** Angular frontend build (`yarn build:prod`)

Beech me log kai minute ruka dikhe to normal hai.

## Install poora hua ya nahi
Log ke end me `==> DONE!` aata hai, aur `/root/dspace-install-info.txt` file ban jati hai.
```bash
systemctl is-active tomcat solr dspace-ui nginx postgresql
curl -s -o /dev/null -w "%{http_code}\n" http://localhost/server/api
```
Sab `active` aur curl me `200` aaye to browser me `http://<IP>` kholo. Tomcat ko ready hone me 1-2 minute lag sakte hain.

## Settings (env variables)

| Variable | Default | Matlab |
|---|---|---|
| `PUBLIC_HOST` | puchhta hai | Public IP ya domain |
| `ADMIN_EMAIL` | puchhta hai | DSpace admin email |
| `ADMIN_PASS` | puchhta hai | Admin password (min 8 characters) |
| `ENABLE_SSL` | no | Domain ho to `yes` (Let's Encrypt, DNS pehle point hona chahiye) |
| `HTTP_PORT` / `HTTPS_PORT` | 80 / 443 | Nginx public ports |
| `UI_PORT` | 4000 | Angular UI (sirf localhost) |
| `TOMCAT_PORT` | 8080 | Backend `/server` (sirf localhost) |
| `SOLR_PORT` | 8983 | Solr (sirf localhost) |
| `PG_PORT` | 5432 | PostgreSQL (sirf localhost) |
| `DSPACE_VERSION` | 9.1 | DSpace version |
| `SOLR_VERSION` | 9.9.0 | Solr version |

Sirf Nginx ke ports bahar khulte hain. Baaki sab services sirf localhost par rehti hain.

## Install ke baad
- Site: `http://<IP>`
- Admin login: jo email aur password diya tha
- Details: `/root/dspace-install-info.txt`
- Services: `systemctl status tomcat solr dspace-ui nginx postgresql`
- Logs: `journalctl -u dspace-ui -f` aur `/opt/tomcat/logs/catalina.out`
- Login ke baad admin password badal do.

## Script beech me ruk jaye to
Script dobara chalane layak hai. Wahi command dobara chalao, jo steps ho chuke hain wo skip ya jaldi ho jate hain. Solr ki download bhi wahin se aage badhti hai.

Pehle purani adhoori process band kar do:
```bash
pkill -f install-dspace; pkill -f mvn; pkill -f wget
```

## Common errors

| Error | Matlab / Fix |
|---|---|
| `Java heap space` (Maven) | Maven ko kam memory mili. Script ka naya version heap khud badhata hai. `free -h` se RAM check karo, kam ho to swap badhao. |
| Site `404` ya khulti nahi, services `inactive` | Install poora nahi hua. `tail -40 /root/dspace-install.log` dekho. |
| VM ke andar `curl` chalta hai par bahar se site nahi khulti | Cloud Security List me TCP 80/443 allow nahi hai. |
| `curl ... 404` (GitHub link) | Repo private hai, branch `main` nahi, ya file ka naam galat hai. |
| `syntax error near unexpected token` | File copy-paste me bigad gayi (curly quotes ya Windows line-endings). File ko link se download karo. |

## Server saaf karna (sab kuch hatana)
```bash
sudo bash cleanup-server.sh
sudo reboot
```
Ye DSpace, Solr, Tomcat, PostgreSQL, Nginx, Apache aur MariaDB ko unke **saare data** ke saath hata deta hai. Chalane se pehle backup le lo. `YES` likhkar confirm karna padta hai.

## Files
| File | Kaam |
|---|---|
| `install-dspace.sh` | Poora installer |
| `cleanup-server.sh` | Server saaf karne ki script |
| `.gitattributes` | Line-ending ki dikkat roke rakhta hai |
