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
git clone https://github.com/wpexpertinbd/rc-upgrade-cwp /root/rc-upgrade-cwp
cd /root/rc-upgrade-cwp
./rc-upgrade.sh detect      # confirm php8.3 CLI + extensions; changes nothing
./rc-upgrade.sh all         # pool->php-swap->upgrade->plugins->routing->harden
```

`all` runs the whole sequence in order and **stops at the first failure** (each step
gets its own `cwpsrv -t` validation and its own `/root/rc-upgrade-<phase>-<ts>.log`).
Prefer to go step-by-step? Run them individually instead of `all`:

```bash
./rc-upgrade.sh pool        # dedicated php-fpm83 pool + /run/rc-php83.sock (+ ReadWritePaths drop-in)
./rc-upgrade.sh php-swap    # point webmail PHP -> 8.3 (docroot unchanged; checkpoint)
./rc-upgrade.sh upgrade     # backup files+DB, download 1.7.x, installto, fix perms
./rc-upgrade.sh plugins     # baseline plugin set (drops incompatible 3rd-party plugins)
./rc-upgrade.sh routing     # docroot -> public_html + static.php handling
./rc-upgrade.sh harden      # real client IP (proxy_whitelist) + login logging + fail2ban jail
```
(Pasted the script from Windows instead of cloning? `sed -i 's/\r$//' rc-upgrade.sh` first.)

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

## Optional: `harden` (real client IP + fail2ban) — and how it stays clear of bh-server-ops

By default the webmail scanners (SQLi/XXE login probes) all log as `127.0.0.1`,
because they arrive via the cwpsrv proxy on loopback. The `harden` phase fixes that:

1. **Real client IP (portable)** — sets Roundcube `$config['proxy_whitelist'] = ['127.0.0.1']`
   so RC trusts the loopback proxy's `X-Forwarded-For` and logs the real visitor IP.
   This works on **any** cwpsrv build. It *also* tries nginx `set_real_ip_from` as a
   bonus, but **only if `cwpsrv -t` passes** — some CWP cwpsrv builds lack the
   `realip` module (`unknown directive "set_real_ip_from"` → cwpsrv won't start), so
   if it's unsupported the script reverts that line automatically and relies on
   `proxy_whitelist`. (Real-IP logging still works either way.)
2. **Login logging** — sets `$config['log_logins'] = true;` so failed logins are
   recorded with the IP.
3. **fail2ban jail** — writes `filter.d/bh-roundcube.conf` + `jail.d/bh-roundcube.local`
   (jail name `[bh-roundcube]`) watching `roundcube/logs/errors.log` + `userlogins`.

```bash
./rc-upgrade.sh harden
```

### Why it does NOT conflict with [bh-server-ops](https://github.com/wpexpertinbd/bh-server-ops)

`bh-server-ops` hardens the **main** nginx (ports 80/443 customer sites): jails
`nginx-badbot` / `wp-login`, anti-bot maps in `/etc/nginx/bh.d/`. The webmail
attack surface is a different server (cwpsrv :2095/:2096/:2031) it never touches.
`harden` is deliberately isolated:

- only edits **cwpsrv's `webmail.conf`** — never `/etc/nginx/*` or the vhost `.stpl`
  templates that bh-server-ops manages;
- uses a **unique jail name** (`bh-roundcube`) and **separate files** under
  `filter.d/` + `jail.d/` — never creates/overwrites `jail.local`, so it **inherits**
  your existing `[DEFAULT]` (`bantime`, `ignoreip`, `banaction`);
- **does not install** fail2ban — if it's absent (i.e. you haven't run bh-server-ops
  yet) it skips the jail with a note; run `harden` again afterwards.

Run order: `harden` goes **after** `routing`. Safe to run on a box that already has
bh-server-ops applied.

---

## Repair after a CWP update

A CWP panel update can silently regenerate `cwp_services.conf` and `webmail.conf`,
reverting them to php71 + the old docroot (webmail breaks again). The fix is just
re-running the idempotent phases — no re-upgrade needed. Each phase backs up before
changing anything.

**Health check — see what broke (10s):**
```bash
echo -n "RC version : "; grep -oP "RCMAIL_VERSION'\s*,\s*'\K[^']+" /usr/local/cwpsrv/var/services/roundcube/program/include/iniset.php
echo -n "socket     : "; (ls /run/rc-php83.sock >/dev/null 2>&1 && echo present) || echo MISSING
echo "php targets:"; grep -h fastcgi_pass /usr/local/cwpsrv/conf.d/webmail.conf /usr/local/cwpsrv/conf/cwp_services.conf | sort -u
```

**Match the repair:**

| Symptom (from health check) | Command |
|---|---|
| Webmail stub/unstyled/php71, but RC=1.7.x and socket present (most common) | `./rc-upgrade.sh routing` |
| `socket: MISSING` (alt-php / php-fpm83 update wiped the pool) | `./rc-upgrade.sh pool` then `./rc-upgrade.sh routing` |
| `RC version` is NOT 1.7.x (CWP restored its bundled old Roundcube — rare) | `./rc-upgrade.sh upgrade` then `plugins` then `routing` |

**Rule of thumb:** after any CWP update, if webmail looks wrong → run
**`./rc-upgrade.sh routing`** first; if the socket is gone, run **`pool`** before it.

Keep this repo cloned at `/root/rc-upgrade-cwp` on each server so the repair is
always one command away:
```bash
git clone https://github.com/wpexpertinbd/rc-upgrade-cwp /root/rc-upgrade-cwp
chmod +x /root/rc-upgrade-cwp/rc-upgrade.sh
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
9. **Not every cwpsrv build has the `realip` module.** `set_real_ip_from` →
   `[emerg] unknown directive` → cwpsrv refuses to start. Worse, `systemctl reload`
   sends SIGHUP and returns `0` even when nginx **rejects** the config (it keeps the
   old one) — so the breakage stays hidden until the next *restart* bricks it. The
   script now validates with the cwpsrv binary's `-t` before reloading, and `harden`
   gets real-IP via Roundcube `proxy_whitelist` (portable) instead of depending on
   the nginx module.
10. **alt-php `ProtectSystem=full` makes `/usr` read-only for the pool.** Symptom:
   `file_put_contents(.../logs/errors.log): Failed to open stream: Read-only file
   system`. RC can't write logs/temp under the php-fpm pool, which silently breaks
   logging + fail2ban + attachments (core mail still works because sessions are in
   the DB). The `pool` phase fixes it with a systemd drop-in:
   `/etc/systemd/system/<fpm-unit>.service.d/roundcube-rw.conf` adding
   `ReadWritePaths=<roundcube dir>`. Check with
   `systemctl show <fpm-unit> -p ProtectSystem -p ReadWritePaths`.

---

## Files

```
rc-upgrade.sh                              # the tool (detect|pool|php-swap|upgrade|plugins|routing|restore)
templates/
  roundcube-php83-pool.conf                # dedicated php-fpm 8.3 pool
  cwp_services-roundcube.block.conf         # corrected /roundcube subpath block (port 2031)
  webmail.conf                             # corrected :2095/:2096 webmail vhost (+ real_ip)
  fail2ban/
    bh-roundcube.conf                      # filter.d/  - failed-login regex
    bh-roundcube.local                     # jail.d/    - isolated jail (harden phase)
README.md
```

The templates are reference copies of what the script writes — drop them in by hand
if you prefer manual application, then `systemctl restart php-fpm83 && (systemctl reload cwpsrv || systemctl restart cwpsrv)`.

---

## Optional extras

- **fail2ban jail + real client IP** — now handled by the `harden` phase (see above).
- **carddav** — ⚠️ **not viable on RC 1.7 via tarball** (incl. latest 5.1.3): the
  release tarball bundles its own Guzzle which clashes with RC 1.7's Guzzle 7
  (`GuzzleHttp\choose_handler()` fatal **after login** — the login page looks fine,
  so it's easy to miss). `addons carddav` now refuses by default and requires
  `--force`. Only re-enable once RCMCardDAV ships a 1.7-compatible build, ideally
  installed via **Composer** (single shared Guzzle), and verify by logging in.
  Revert instantly with `./rc-upgrade.sh plugins`.
- **calendar / tasklist** (Kolab plugins) are heavier and lag Roundcube releases —
  install a matching current build manually only if in-webmail calendar is needed.
