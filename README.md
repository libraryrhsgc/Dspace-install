# DSpace 9 Installer

Install DSpace 9 on a fresh Ubuntu server with two commands.

## Before you start

- Ubuntu **22.04 or 24.04**, **4 GB RAM** or more
- Nothing else using port 80 (no Apache, no Koha on the same server)
- In your cloud firewall allow **TCP 80 and 443**
  (Oracle Cloud: VCN > Security List > Add Ingress Rule)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/libraryrhsgc/Dspace-install/main/install-dspace.sh -o install-dspace.sh
sudo bash install-dspace.sh
```

The script asks for three things: **server IP** (it suggests one), **admin email** and **admin password**.
After that it keeps running in the background, even if you close the terminal.

## Check progress

```bash
tail -f /root/dspace-install.log
```

It is finished when the log shows `==> DONE`. This takes 30-60+ minutes.
Long quiet periods are normal. Press `Ctrl+C` to stop watching; the install keeps going.

## Open DSpace

Go to `http://YOUR_SERVER_IP` and log in with the email and password you entered.
Your details are also saved in `/root/dspace-install-info.txt`.

## If something fails

Run the same two commands again. Finished steps are skipped, so it continues where it stopped.
To see what went wrong:

```bash
tail -40 /root/dspace-install.log
```

| Problem | Fix |
|---|---|
| `Java heap space` or killed during build | Server has too little RAM. Use 4 GB+ RAM. |
| Site does not open from outside | Open TCP 80/443 in the cloud firewall. |
| `Port 80 is already used` | Stop the other web server (Apache) or use a different server. |

## Remove everything

```bash
curl -fsSL https://raw.githubusercontent.com/libraryrhsgc/Dspace-install/main/cleanup-server.sh -o cleanup-server.sh
sudo bash cleanup-server.sh
```

This deletes DSpace and its data. It asks you to type `YES` first.

## No questions (automation)

```bash
sudo PUBLIC_HOST=1.2.3.4 ADMIN_EMAIL=you@example.com ADMIN_PASS='YourPassword' bash install-dspace.sh
```
