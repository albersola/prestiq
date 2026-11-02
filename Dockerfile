FROM openresty/openresty:1.31.8.1-alpine

COPY gateway/nginx.conf gateway/routes.conf /etc/gateway/nginx/
COPY gateway/lua/ /opt/gateway/
COPY gateway/entrypoint.sh /usr/local/bin/entrypoint.sh

EXPOSE 8080 8443
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
