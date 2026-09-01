# Stand-in for the authentik RADIUS outpost.
#
# The real outpost speaks PAP only and silently drops every packet that is not
# an Access-Request -- its ServeRADIUS has no else branch. status_server must
# therefore be "no" here, or this stand-in answers Status-Server when the real
# outpost never would, and the regression test in run.sh becomes meaningless.
FROM freeradius/freeradius-server:3.2.10-alpine

RUN printf '\nclient proxy {\n\tipaddr = 0.0.0.0/0\n\tsecret = "backendsecret"\n\trequire_message_authenticator = no\n}\n' \
      >> /etc/raddb/clients.conf \
 && sed -i '1i testuser Cleartext-Password := "testpw"' /etc/raddb/mods-config/files/authorize \
 && sed -i 's/^\([[:space:]]*\)status_server = yes/\1status_server = no/' /etc/raddb/radiusd.conf \
 && grep -q 'status_server = no' /etc/raddb/radiusd.conf

ENTRYPOINT ["/opt/sbin/radiusd", "-f", "-l", "stdout", "-d", "/etc/raddb"]
