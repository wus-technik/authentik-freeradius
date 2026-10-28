FROM alpine:3.21
RUN apk add --no-cache wpa_supplicant openssl openldap-clients
COPY ttls.conf /ttls.conf
COPY peap.conf /peap.conf
COPY auto.conf /auto.conf
COPY auth.sh /auth.sh
RUN chmod +x /auth.sh
