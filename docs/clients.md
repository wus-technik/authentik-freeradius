# Client configuration

All clients use **EAP-TTLS** with **PAP** as the inner method.

## The certificate trust problem

A publicly-trusted certificate (Let's Encrypt) means clients already trust the issuer, but
that is **not** the same as being safe. Unless the client is told which CA and which server
name to expect, it will accept any server presenting any valid certificate — which is
exactly how EAP credential-theft attacks work.

Configure the CA **and** the server name on every managed device, via Intune, GPO or an
`.mobileconfig`. This stack cannot enforce it from the server side.

## Windows 10/11

Network & Internet → Manage known networks → Add.

- Security type: **WPA2-Enterprise**
- EAP method: **EAP-TTLS**
- Trusted Root CA: the CA that issued the server certificate
- Server name: the certificate's CN, e.g. `radius.example.com`
- Authentication method: **Unencrypted password (PAP)**

Windows does not offer EAP-TTLS/PAP in every UI path; deploy it by GPO or Intune profile
for a fleet.

## Android 11+

- EAP method: **TTLS**
- Phase 2: **PAP**
- CA certificate: **Use system certificates** (not "Do not validate")
- Domain: `radius.example.com` — mandatory on Android 11+; the network will not connect
  without it

## iOS / macOS

iOS has no EAP-TTLS/PAP option in the manual UI. Deploy a `.mobileconfig` profile with
Apple Configurator or your MDM, setting EAP-TTLS, inner authentication PAP, and the trusted
certificate and server name.

## Linux (NetworkManager)

- Security: **WPA & WPA2 Enterprise**
- Authentication: **Tunneled TLS**
- CA certificate: the issuing CA
- Inner authentication: **PAP**

## Linux (wpa_supplicant)

```
ctrl_interface=/var/run/wpa_supplicant
ctrl_interface_group=root
network={
	ssid="YOUR-SSID"
	scan_ssid=1
	key_mgmt=WPA-EAP
	eap=TTLS
	identity="user@example.com"
	password="user-password"
	anonymous_identity="anonymous"
	ca_cert="/etc/ssl/certs/ca-certificates.crt"
	domain_suffix_match="radius.example.com"
	phase2="auth=PAP"
}
```

Save the block above as `wpa2_supplicant.conf`, then run with
`sudo wpa_supplicant -d -c ./wpa2_supplicant.conf -i wlan0`.

Do not omit `ca_cert` and `domain_suffix_match`. Without them the supplicant accepts any
server and will hand the password to an impostor access point.
