# UltraDoc AI runbook

Operational procedures for the self-hosted deployment (Ubuntu 24.04 VM,
Docker managed by Terraform, nginx in front). Commands run on the VM as the
`deploy` user unless marked `sudo`.

## Quick reference

| What | Where |
|---|---|
| App URL | `https://<vm-ip>` (self-signed cert) |
| Containers | `ultradoc-nginx`, `ultradoc-web`, `ultradoc-api`, `ultradoc-localstack` |
| Data volume | `ultradoc_data` (uploads + Chroma), mounted at `/app/data` in the API |
| Terraform state | `/opt/ultradoc/state/docker.tfstate`, `/opt/ultradoc/state/aws-local.tfstate` (contain secrets; dir is `700`) |
| Deployed image tags | `/opt/ultradoc/state/current_tag`, `/opt/ultradoc/state/previous_tag` |
| TLS cert + key | `/opt/ultradoc/certs/selfsigned.{crt,key}` |
| Script config | `/opt/ultradoc/ultradoc.env` (mode `600`) |
| Backups | `/opt/ultradoc/backups/` (newest 7) + `s3://ultradoc-backups/backups/` |
| Logs | `/opt/ultradoc/logs/{healthcheck,backup}.log`, `docker logs <container>` |
| Repo checkout | `~/ultradoc-ai` (manual ops), runner workspace `~/actions-runner/_work` |

Terraform commands below assume:

```bash
cd ~/ultradoc-ai/terraform/docker
terraform init -backend-config="path=/opt/ultradoc/state/docker.tfstate"
export TF_VAR_llm_api_key="gsk_..."            # read -s is better: see below
export TF_VAR_cert_dir=/opt/ultradoc/certs
```

Tip: `read -rs TF_VAR_llm_api_key && export TF_VAR_llm_api_key` keeps the key
out of your shell history.

---

## 1. App is down

**Symptoms:** `healthcheck.sh` failing, browser errors, 502 from nginx.

1. See what's unhealthy:
   ```bash
   /opt/ultradoc/app/scripts/healthcheck.sh
   docker ps -a --filter name=ultradoc- --format 'table {{.Names}}\t{{.Status}}'
   ```
2. Read the failing container's logs (section 6). Common causes:
   - **502 Bad Gateway**: nginx is up but `api`/`web` isn't. Check `docker logs ultradoc-api`.
   - **API unhealthy / 503 on `/api/ready`**: the response body says which check failed:
     ```bash
     curl -sk https://127.0.0.1/api/ready
     ```
     `data_dir ... not writable` means a volume permission problem (restore from backup or
     `docker run --rm -v ultradoc_data:/data alpine chown -R 10001:10001 /data`).
     `chroma: unavailable` means a corrupt store: restore from backup (section 3).
   - **OOM-killed** (`docker inspect -f '{{.State.OOMKilled}}' ultradoc-api` is `true`):
     check `free -m`; the VM needs ~2 GB free for the API. Add RAM or swap.
3. Restart one container: `docker restart ultradoc-api`
4. Recreate the whole stack from state (safe, data volume is kept):
   ```bash
   terraform apply -var "image_tag=$(cat /opt/ultradoc/state/current_tag)"
   ```
5. If the last deploy broke it, roll back (section 4).

## 2. Disk full

**Symptoms:** healthcheck `disk / FAIL`, uploads fail, Docker errors with
`no space left on device`.

```bash
df -h /                                 # how bad
docker system df                        # images / containers / volumes / build cache
sudo du -xh /var/lib/docker --max-depth=1 | sort -h | tail
du -sh /opt/ultradoc/backups /opt/ultradoc/logs
```

Free space, safest first:

1. Build cache and dangling images (nothing running uses them):
   ```bash
   docker builder prune -f
   docker image prune -f
   ```
2. Old image tags. Keep `current_tag` and `previous_tag` (needed for rollback):
   ```bash
   docker images ultradoc-api; docker images ultradoc-web
   docker rmi ultradoc-api:<old-sha> ultradoc-web:<old-sha>
   ```
3. Old local backups. They're also in S3; keep the newest few:
   ```bash
   ls -lt /opt/ultradoc/backups/
   ```
4. Journal logs: `sudo journalctl --vacuum-size=200M`
5. Container logs are capped (10 MB x 3 per container), so they're rarely the cause.

**Never** `docker volume prune` or delete `ultradoc_data`: that is the user data.

## 3. Backup and restore

Backups run daily at 02:02 from cron (`crontab -l`). Manual run:

```bash
/opt/ultradoc/app/scripts/backup.sh
tail -n 20 /opt/ultradoc/logs/backup.log
```

The API is paused for a few seconds during the snapshot so Chroma's SQLite
files are consistent.

List and restore:

```bash
/opt/ultradoc/app/scripts/restore.sh --list
/opt/ultradoc/app/scripts/restore.sh latest                                   # newest in S3
/opt/ultradoc/app/scripts/restore.sh s3:ultradoc-data-20260102T020200Z.tar.gz # a specific one
/opt/ultradoc/app/scripts/restore.sh /opt/ultradoc/backups/<file>.tar.gz      # a local file
```

Restore verifies the SHA-256 checksum, stops the API, **replaces everything**
in the volume, starts the API and checks `/api/ready`. Test a restore
periodically: a backup you haven't restored isn't a backup.

**LocalStack was restarted (VM reboot etc.).** The free LocalStack edition
keeps no state, so the bucket and the backup IAM user disappear on restart.
Recreate them and refresh the keys in `ultradoc.env`:

```bash
cd ~/ultradoc-ai/terraform/aws-local
terraform init -backend-config="path=/opt/ultradoc/state/aws-local.tfstate"
terraform apply
sed -i "s|^AWS_ACCESS_KEY_ID=.*|AWS_ACCESS_KEY_ID=$(terraform output -raw backup_access_key_id)|; \
        s|^AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=$(terraform output -raw backup_secret_access_key)|" \
  /opt/ultradoc/ultradoc.env
```

Local copies in `/opt/ultradoc/backups` survive and can be restored directly.

## 4. Roll back a deploy

The deploy workflow rolls back automatically when the health check fails.
To roll back manually (e.g. a bug found after a "successful" deploy):

```bash
cat /opt/ultradoc/state/current_tag /opt/ultradoc/state/previous_tag
docker images ultradoc-api              # which tags still exist locally

cd ~/ultradoc-ai/terraform/docker
terraform apply -var "image_tag=<previous-sha>"
curl -sk https://127.0.0.1/api/ready
echo "<previous-sha>" > /opt/ultradoc/state/current_tag
```

Then revert the bad commit on `main` so the next push doesn't redeploy it.
Rollback only swaps images; data in `ultradoc_data` is untouched (back up
first if the bad release may have written bad data).

## 5. Renew the TLS certificate

The self-signed cert is valid 365 days. Check expiry:

```bash
openssl x509 -enddate -noout -in /opt/ultradoc/certs/selfsigned.crt
```

Renew (pass the VM's IP so browsers match it), then let Terraform push the
new files into nginx (it replaces the nginx container in a few seconds):

```bash
cd ~/ultradoc-ai
CERT_DIR=/opt/ultradoc/certs scripts/gen-certs.sh <vm-ip>
cd terraform/docker
terraform apply -var "image_tag=$(cat /opt/ultradoc/state/current_tag)"
echo | openssl s_client -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -enddate
```

## 6. Reading logs

```bash
# Application containers (JSON logs from the API; add -f to follow)
docker logs --tail 100 ultradoc-api
docker logs --since 30m ultradoc-web
docker logs ultradoc-api 2>&1 | grep -i error

# nginx: access log goes to stdout, error log to stderr
docker logs --tail 50 ultradoc-nginx              # both
docker logs ultradoc-nginx 2>/dev/null | tail     # access only
docker logs ultradoc-nginx 2>&1 >/dev/null | tail # errors only
docker logs ultradoc-nginx 2>/dev/null | awk '$9 == 429' | tail   # rate-limited requests

# Ops scripts
tail -n 50 /opt/ultradoc/logs/healthcheck.log
tail -n 50 /opt/ultradoc/logs/backup.log

# System services
journalctl -u docker --since today
journalctl -u 'actions.runner.*' -f              # GitHub runner (deploys)
journalctl -u ssh --since "1 hour ago"
sudo fail2ban-client status sshd                 # banned IPs
sudo ufw status verbose
grep CRON /var/log/syslog | tail                 # did cron run the jobs?
```

## 7. Rotate the LLM API key

1. Create a new key in the Groq console.
2. Update the GitHub secret `LLM_API_KEY` (Settings → Secrets and variables → Actions).
3. Apply it now without waiting for a deploy:
   ```bash
   read -rs TF_VAR_llm_api_key && export TF_VAR_llm_api_key
   terraform apply -var "image_tag=$(cat /opt/ultradoc/state/current_tag)"
   ```
4. Revoke the old key in the Groq console.

The key exists only in the GitHub secret, the API container's environment and
the Terraform state file (`/opt/ultradoc/state`, mode `700`). It is never in
an image or in git.
