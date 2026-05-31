# rc-upgrade-cwp

Upgrade **Roundcube** to **1.7.x** on **CWP (Control Web Panel) + AlmaLinux 8**
without breaking the panel.

Roundcube 1.7 requires **PHP 8.1+**. CWP serves its panel *and* its bundled
Roundcube webmail through an **internal php71 (PHP 7.2)**. You cannot just
upgrade that PHP — the CWP panel itself is written for 7.x and will break, and a
CWP update would revert it anyway.

**The fix:** give Roundcube its **own dedicated php-fpm 8.3 pool + socket**, then
repoint **only the webmail nginx routes** at it. Panel, user panel, phpMyAdmin
stay on php71. Then upgrade the Roundcube files/DB and adjust routing for the new
1.6+ `public_html/` layout.

> Live-validated 2026-05-31 on a production CWP box: Roundcube **1.5.15 → 1.7.1**,
> CWP alt-php at `/opt/alt/php-fpm83`, panel untouched.

---

## CWP webmail architecture (why there are two routes to fix)

Roundcube lives at `/usr/local/cwpsrv/var/services/roundcube` and is exposed via
**two** independent paths — both must be fixed:

| Route | Served by | Config file | Notes |
|---|---|---|---|
| `cpanel.<domain>/roundcube`, `server.<domain>/roundcube` | cwpsrv :2031 | `/usr/local/cwpsrv/conf/cwp_services.conf` (`location /roundcube`) | subpath → nginx `alias` |
| `mail.<domain>/`, `webmail.<domain>/` | cwpsrv :2095 / :2096 | `/usr/local/cwpsrv/conf.d/webmail.conf` | main nginx `proxy_pass` → 127.0.0.1:2095 |

The php-fpm pool is **shared** (`cwpsvc.sock` = php71) across the panel, pma, and
webmail — so do **NOT** repoint the socket globally. Only the two webmail routes.

---

## Quick start

```bash
# get the script onto the server, then (if pasted from Windows):
sed -i 's/\r$//' rc-upgrade.sh && chmod +x rc-upgrade.sh

./rc-upgrade.sh detect      # confirm php8.3 CLI + extensions; changes nothing
./rc-upgrade.sh pool        # create dedicated php-fpm83 pool + /run/rc-php83.sock
./rc-upgrade.sh php-swap    # point webmail PHP -> 8.3 (docroot unchanged)
#   -> load webmail: your CURRENT Roundcube should still work, now on 8.3
./rc-upgrade.sh upgrade     # backup files+DB, download 1.7.x, installto, fix perms
./rc-upgrade.sh plugins     # trim incompatible plugins (carddav/calendar/tasklist)
./rc-upgrade.sh routing     # docroot -> public_html + static.php handling
#   -> load /roundcube AND mail. webmail: styled 1.7.x login on PHP 8.3
```

**Rollback any time:**
```bash
./rc-upgrade.sh restore        # dry-run: shows what it would restore
./rc-upgrade.sh restore --go   # restore files + DB + nginx configs from backups
```

Backups (auto): `/root/rc-upgrade-backups/` — files dir, DB dump, and timestamped
copies of every config edited.

### Order matters
- `php-swap` (socket only) is safe before upgrade — 1.5.x runs fine on 8.3. Good checkpoint.
- `routing` (docroot → `public_html`) is valid **only after** `upgrade` — 1.5.x has no `public_html/`.

### Env overrides
```bash
RC_VER=1.6.16 ./rc-upgrade.sh upgrade     # target a different release
RC_SOCK=/run/rc-php83.sock FPM_UNIT=php-fpm83 ./rc-upgrade.sh detect
SAFE_PLUGINS="'archive','zipdownload','managesieve','password'" ./rc-upgrade.sh plugins
```

---

## Gotchas we hit (so you don't, on the next server)

1. **CRLF** — script pasted from Windows fails with `bad interpreter: /bin/bash^M`.
   Fix: `sed -i 's/\r$//' rc-upgrade.sh`.
2. **DB password with special chars** (`@ # $ ,`) breaks naive DSN parsing. The
   script reads `db_dsnw` via PHP and writes a `0600` mysql `--defaults-extra-file`,
   so any password works. mysqldump aborts the run *before* any change if it fails.
3. **False "installto failed"** — `yes Y | php installto.sh` makes `yes` exit with
   SIGPIPE; with `set -o pipefail` that looks like failure even though installto
   printed `All done.` The script wraps it in `set +o pipefail` and checks the PHP
   exit code. If you ever see it manually: the upgrade *succeeded* — just run the
   post-steps (`chown -R cwpsvc:cwpsvc <rcdir>`, restart php-fpm83, reload cwpsrv).
4. **1.6+ `public_html/` layout** — top-level `index.php` is now a stub printing
   *"configure your HTTP server to point to /public_html"*. Docroot must move to
   `public_html` (handled by `routing`).
5. **Assets via `static.php/<path>`** — RC 1.7 serves all CSS/JS through
   `static.php` using PATH_INFO. The nginx php `location` must match `\.php(/|$)`
   (subpath: `...\.php(?<pathinfo>/.*)?$`) and pass `PATH_INFO`, else every asset
   404s → unstyled login page that also won't log in. Remove any `try_files $uri =404`.
6. **Incompatible plugins** — `installto` only updates RC's *own* bundled plugins.
   Third-party/CWP plugins (`carddav`, `calendar`, `tasklist`) bundle an old Guzzle
   and fatal with `Call to undefined method GuzzleHttp\Utils::chooseHandler()`
   ("Oops... something went wrong"). The `plugins` phase trims them out. Re-add only
   guzzle-7-compatible (current) builds later.
7. **Finding the real error** — RC's "Oops" page logs the fatal to the **cwpsrv
   error log** `/usr/local/cwpsrv/logs/error_log` (not always `roundcube/logs/errors.log`,
   which is usually drowned in `[1062] Duplicate entry session` bot-scanner noise).
8. **CWP updates may revert** `cwp_services.conf` / `webmail.conf`. The pool persists;
   just re-run `php-swap` + `routing` after a panel update. Keep this repo handy.

---

## Files

```
rc-upgrade.sh                              # the tool (detect|pool|php-swap|upgrade|plugins|routing|restore)
templates/
  roundcube-php83-pool.conf                # dedicated php-fpm 8.3 pool
  cwp_services-roundcube.block.conf         # corrected /roundcube subpath block (port 2031)
  webmail.conf                             # corrected :2095/:2096 webmail vhost
README.md
```

The templates are reference copies of what the script writes — drop them in by hand
if you prefer manual application, then `systemctl restart php-fpm83 && (systemctl reload cwpsrv || systemctl restart cwpsrv)`.

---

## Still TODO on the reference box (optional hardening)

- **fail2ban jail** on Roundcube auth + block the SQLi/XXE login scanners.
- **Pass the real client IP** to webmail — currently all hits log as `127.0.0.1`
  because cwpsrv proxies without forwarding the client IP, blinding brute-force
  protection. (Set `fastcgi_param REMOTE_ADDR` / trust `X-Forwarded-For` + RC
  `proxy_whitelist`.)
- **Re-add** carddav / calendar / tasklist using current (guzzle-7) plugin builds
  if contacts/calendar sync is needed.
