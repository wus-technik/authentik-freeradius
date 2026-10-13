# Stand-in for the authentik LDAP outpost (issue #14): the DNs, the attribute
# names and the "only the service account may search" rule of the real one.
FROM alpine:3.21
RUN apk add --no-cache openldap openldap-back-mdb
COPY akfr.schema /etc/openldap/schema/akfr.schema
COPY slapd.conf /etc/openldap/slapd.conf
COPY seed.ldif /tmp/seed.ldif
RUN mkdir -p /run/openldap /var/lib/openldap/openldap-data \
 && slapadd -f /etc/openldap/slapd.conf -l /tmp/seed.ldif \
 && rm /tmp/seed.ldif
ENTRYPOINT ["/usr/sbin/slapd", "-d", "0", "-f", "/etc/openldap/slapd.conf", "-h", "ldap://0.0.0.0:3389/"]
