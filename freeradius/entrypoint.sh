#!/bin/sh

cat /etc/raddb/template/clients.conf.template |\
  sed "s/__AUTHENTIK_RADIUS_SECRET__/${AUTHENTIK_RADIUS_SECRET}/g" |\
  sed "s/__RADIUS_SECRET__/${RADIUS_SECRET}/g" > /etc/raddb/clients.conf

if [ "${FREERADIUS_ENABLE_DEBUG}" == "true" ]; then
    exec /opt/sbin/radiusd -X $*
else
    exec /opt/sbin/radiusd $*
fi
