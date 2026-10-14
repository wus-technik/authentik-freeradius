# Stand-in for the authentik RADIUS outpost.
#
# The real outpost speaks PAP only and silently drops every packet that is not
# an Access-Request -- its ServeRADIUS has no else branch. status_server must
# therefore be "no" here, or this stand-in answers Status-Server when the real
# outpost never would, and the regression test in run.sh becomes meaningless.
#
# testuser and otheruser carry a Filter-Id the way an authentik property
# mapping does -- verified against authentik 2026.8.3, where Filter-Id is one
# of the few RFC attributes its bundled dictionary knows (issue #10).
FROM freeradius/freeradius-server:3.2.10-alpine

RUN printf '\nclient proxy {\n\tipaddr = 0.0.0.0/0\n\tsecret = $ENV{AUTHENTIK_RADIUS_SECRET}\n\trequire_message_authenticator = no\n}\n' \
      >> /etc/raddb/clients.conf \
 && f=/etc/raddb/mods-config/files/authorize \
 && { printf 'testuser Cleartext-Password := "testpw"\n\tFilter-Id = "vlan-staff"\n\n'; \
      printf 'otheruser Cleartext-Password := "testpw"\n\tFilter-Id = "vlan-unmapped"\n\n'; \
      cat "$f"; } > /tmp/authorize && mv /tmp/authorize "$f" \
 && sed -i 's/^\([[:space:]]*\)status_server = yes/\1status_server = no/' /etc/raddb/radiusd.conf \
 && grep -q 'status_server = no' /etc/raddb/radiusd.conf

ENTRYPOINT ["/opt/sbin/radiusd", "-f", "-l", "stdout", "-d", "/etc/raddb"]
