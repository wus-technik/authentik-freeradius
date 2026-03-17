FROM freeradius/freeradius-server:latest-3.2-alpine

RUN apk add --no-cache openssl

# Generate Dhparam
RUN rm -rf /etc/raddb/certs && \
 mkdir -p /etc/raddb/certs && \
 cd /etc/raddb/certs && \
 openssl dhparam -out dh.pem 2048

RUN wget -O /etc/ca.crt https://ccadb.my.salesforce-sites.com/mozilla/IncludedRootsPEMTxt?TrustBitsInclude=Websites

RUN mkdir -p /etc/raddb/template/

COPY freeradius/radiusd.conf /etc/raddb/
COPY freeradius/mods/eap /etc/raddb/mods-available
COPY freeradius/clients.conf.template /etc/raddb/template/

COPY freeradius/sites/site /etc/raddb/sites-available
COPY freeradius/sites/proxy-inner-tunnel /etc/raddb/sites-available
COPY freeradius/entrypoint.sh /entrypoint.sh

RUN rm /etc/raddb/sites-enabled/* && \
    ln -s /etc/raddb/sites-available/site /etc/raddb/sites-enabled/site && \
    ln -s /etc/raddb/sites-available/proxy-inner-tunnel /etc/raddb/sites-enabled/proxy-inner-tunnel && \
    mkdir /tmp/radiusd

WORKDIR /

EXPOSE 1812/udp

ENTRYPOINT ["/entrypoint.sh", "-d", "/etc/raddb", "-f"]
