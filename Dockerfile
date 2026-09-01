FROM freeradius/freeradius-server:3.2.10-alpine

LABEL org.opencontainers.image.title="authentik-freeradius" \
      org.opencontainers.image.description="FreeRADIUS EAP-TTLS front-end for the authentik RADIUS outpost (WPA2/3-Enterprise)" \
      org.opencontainers.image.source="https://github.com/wus-technik/authentik-freeradius"

# No openssl and no DH parameter generation: FreeRADIUS 3.2 configures DH
# itself, and radclient for the healthcheck already ships in the base image.

COPY freeradius/radiusd.conf /etc/raddb/radiusd.conf
COPY freeradius/clients.conf /etc/raddb/clients.conf
COPY freeradius/mods/eap /etc/raddb/mods-available/eap
COPY freeradius/sites/site /etc/raddb/sites-available/site
COPY freeradius/sites/proxy-inner-tunnel /etc/raddb/sites-available/proxy-inner-tunnel
COPY freeradius/entrypoint.sh /entrypoint.sh
COPY freeradius/healthcheck.sh /healthcheck.sh

RUN rm -f /etc/raddb/sites-enabled/* \
 && ln -s ../sites-available/site /etc/raddb/sites-enabled/site \
 && ln -s ../sites-available/proxy-inner-tunnel /etc/raddb/sites-enabled/proxy-inner-tunnel \
 && chmod +x /entrypoint.sh /healthcheck.sh \
 && mkdir -p /tmp/radiusd /run/radiusd

EXPOSE 1812/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD /healthcheck.sh

ENTRYPOINT ["/entrypoint.sh"]
