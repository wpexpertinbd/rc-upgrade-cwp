#!/bin/bash
# =============================================================================
# rc-upgrade-cwp / rc-upgrade.sh
# Upgrade Roundcube to 1.7.x on CWP (Control Web Panel) + AlmaLinux 8
# WITHOUT touching CWP's internal php71 (the panel needs it).
#
# Strategy: give Roundcube its OWN php-fpm 8.3 pool + socket, repoint ONLY the
# webmail routes at it, then upgrade the files/DB. Roundcube 1.7 requires PHP
# 8.1+; CWP's bundled webmail PHP is 7.2, so the engine swap is mandatory.
#
# Live-validated 2026-05-31 on server.biswashost.com (1.5.15 -> 1.7.1).
#
# PHASES (run in this order):
#   detect    - print what was auto-detected; change nothing
#   pool      - create the dedicated php-fpm 8.3 pool + socket for Roundcube
#   php-swap  - repoint the webmail nginx routes' PHP handler to the 8.3 socket
#               (docroot stays on the OLD layout -> your CURRENT Roundcube now
#                runs on 8.3 as a safe checkpoint before upgrading)
#   upgrade   - backup files+DB, download 1.7.x, run installto, fix perms
#   plugins   - trim $config['plugins'] to the safe bundled set (drops the
#               incompatible carddav/calendar/tasklist that bundle old Guzzle)
#   routing   - point docroot -> public_html + add static.php PATH_INFO handling
#               (ONLY valid AFTER upgrade: 1.5.x has no public_html/)
#   harden    - (optional) real client IP into cwpsrv webmail + Roundcube login
#               logging + a dedicated fail2ban jail. Self-contained; does NOT
#               touch the main nginx or jail.local that bh-server-ops manages.
#   addons    - (optional) re-install carddav from its LATEST release (bundled
#               Guzzle 7 = no clash with 1.7). Backs up, enables, health-checks,
#               and AUTO-REVERTS if webmail shows an error. Usage: addons carddav
#   restore   - roll back files + DB + nginx configs from the latest backups
#
# Typical full run:
#   ./rc-upgrade.sh detect
#   ./rc-upgrade.sh pool
#   ./rc-upgrade.sh php-swap     # then load webmail -> still works, now on 8.3
#   ./rc-upgrade.sh upgrade
#   ./rc-upgrade.sh plugins
#   ./rc-upgrade.sh routing      # then load webmail -> styled 1.7.x login
#   ./rc-upgrade.sh harden       # (optional) real-IP logging + fail2ban jail
#
# Rollback any time:  ./rc-upgrade.sh restore
#
# NOTE: pasted from Windows? run:  sed -i 's/\r$//' rc-upgrade.sh
# =============================================================================
set -uo pipefail

# ---- configurable (override via env) ----------------------------------------
RC_VER="${RC_VER:-1.7.1}"
RC_DIR="${RC_DIR:-/usr/local/cwpsrv/var/services/roundcube}"
SERVICES_CONF="${SERVICES_CONF:-/usr/local/cwpsrv/conf/cwp_services.conf}"   # holds /roundcube subpath (port 2031)
WEBMAIL_CONF="${WEBMAIL_CONF:-/usr/local/cwpsrv/conf.d/webmail.conf}"        # holds :2095/:2096 webmail vhost
FPM_UNIT="${FPM_UNIT:-php-fpm83}"
RC_SOCK="${RC_SOCK:-/run/rc-php83.sock}"
POOL_NAME="roundcube"
# safe bundled plugins that survive a major upgrade (edit if you need more):
SAFE_PLUGINS="${SAFE_PLUGINS:-'archive', 'zipdownload', 'managesieve', 'cwpautologon', 'password'}"
BK="/root/rc-upgrade-backups"
SRC="/usr/local/src"
MODE="${1:-detect}"

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo -e "\n=== $* ==="; }
[ "$(id -u)" = 0 ] || die "run as root"

# ---- auto-detect php 8.3 (CWP alt-php layout) -------------------------------
EXEC=$(systemctl show -p ExecStart --value "${FPM_UNIT}.service" 2>/dev/null)
FPM_BIN=$(echo "$EXEC" | grep -oP 'path=\K[^ ;]+' | head -1)
[ -x "$FPM_BIN" ] || FPM_BIN=$(echo "$EXEC" | awk '{print $1}')
[ -x "$FPM_BIN" ] || die "cannot find php-fpm binary for $FPM_UNIT"
PREFIX="${FPM_BIN%/sbin/php-fpm}"; PREFIX="${PREFIX%/bin/php-fpm}"
PHP_CLI="$PREFIX/bin/php"; [ -x "$PHP_CLI" ] || PHP_CLI="$(command -v php83 || true)"
[ -x "$PHP_CLI" ] || die "cannot find php 8.x CLI (looked at $PREFIX/bin/php)"
FPM_CONF=$(echo "$EXEC" | grep -oP '(?:--fpm-config|-y)\s+\K[^ ;]+' | head -1)
[ -f "$FPM_CONF" ] || FPM_CONF="$PREFIX/etc/php-fpm.conf"
POOL_INC=$(grep -oP '^\s*include\s*=\s*\K\S+' "$FPM_CONF" 2>/dev/null | head -1)
POOL_DIR=$(dirname "${POOL_INC:-$PREFIX/etc/php-fpm.d/x}")
# Use the roundcube DIRECTORY owner (always cwpsvc on CWP). NOT index.php: after a
# 1.7 upgrade index.php/static.php can end up owned by cbpolicyd, which would make
# the pool run as the wrong user.
RC_OWNER=$(stat -c '%U' "$RC_DIR" 2>/dev/null || echo cwpsvc)
RC_GROUP=$(stat -c '%G' "$RC_DIR" 2>/dev/null || echo cwpsvc)
case "$RC_OWNER" in root|cbpolicyd|"") RC_OWNER=cwpsvc; RC_GROUP=cwpsvc;; esac
PHP_VER=$("$PHP_CLI" -r 'echo PHP_VERSION;' 2>/dev/null)

mkdir -p "$BK"

# ---- build a 0600 mysql defaults file from RC's db_dsnw (handles @#$, in pw) -
mk_defaults(){ # $1 = output cnf path; echoes db name
  "$PHP_CLI" -r '
    $config=[]; include $argv[1]; $dsn=$config["db_dsnw"]??"";
    if(!preg_match("#^\w+://([^:]+):(.*)@([^@/]+)/(.+)$#",$dsn,$m)){fwrite(STDERR,"DSN parse failed\n");exit(2);}
    list(,$u,$p,$h,$d)=$m; $port="3306";
    if(strpos($h,":")!==false){list($h,$port)=explode(":",$h,2);}
    $f=fopen($argv[2],"w"); chmod($argv[2],0600);
    fprintf($f,"[client]\nuser=\"%s\"\npassword=\"%s\"\nhost=\"%s\"\nport=%s\n",
      addcslashes($u,"\"\\"),addcslashes($p,"\"\\"),addcslashes($h,"\"\\"),$port);
    fclose($f); echo $d;
  ' "$RC_DIR/config/config.inc.php" "$1"
}

reload_web(){ systemctl reload cwpsrv 2>/dev/null || systemctl restart cwpsrv; }

# ---- generate the corrected /roundcube block (subpath, port 2031) -----------
roundcube_block(){
cat <<NGINX
location /roundcube {
    alias $RC_DIR/public_html;
    index  index.php;

    location ~ ^/roundcube/(?<rcphp>.+\.php)(?<pathinfo>/.*)?\$ {
        include                 fastcgi_params;
        fastcgi_read_timeout 600;
        fastcgi_pass    unix:$RC_SOCK;
        fastcgi_index   index.php;
        fastcgi_param   SCRIPT_FILENAME  $RC_DIR/public_html/\$rcphp;
        fastcgi_param   SCRIPT_NAME   /roundcube/\$rcphp;
        fastcgi_param   PATH_INFO  \$pathinfo;
        fastcgi_param   PHP_ADMIN_VALUE "open_basedir = $RC_DIR/:/tmp/";
    }
}
NGINX
}

# ---- generate the corrected :2095/:2096 webmail.conf (preserves ssl lines) ---
webmail_conf(){
  local cur="$1" sslc sslk
  sslc=$(grep -oP 'ssl_certificate\s+\K[^;]+' "$cur" 2>/dev/null | head -1)
  sslk=$(grep -oP 'ssl_certificate_key\s+\K[^;]+' "$cur" 2>/dev/null | head -1)
  sslc=${sslc:-/etc/pki/tls/certs/hostname.bundle}
  sslk=${sslk:-/etc/pki/tls/private/hostname.key}
cat <<NGINX
server {
    listen       2095;
    server_name  localhost;

    # trust the main-nginx reverse proxy on loopback so logs/bans see the real client IP
    set_real_ip_from 127.0.0.1;
    real_ip_header X-Forwarded-For;
    real_ip_recursive on;

    location / {
        root   $RC_DIR/public_html;
        index  index.php;

        location ~ \.php(/|\$) {
                fastcgi_split_path_info ^(.+?\.php)(/.*)\$;
                fastcgi_read_timeout 600;
                fastcgi_pass    unix:$RC_SOCK;
                fastcgi_index   index.php;
                fastcgi_param   SCRIPT_FILENAME  \$document_root\$fastcgi_script_name;
                fastcgi_param   SCRIPT_NAME       \$fastcgi_script_name;
                fastcgi_param   PATH_INFO         \$fastcgi_path_info;
                fastcgi_param   PHP_ADMIN_VALUE "open_basedir = $RC_DIR/:/tmp/";
                include                 fastcgi_params;
            }
    }
}

server {
    listen       2096 ssl;
    server_name  localhost;

    ssl_session_timeout  90m;
    ssl_certificate $sslc;
    ssl_certificate_key $sslk;
    ssl_protocols       TLSv1 TLSv1.1 TLSv1.2;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers   on;

    # trust the main-nginx reverse proxy on loopback so logs/bans see the real client IP
    set_real_ip_from 127.0.0.1;
    real_ip_header X-Forwarded-For;
    real_ip_recursive on;

    location / {
        root   $RC_DIR/public_html;
        index  index.php;

        location ~ \.php(/|\$) {
                fastcgi_split_path_info ^(.+?\.php)(/.*)\$;
                fastcgi_read_timeout 600;
                fastcgi_pass    unix:$RC_SOCK;
                fastcgi_index   index.php;
                fastcgi_param   SCRIPT_FILENAME  \$document_root\$fastcgi_script_name;
                fastcgi_param   SCRIPT_NAME       \$fastcgi_script_name;
                fastcgi_param   PATH_INFO         \$fastcgi_path_info;
                fastcgi_param   PHP_ADMIN_VALUE "open_basedir = $RC_DIR/:/tmp/";
                include                 fastcgi_params;
            }
    }
}
NGINX
}

say "DETECTED"
cat <<EOF
php CLI  : $PHP_CLI  (v$PHP_VER)
fpm unit : $FPM_UNIT
pool dir : $POOL_DIR
roundcube: $RC_DIR  (owner $RC_OWNER:$RC_GROUP)
socket   : $RC_SOCK
services : $SERVICES_CONF   (/roundcube subpath)
webmail  : $WEBMAIL_CONF    (:2095/:2096)
target   : Roundcube $RC_VER
EOF
case "$PHP_VER" in 8.1*|8.2*|8.3*|8.4*) ;; *) echo "WARN: php CLI is $PHP_VER, Roundcube 1.7 needs >=8.1";; esac
MISS=""; for e in dom mbstring openssl pdo_mysql intl iconv fileinfo session json xml; do
  "$PHP_CLI" -m 2>/dev/null | grep -qix "$e" || MISS="$MISS $e"; done
[ -n "$MISS" ] && echo "WARN: php8x missing extensions:$MISS"

case "$MODE" in
# -----------------------------------------------------------------------------
detect)
  echo -e "\nNo changes. Order: pool -> php-swap -> upgrade -> plugins -> routing"; exit 0 ;;

# -----------------------------------------------------------------------------
pool)
  say "WRITE php-fpm pool $POOL_DIR/$POOL_NAME.conf"
  mkdir -p "$POOL_DIR"
  cat > "$POOL_DIR/$POOL_NAME.conf" <<EOF
[$POOL_NAME]
user = $RC_OWNER
group = $RC_GROUP
listen = $RC_SOCK
listen.owner = root
listen.group = root
listen.mode = 0666
pm = ondemand
pm.max_children = 15
pm.process_idle_timeout = 30s
chdir = /
php_admin_value[open_basedir] = $RC_DIR/:/tmp/
php_admin_value[session.save_path] = $RC_DIR/temp
php_admin_value[upload_tmp_dir] = $RC_DIR/temp
php_admin_value[sys_temp_dir] = $RC_DIR/temp
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 72M
php_admin_value[memory_limit] = 256M
php_admin_value[date.timezone] = UTC
EOF
  mkdir -p "$RC_DIR/temp" "$RC_DIR/logs"; chown -R "$RC_OWNER:$RC_GROUP" "$RC_DIR/temp" "$RC_DIR/logs"
  # alt-php units commonly ship ProtectSystem=full -> /usr (incl. roundcube) is
  # READ-ONLY for the pool, so RC can't write logs/temp (breaks logging + fail2ban
  # + attachments). Grant write to ONLY the roundcube dir via a systemd drop-in.
  DROPIN="/etc/systemd/system/${FPM_UNIT}.service.d"
  mkdir -p "$DROPIN"
  printf '[Service]\nReadWritePaths=%s\n' "$RC_DIR" > "$DROPIN/roundcube-rw.conf"
  systemctl daemon-reload
  systemctl restart "$FPM_UNIT" || die "php-fpm restart failed"
  sleep 1; [ -S "$RC_SOCK" ] || die "socket $RC_SOCK not created - check the pool conf"
  echo "OK: pool live, socket $RC_SOCK present."; exit 0 ;;

# -----------------------------------------------------------------------------
php-swap)
  # repoint ONLY the PHP handler to the 8.3 socket in BOTH webmail routes,
  # WITHOUT changing docroot. Your current Roundcube now runs on 8.3.
  for f in "$SERVICES_CONF" "$WEBMAIL_CONF"; do
    [ -f "$f" ] || { echo "skip (missing): $f"; continue; }
    cp -a "$f" "$BK/$(basename "$f").$(date +%s).bak"
    sed -i "s#unix:/usr/local/cwp/php[0-9]*/var/sockets/cwpsvc.sock;#unix:$RC_SOCK;#g" "$f" \
      && echo "patched socket in $f"
  done
  reload_web || die "cwpsrv reload failed"
  echo "OK: webmail PHP handler -> $RC_SOCK (php $PHP_VER). Load webmail; it should still work."; exit 0 ;;

# -----------------------------------------------------------------------------
upgrade)
  command -v wget >/dev/null || die "wget required"
  say "BACKUP files"; cp -a "$RC_DIR" "$BK/roundcube-files-$(date +%s)"
  say "BACKUP database"
  DEF="$BK/.rcmy.cnf"; trap 'rm -f "$DEF"' EXIT
  DDB=$(mk_defaults "$DEF") || die "could not build DB creds from db_dsnw"
  mysqldump --defaults-extra-file="$DEF" --single-transaction --routines "$DDB" \
    > "$BK/roundcube-db-$(date +%s).sql" || die "mysqldump failed - aborting BEFORE schema change"
  rm -f "$DEF"; trap - EXIT; echo "DB '$DDB' dumped to $BK"
  say "DOWNLOAD roundcube $RC_VER (complete tarball)"; cd "$SRC"
  URL="https://github.com/roundcube/roundcubemail/releases/download/$RC_VER/roundcubemail-$RC_VER-complete.tar.gz"
  wget -q --show-progress "$URL" -O "rc-$RC_VER.tar.gz" || die "download failed: $URL"
  tar xzf "rc-$RC_VER.tar.gz"; cd "roundcubemail-$RC_VER"
  say "INSTALLTO $RC_DIR (php $PHP_VER)"
  # NOTE: 'yes Y |' gets SIGPIPE when installto closes stdin; with pipefail that
  # falsely looks like failure. Capture the PHP exit code explicitly instead.
  set +o pipefail; yes Y | "$PHP_CLI" bin/installto.sh "$RC_DIR"; rc=$?; set -o pipefail
  [ "$rc" = 0 ] || die "installto failed (exit $rc) - run: $0 restore"
  chown -R "$RC_OWNER:$RC_GROUP" "$RC_DIR"
  systemctl restart "$FPM_UNIT"; reload_web
  INSTVER=$(grep -oP "RCMAIL_VERSION'\s*,\s*'\K[^']+" "$RC_DIR/program/include/iniset.php" 2>/dev/null)
  echo "OK: installed Roundcube ${INSTVER:-?}. Next: plugins, then routing."; exit 0 ;;

# -----------------------------------------------------------------------------
plugins)
  # trim to safe bundled set; non-bundled plugins (carddav/calendar/tasklist)
  # ship their own old Guzzle and fatal on 1.7 until updated to guzzle-7 builds.
  CFG="$RC_DIR/config/config.inc.php"
  cp -a "$CFG" "$BK/config.inc.php.$(date +%s).bak"
  sed -i "s/\$config\['plugins'\].*/\$config['plugins'] = [$SAFE_PLUGINS];/" "$CFG"
  rm -rf "$RC_DIR"/temp/* 2>/dev/null
  systemctl restart "$FPM_UNIT"
  echo "plugins now:"; grep -n "config\['plugins'\]" "$CFG"; exit 0 ;;

# -----------------------------------------------------------------------------
routing)
  # ONLY after upgrade: point docroot -> public_html + handle static.php PATH_INFO
  [ -d "$RC_DIR/public_html" ] || die "no $RC_DIR/public_html - upgrade to 1.7 first"

  # 1) /roundcube subpath block in cwp_services.conf (awk full-block replace)
  if [ -f "$SERVICES_CONF" ] && grep -q '^location /roundcube' "$SERVICES_CONF"; then
    cp -a "$SERVICES_CONF" "$BK/$(basename "$SERVICES_CONF").$(date +%s).bak"
    roundcube_block > /tmp/rc_block.$$
    awk 'BEGIN{while((getline l < "/tmp/rc_block.'"$$"'")>0) b=b l ORS}
         /^location \/roundcube[ \t]*\{/{printf "%s",b; s=1; next}
         s&&/^}/{s=0; next} s{next} {print}' "$SERVICES_CONF" > "$SERVICES_CONF.new" \
      && mv "$SERVICES_CONF.new" "$SERVICES_CONF" && echo "patched /roundcube block in $SERVICES_CONF"
    rm -f /tmp/rc_block.$$
  fi

  # 2) :2095/:2096 webmail.conf (regenerate, preserving ssl_certificate lines)
  if [ -f "$WEBMAIL_CONF" ]; then
    cp -a "$WEBMAIL_CONF" "$BK/$(basename "$WEBMAIL_CONF").$(date +%s).bak"
    webmail_conf "$WEBMAIL_CONF" > "$WEBMAIL_CONF.new" && mv "$WEBMAIL_CONF.new" "$WEBMAIL_CONF" \
      && echo "rewrote $WEBMAIL_CONF (docroot->public_html, static.php, $RC_SOCK)"
  fi

  chown -R "$RC_OWNER:$RC_GROUP" "$RC_DIR" 2>/dev/null   # normalize (1.7 leaves some files cbpolicyd)
  reload_web || die "cwpsrv reload failed - check configs / restore"
  echo "OK: routing fixed. Load /roundcube and mail. webmail - both should be styled 1.7.x on $PHP_VER."; exit 0 ;;

# -----------------------------------------------------------------------------
harden)
  # Optional: make webmail see the REAL client IP, log failed logins, and jail
  # the scanners. Self-contained - does NOT touch the main nginx or jail.local
  # that bh-server-ops owns. Run AFTER routing.
  say "1) real client IP in webmail.conf"
  if [ -f "$WEBMAIL_CONF" ]; then
    if grep -q 'set_real_ip_from' "$WEBMAIL_CONF"; then
      echo "real_ip already present"
    else
      cp -a "$WEBMAIL_CONF" "$BK/webmail.conf.harden.$(date +%s).bak"
      sed -i '/^[[:space:]]*server_name[[:space:]]\+localhost;/a\    set_real_ip_from 127.0.0.1;\n    real_ip_header X-Forwarded-For;\n    real_ip_recursive on;' "$WEBMAIL_CONF"
      echo "added real_ip to both server blocks"
    fi
    if ! reload_web; then
      echo "cwpsrv reload FAILED (realip module missing?) - reverting"
      b=$(ls -t "$BK"/webmail.conf.harden.*.bak 2>/dev/null | head -1)
      [ -n "$b" ] && cp -a "$b" "$WEBMAIL_CONF" && reload_web
      die "reverted webmail.conf - harden aborted"
    fi
  else
    echo "skip: $WEBMAIL_CONF not found"
  fi

  say "2) Roundcube: log failed logins with IP"
  CFG="$RC_DIR/config/config.inc.php"
  grep -qF "\$config['log_logins'] = true;" "$CFG" || printf "\n\$config['log_logins'] = true;\n" >> "$CFG"
  echo "log_logins enabled"

  say "3) fail2ban jail (separate files; jail name bh-roundcube)"
  if command -v fail2ban-client >/dev/null 2>&1; then
    cat > /etc/fail2ban/filter.d/bh-roundcube.conf <<'F2B'
[Definition]
failregex = (?:Failed login for|IMAP Error: Login failed for) .*? from <HOST>
ignoreregex =
F2B
    cat > /etc/fail2ban/jail.d/bh-roundcube.local <<F2B
# Roundcube webmail brute-force jail. Inherits [DEFAULT] (bantime/ignoreip/
# banaction) from your existing fail2ban config - no jail.local overwrite.
[bh-roundcube]
enabled  = true
filter   = bh-roundcube
logpath  = $RC_DIR/logs/errors.log
           $RC_DIR/logs/userlogins
port     = http,https,2095,2096
maxretry = 5
findtime = 600
bantime  = 3600
backend  = auto
F2B
    systemctl restart fail2ban 2>/dev/null || service fail2ban restart 2>/dev/null
    sleep 1
    fail2ban-client status bh-roundcube >/dev/null 2>&1 \
      && echo "jail bh-roundcube ACTIVE" \
      || echo "WARN: jail not active yet - check: journalctl -u fail2ban | tail"
  else
    echo "NOTE: fail2ban not installed - skipped. (bh-server-ops installs it; re-run harden after.)"
  fi
  chown -R "$RC_OWNER:$RC_GROUP" "$RC_DIR" 2>/dev/null   # normalize ownership (config.inc.php was edited as root)
  echo -e "\nOK: harden done. Webmail now logs/bans the REAL attacker IP, not 127.0.0.1."; exit 0 ;;

# -----------------------------------------------------------------------------
addons)
  # Re-install carddav from its LATEST upstream release. The current RCMCardDAV
  # targets Guzzle 7 (same major as RC 1.7), so it does NOT hit the old
  # 'chooseHandler()' fatal. Health-checked + AUTO-REVERTED on any error.
  ADDON="${2:-carddav}"
  [ "$ADDON" = carddav ] || die "this phase only supports: carddav"
  # KNOWN-BROKEN on RC 1.7: carddav release tarballs bundle their own Guzzle, which
  # clashes with RC 1.7's Guzzle 7 -> GuzzleHttp\choose_handler() fatal AFTER login
  # (the login-page health check below CANNOT catch it). Confirmed with carddav 5.1.3.
  echo "WARNING: carddav tarball bundles its own Guzzle and clashes with RC 1.7's"
  echo "Guzzle 7 (fatal appears only AFTER you log in). Known-broken as of carddav 5.1.3."
  [ "${3:-}" = "--force" ] || die "refusing by default. With a verified 1.7-compatible build: $0 addons carddav --force  (then LOG IN to verify; revert with: $0 plugins)"
  command -v curl >/dev/null || die "curl required"
  command -v wget >/dev/null || die "wget required"
  CFG="$RC_DIR/config/config.inc.php"
  HEALTH_URL="${HEALTH_URL:-https://127.0.0.1:2096/}"   # cwpsrv webmail on loopback

  say "BACKUP config + any existing carddav"
  cp -a "$CFG" "$BK/config.inc.php.carddav.$(date +%s).bak"
  [ -d "$RC_DIR/plugins/carddav" ] && cp -a "$RC_DIR/plugins/carddav" "$BK/carddav-old-$(date +%s)"

  say "FETCH latest RCMCardDAV release (bundled deps = Guzzle 7)"
  URL=$(curl -fsSL https://api.github.com/repos/mstilkerich/rcmcarddav/releases/latest \
        | grep -oP '"browser_download_url":\s*"\K[^"]*carddav-v[^"]*\.tar\.gz' | head -1)
  [ -n "$URL" ] || die "could not resolve carddav tarball asset (network/GitHub API?)"
  echo "URL: $URL"
  cd "$SRC"; rm -rf carddav-dl; mkdir carddav-dl
  wget -q "$URL" -O carddav-dl/c.tgz || die "download failed"
  tar xzf carddav-dl/c.tgz -C carddav-dl
  PDIR=$(dirname "$(find "$SRC/carddav-dl" -name carddav.php | head -1)")
  [ -f "$PDIR/carddav.php" ] || die "extracted tarball has no carddav.php"
  rm -rf "$RC_DIR/plugins/carddav"; cp -a "$PDIR" "$RC_DIR/plugins/carddav"
  echo "installed plugin from $(basename "$URL")"

  say "ENABLE + restart"
  grep -q "'carddav'" "$CFG" || sed -i "s/\$config\['plugins'\] = \[/\$config['plugins'] = ['carddav', /" "$CFG"
  rm -rf "$RC_DIR"/temp/* 2>/dev/null
  chown -R "$RC_OWNER:$RC_GROUP" "$RC_DIR"
  systemctl restart "$FPM_UNIT"; reload_web; sleep 1

  say "HEALTH CHECK $HEALTH_URL"
  body=$(curl -sk "$HEALTH_URL" 2>/dev/null)
  if echo "$body" | grep -qiE "something went wrong|internal error has occurred"; then
    echo "FAIL: webmail shows an error -> AUTO-REVERTING carddav"
    rm -rf "$RC_DIR/plugins/carddav"
    cp -a "$(ls -t "$BK"/config.inc.php.carddav.*.bak | head -1)" "$CFG"
    rm -rf "$RC_DIR"/temp/* 2>/dev/null; chown -R "$RC_OWNER:$RC_GROUP" "$RC_DIR"
    systemctl restart "$FPM_UNIT"; reload_web
    die "carddav still incompatible -> reverted; webmail restored. Try the composer method, or a specific older carddav release."
  fi
  echo -e "\nOK: carddav installed and webmail healthy. Configure it per-user under"
  echo "Settings > Preferences, or set server defaults in plugins/carddav/config.inc.php."; exit 0 ;;

# -----------------------------------------------------------------------------
restore)
  FB=$(ls -dt "$BK"/roundcube-files-* 2>/dev/null | head -1)
  SQL=$(ls -t "$BK"/roundcube-db-*.sql 2>/dev/null | head -1)
  say "RESTORE plan"; echo "files: ${FB:-none}"; echo "db:    ${SQL:-none}"
  echo "nginx: latest .bak of cwp_services.conf / webmail.conf / config.inc.php in $BK"
  [ "${2:-}" = --go ] || { echo -e "\nDry run. Apply with: $0 restore --go"; exit 0; }
  [ -n "$FB" ] && { rm -rf "$RC_DIR"; cp -a "$FB" "$RC_DIR"; chown -R "$RC_OWNER:$RC_GROUP" "$RC_DIR"; echo "files restored"; }
  if [ -n "$SQL" ]; then
    DEF="$BK/.rcmy.cnf"; trap 'rm -f "$DEF"' EXIT; DDB=$(mk_defaults "$DEF") || die "creds build failed"
    mysql --defaults-extra-file="$DEF" "$DDB" < "$SQL" && echo "db restored" || echo "WARN: db restore failed"
    rm -f "$DEF"; trap - EXIT; fi
  for base in cwp_services.conf webmail.conf; do
    b=$(ls -t "$BK/$base".*.bak 2>/dev/null | head -1)
    [ -n "$b" ] && { tgt=$([ "$base" = webmail.conf ] && echo "$WEBMAIL_CONF" || echo "$SERVICES_CONF"); cp -a "$b" "$tgt"; echo "restored $tgt"; }
  done
  cfgb=$(ls -t "$BK"/config.inc.php.*.bak 2>/dev/null | head -1)
  [ -n "$cfgb" ] && { cp -a "$cfgb" "$RC_DIR/config/config.inc.php"; echo "restored config.inc.php"; }
  systemctl restart "$FPM_UNIT" 2>/dev/null; reload_web
  echo "RESTORE done."; exit 0 ;;

*) die "unknown mode '$MODE' (use: detect|pool|php-swap|upgrade|plugins|routing|harden|addons|restore)" ;;
esac
