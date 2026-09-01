FROM alpine:3.21
RUN apk add --no-cache wpa_supplicant openssl
COPY ttls.conf /ttls.conf
COPY auth.sh /auth.sh
RUN chmod +x /auth.sh
