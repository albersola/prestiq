#!/bin/sh
# Enables the TLS server only when a certificate is mounted, then starts OpenResty.
set -eu

RUNTIME_DIR=/tmp/nginx
TLS_DIR=/etc/gateway/tls
CERT="$TLS_DIR/${TLS_CERT:-fullchain.pem}"
KEY="$TLS_DIR/${TLS_KEY:-privkey.pem}"

mkdir -p "$RUNTIME_DIR/servers"
rm -f "$RUNTIME_DIR/servers/tls.conf"

if [ -f "$CERT" ] && [ -f "$KEY" ]; then
  cat > "$RUNTIME_DIR/servers/tls.conf" <<CONF
server {
    listen 8443 ssl;
    ssl_certificate $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    include /etc/gateway/nginx/routes.conf;
}
CONF
  echo "entrypoint: TLS enabled on :8443 with $CERT"
else
  echo "entrypoint: TLS disabled, no certificate at $CERT"
fi

exec openresty -e stderr -c /etc/gateway/nginx/nginx.conf -g 'daemon off;'
