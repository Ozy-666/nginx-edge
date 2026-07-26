#!/bin/bash
set -e

BUILD_DIR="/root/nginx-build"
NGINX_URL="https://nginx.org/download"
CORES=4
DATE=$(date +%Y%m%d_%H%M%S)

echo -e "\033[1;34m[+] Starting Enterprise Nginx Auto-Update (BoringSSL, Brotli, Zen 2)\033[0m"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# 1. Back up the current state (binary + config) before touching anything
echo -e "\033[1;33m[*] Creating backups...\033[0m"
if [ -f /usr/sbin/nginx ]; then
    cp -a /usr/sbin/nginx "/usr/sbin/nginx.backup.${DATE}"
    echo -e "\033[1;32m[+] Binary backed up to /usr/sbin/nginx.backup.${DATE}\033[0m"
fi
if [ -d /etc/nginx ]; then
    tar -czf "/root/nginx-build/nginx_conf_backup_${DATE}.tar.gz" /etc/nginx/
    echo -e "\033[1;32m[+] Config backed up to /root/nginx-build/nginx_conf_backup_${DATE}.tar.gz\033[0m"
fi

# 2. Update ngx_brotli and its submodules
echo -e "\033[1;33m[*] Updating ngx_brotli...\033[0m"
if [ ! -d "ngx_brotli" ]; then
    git clone --recursive https://github.com/google/ngx_brotli.git
else
    cd ngx_brotli
    git reset --hard HEAD
    git checkout master
    git pull origin master
    git submodule update --init --recursive --remote
    cd ..
fi

# 3. BoringSSL for nginx — DEDICATED dir (boringssl-nginx), separate from the
# shared ./boringssl used with unbound. Grabs the LATEST tagged BoringSSL
# release from GitHub automatically (Google tags often), so there is no pin to
# maintain. Freshness over strict reproducibility, by choice: the pre-install
# build + `nginx -t` gate below means a release that breaks the server-side ECH
# patch (ech-boringssl.patch: SSL_ECH_KEYS_*/EVP_HPKE_KEY_*) aborts safely
# without ever touching the running binary.
BORING_DIR="boringssl-nginx"
BORING_REPO="https://github.com/google/boringssl"
echo -e "\033[1;33m[*] Resolving latest BoringSSL release tag...\033[0m"
BORING_TAG=$(git ls-remote --tags --sort=-v:refname "$BORING_REPO" 2>/dev/null \
    | grep -oE 'refs/tags/[0-9]+\.[0-9]+\.[0-9]+$' | sed 's#refs/tags/##' | head -n1)
if [ -z "$BORING_TAG" ]; then
    echo -e "\033[1;31m[-] Could not resolve a BoringSSL release tag — abort\033[0m"; exit 1
fi
echo -e "\033[1;32m[+] Latest BoringSSL release: ${BORING_TAG}\033[0m"
if [ ! -d "$BORING_DIR/.git" ]; then
    git clone --depth 1 --branch "$BORING_TAG" "$BORING_REPO" "$BORING_DIR"
    cd "$BORING_DIR"
else
    cd "$BORING_DIR"
    git remote set-url origin "$BORING_REPO" 2>/dev/null || true
    git fetch --depth 1 origin "refs/tags/${BORING_TAG}:refs/tags/${BORING_TAG}" 2>/dev/null \
        || git fetch --tags --depth 1 origin 2>/dev/null || true
    git checkout -q -f "$BORING_TAG" 2>/dev/null || true
fi
echo -e "\033[1;32m[+] BoringSSL (nginx) at $(git describe --tags 2>/dev/null || git rev-parse --short HEAD)\033[0m"
# Clean build dir: clears any prior BUILD_SHARED_LIBS cache so we get STATIC .a
# (the shared .so build for unbound lives in /opt/boring; nginx needs libssl.a/libcrypto.a)
rm -rf build && mkdir build && cd build
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release ..
ninja -j"$CORES" crypto ssl bssl
ls libssl.a libcrypto.a >/dev/null || { echo "BoringSSL static libs missing — abort"; exit 1; }
cd "$BUILD_DIR"

# 4. Download the latest nginx mainline release
echo -e "\033[1;33m[*] Fetching latest Nginx mainline version...\033[0m"
LATEST_NGINX=$(curl -sL https://nginx.org/en/download.html | grep -oP 'nginx-\K1\.[0-9]+\.[0-9]+' | head -n 1)

if [ -z "$LATEST_NGINX" ]; then
    echo -e "\033[1;31m[-] Failed to fetch Nginx version.\033[0m"
    exit 1
fi

echo -e "\033[1;32m[+] Target Nginx version: $LATEST_NGINX\033[0m"

# nginx.org publishes a detached PGP signature (.asc) for every release but does
# NOT publish a .sha256 — so unlike the unbound scripts, PGP is the only integrity
# check available and it is therefore FATAL rather than best-effort.
#
# Keys are fetched from https://nginx.org/keys/ and accepted only if their
# fingerprint is in the pinned allowlist below, so a compromised keys page cannot
# introduce a new signer. Import happens into a throwaway keyring under the build
# dir — root's real GNUPGHOME is never touched.
#
# Refresh the list from https://nginx.org/en/pgp_keys.html when nginx adds a
# maintainer; an unknown signer is treated as a failure, not a warning.
NGINX_KEY_FPRS=(
    43387825DDB1BB97EC36BA5D007C8D7C15D87369  # Roman Arutyunyan   <r.arutyunyan@f5.com>  (signed 1.31.3)
    D6786CE303D9A9022998DC6CC8464D549AF75C0A  # Sergey Kandaurov   <s.kandaurov@f5.com>
    7338973069ED3F443F4D37DFA64FD5B17ADB39A8  # Sergey Budnevitch  <sb@waeme.net>
    13C82A63B603576156E30A4EA0EA981B66B0D967  # Konstantin Pavlov  <thresh@nginx.com>
    573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62  # nginx signing key  <signing-key@nginx.com>
    8540A6F18833A80E9C1653A42FD21310B49F6B46  # nginx signing key  <signing-key-2@nginx.com>
    9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3  # nginx signing key  <signing-key-3@nginx.com>
)

verify_nginx_tarball() {
    local tarball="$1" version="$2"
    local keyring="${BUILD_DIR}/.nginx-keyring"

    if [ "${NGINX_SKIP_PGP:-0}" = "1" ]; then
        echo -e "\033[1;31m[!] NGINX_SKIP_PGP=1 — tarball signature NOT verified\033[0m"
        return 0
    fi
    command -v gpg >/dev/null 2>&1 || {
        echo -e "\033[1;31m[-] gpg not installed — cannot verify tarball. Install gnupg, or re-run with NGINX_SKIP_PGP=1 to accept the risk.\033[0m"
        return 1; }

    echo -e "\033[1;33m[*] Verifying PGP signature...\033[0m"
    curl -fsSL --max-time 60 -o "${tarball}.asc" "${NGINX_URL}/nginx-${version}.tar.gz.asc" || {
        echo -e "\033[1;31m[-] Could not download the .asc signature — abort\033[0m"; return 1; }

    # Throwaway keyring, rebuilt from scratch each run.
    rm -rf "$keyring"; mkdir -p "$keyring"; chmod 700 "$keyring"

    local imported=0 fpr keyfile
    for keyfile in arut pluknet sb thresh nginx_signing; do
        curl -fsSL --max-time 30 -o "${keyring}/${keyfile}.key" \
            "https://nginx.org/keys/${keyfile}.key" 2>/dev/null || continue
        # Accept the key only if EVERY primary fingerprint it carries is pinned.
        local rejected=0
        while read -r fpr; do
            [ -z "$fpr" ] && continue
            printf '%s\n' "${NGINX_KEY_FPRS[@]}" | grep -qx "$fpr" || {
                echo -e "\033[1;31m[!] Unpinned key on nginx.org/keys/${keyfile}.key: ${fpr} — refusing to import\033[0m"
                rejected=1; }
        done < <(gpg --homedir "$keyring" --with-colons --import-options show-only \
                     --import "${keyring}/${keyfile}.key" 2>/dev/null \
                 | awk -F: '/^fpr:/{print $10}' | head -1)
        [ "$rejected" -eq 1 ] && continue
        gpg --homedir "$keyring" --quiet --batch --import "${keyring}/${keyfile}.key" 2>/dev/null \
            && imported=$((imported + 1))
    done
    [ "$imported" -gt 0 ] || {
        echo -e "\033[1;31m[-] No trusted nginx signing keys could be imported — abort\033[0m"; return 1; }

    local gpg_out
    gpg_out=$(gpg --homedir "$keyring" --status-fd 1 --verify \
                  "${tarball}.asc" "$tarball" 2>/dev/null) || {
        echo -e "\033[1;31m[-] PGP VERIFICATION FAILED — the tarball is NOT what nginx published. Aborting.\033[0m"
        echo "$gpg_out"; return 1; }

    # A good signature is not enough: confirm the signer is one of the pinned keys.
    local signer
    signer=$(printf '%s\n' "$gpg_out" | awk '/VALIDSIG/{print $3; exit}')
    printf '%s\n' "${NGINX_KEY_FPRS[@]}" | grep -qx "$signer" || {
        echo -e "\033[1;31m[-] Good signature, but from an UNPINNED key ${signer} — abort\033[0m"; return 1; }

    echo -e "\033[1;32m[+] PGP verified — signed by ${signer}\033[0m"
    rm -rf "$keyring"
    return 0
}

# Only a freshly downloaded tarball is verified; an already-extracted tree is left
# alone so a re-run does not clobber the applied ECH patch.
if [ ! -d "nginx-$LATEST_NGINX" ]; then
    curl -fSL --max-time 300 -o "nginx-$LATEST_NGINX.tar.gz" \
        "$NGINX_URL/nginx-$LATEST_NGINX.tar.gz"
    verify_nginx_tarball "nginx-$LATEST_NGINX.tar.gz" "$LATEST_NGINX" || {
        rm -f "nginx-$LATEST_NGINX.tar.gz" "nginx-$LATEST_NGINX.tar.gz.asc"
        echo -e "\033[1;31m[-] Refusing to build from an unverified tarball. Your running nginx is untouched.\033[0m"
        exit 1; }
    tar -xf "nginx-$LATEST_NGINX.tar.gz"
    rm -f "nginx-$LATEST_NGINX.tar.gz" "nginx-$LATEST_NGINX.tar.gz.asc"
else
    echo -e "\033[1;33m[*] nginx-$LATEST_NGINX already extracted — skipping download and PGP check\033[0m"
fi

cd "nginx-$LATEST_NGINX"

# Server-side ECH for BoringSSL. nginx ships the ssl_ech_file directive but its
# implementation targets the OpenSSL-ECH API (guarded by SSL_OP_ECH_GREASE) and
# is a no-op against BoringSSL; this patch adds a BoringSSL branch. Idempotent:
# only applied to a freshly downloaded (unpatched) source tree.
if ! grep -q "SSL_ECH_KEYS_add" src/event/ngx_event_openssl.c; then
    echo -e "\033[1;33m[*] Applying BoringSSL ECH patch...\033[0m"
    patch -p1 < /root/nginx-build/ech-boringssl.patch \
        || { echo -e "\033[1;31m[-] ECH patch failed to apply — abort\033[0m"; exit 1; }
    echo -e "\033[1;32m[+] ECH patch applied\033[0m"
fi

# Make sure the cache/temp directories exist before configure
mkdir -p /var/lib/nginx/{body,fastcgi,proxy,scgi,uwsgi}
chown -R www-data:www-data /var/lib/nginx

# 5. Configure nginx
echo -e "\033[1;33m[*] Configuring Nginx...\033[0m"
./configure \
    --prefix=/usr/share/nginx \
    --sbin-path=/usr/sbin/nginx \
    --conf-path=/etc/nginx/nginx.conf \
    --http-log-path=/var/log/nginx/access.log \
    --error-log-path=/var/log/nginx/error.log \
    --lock-path=/var/lock/nginx.lock \
    --pid-path=/run/nginx.pid \
    --modules-path=/usr/lib/nginx/modules \
    --http-client-body-temp-path=/var/lib/nginx/body \
    --http-fastcgi-temp-path=/var/lib/nginx/fastcgi \
    --http-proxy-temp-path=/var/lib/nginx/proxy \
    --http-scgi-temp-path=/var/lib/nginx/scgi \
    --http-uwsgi-temp-path=/var/lib/nginx/uwsgi \
    --user=www-data \
    --group=www-data \
    --with-compat \
    --with-file-aio \
    --with-threads \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-http_realip_module \
    --with-http_addition_module \
    --with-http_sub_module \
    --with-http_dav_module \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_auth_request_module \
    --with-http_stub_status_module \
    --with-http_slice_module \
    --with-stream \
    --with-stream_ssl_module \
    --with-stream_realip_module \
    --with-pcre-jit \
    --add-module=/root/nginx-build/ngx_brotli \
    --with-cc-opt="-I/root/nginx-build/boringssl-nginx/include -O3 -march=znver2 -mtune=znver2 -flto -fstack-protector-strong -DTCP_FASTOPEN=23" \
    --with-ld-opt="/root/nginx-build/boringssl-nginx/build/libssl.a /root/nginx-build/boringssl-nginx/build/libcrypto.a -flto -ljemalloc -lstdc++ -lpthread -ldl -Wl,-z,relro -Wl,-z,now -Wl,-E"

# 6. Compile
echo -e "\033[1;33m[*] Compiling Nginx with $CORES threads...\033[0m"
make -j"$CORES"

# 7. Test the freshly built binary BEFORE installing it (safe update gate)
echo -e "\033[1;33m[*] Testing compiled binary against current config...\033[0m"
if ./objs/nginx -t -c /etc/nginx/nginx.conf -p /usr/share/nginx/; then
    echo -e "\033[1;32m[+] Config test passed! Safe to install.\033[0m"
else
    echo -e "\033[1;31m[-] CRITICAL: Config test failed with new binary.\033[0m"
    echo -e "\033[1;31m[-] Aborting installation. Your running Nginx is untouched.\033[0m"
    exit 1
fi


# After make, before make install:
# ─── Extra safety: ensure binary actually starts ───
echo -e "\033[1;33m[*] Quick binary startup test...\033[0m"
./objs/nginx -t -c /etc/nginx/nginx.conf
./objs/nginx -V 2>&1 | head -3  # confirms version, modules, ssl lib
if ! ./objs/nginx -V 2>&1 | grep -q "BoringSSL"; then
    echo -e "\033[1;31m[-] CRITICAL: Binary not linked against BoringSSL!\033[0m"
    exit 1
fi

# 8. Hot upgrade — zero downtime binary swap
echo -e "\033[1;33m[*] Installing new binary...\033[0m"
make install

echo -e "\033[1;33m[*] Sending USR2 to running master (hot upgrade)...\033[0m"
OLD_PID=$(cat /run/nginx.pid)
kill -USR2 "$OLD_PID"

# Wait for new master to come up
sleep 3

# Check that new master spawned
if [ -f /run/nginx.pid.oldbin ]; then
    echo -e "\033[1;32m[+] New master is running. Gracefully shutting down old workers...\033[0m"
    NEW_PID=$(cat /run/nginx.pid)
    kill -WINCH "$OLD_PID"  # gracefully shut down old workers
    sleep 5
    kill -QUIT "$OLD_PID"   # kill old master
    echo -e "\033[1;32m[+] Hot upgrade complete. New version: $(nginx -v 2>&1)\033[0m"
else
    echo -e "\033[1;31m[-] Hot upgrade failed. Falling back to systemctl restart.\033[0m"
    systemctl restart nginx
fi