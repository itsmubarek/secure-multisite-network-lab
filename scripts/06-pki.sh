#!/usr/bin/env bash
# Step 6: private PKI with OpenSSL and an HTTPS web server (run from the host).
#
#   Root CA (self-signed) -> Intermediate CA (pathlen 0) -> server certificate for web.lab.local
#   The CA tree lives on the admin workstation client-a (never on the DMZ web server).
#   The web server generates its OWN private key and only sends a CSR to the CA.
#
# Lab note: CA keys are unencrypted so the lab can be rebuilt unattended. In production the root key
# is encrypted and kept offline.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH="ssh -i $LAB_DIR/.keys/lab_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
CA() { $SSH -p 2204 lab@127.0.0.1 "$@"; }      # client-a  = CA / admin workstation
WEB() { $SSH -p 2203 lab@127.0.0.1 "$@"; }     # web-dmz   = web server

# ---------------------------------------------------------------- openssl configuration template
read -r -d '' TEMPLATE <<'EOF' || true
[ ca ]
default_ca = CA_default
[ CA_default ]
dir               = @DIR@
certs             = $dir/certs
crl_dir           = $dir/crl
new_certs_dir     = $dir/newcerts
database          = $dir/index.txt
serial            = $dir/serial
private_key       = $dir/private/@NAME@.key
certificate       = $dir/certs/@NAME@.crt
crlnumber         = $dir/crlnumber
crl               = $dir/crl/@NAME@.crl
crl_extensions    = crl_ext
default_crl_days  = 30
default_md        = sha384
default_days      = 365
preserve          = no
unique_subject    = no
policy            = policy_loose
[ policy_loose ]
organizationName  = optional
commonName        = supplied
[ req ]
distinguished_name = req_dn
string_mask        = utf8only
default_md         = sha384
prompt             = no
[ req_dn ]
CN = placeholder
[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign
[ v3_intermediate_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true, pathlen:0
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign
[ server_cert ]
basicConstraints       = CA:FALSE
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer:always
keyUsage               = critical, digitalSignature
extendedKeyUsage       = serverAuth
subjectAltName         = $ENV::SAN
[ crl_ext ]
authorityKeyIdentifier = keyid:always
EOF

# ---------------------------------------------------------------- 1. build the CA hierarchy on client-a
echo "== 1. root CA and intermediate CA on client-a"
CA 'bash -s' <<REMOTE
set -euo pipefail
export SAN=DNS:unused
rm -rf ~/pki && mkdir -p ~/pki/root ~/pki/intermediate
for d in root intermediate; do
  mkdir -p ~/pki/\$d/{certs,crl,newcerts,private}; chmod 700 ~/pki/\$d/private
  : > ~/pki/\$d/index.txt; echo 1000 > ~/pki/\$d/serial; echo 1000 > ~/pki/\$d/crlnumber
done
cat > ~/pki/template.cnf <<'CNF'
$TEMPLATE
CNF
sed "s#@DIR@#\$HOME/pki/root#;s#@NAME@#root#"                 ~/pki/template.cnf > ~/pki/root/openssl.cnf
sed "s#@DIR@#\$HOME/pki/intermediate#;s#@NAME@#intermediate#" ~/pki/template.cnf > ~/pki/intermediate/openssl.cnf

# root CA: EC P-384, self-signed, 10 years
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out ~/pki/root/private/root.key
chmod 400 ~/pki/root/private/root.key
openssl req -config ~/pki/root/openssl.cnf -new -x509 -sha384 -days 3650 -extensions v3_ca \
  -key ~/pki/root/private/root.key -subj "/O=SecurityLab/CN=SecurityLab Root CA" -out ~/pki/root/certs/root.crt

# intermediate CA: key + CSR, signed by the root, pathlen 0, 5 years
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out ~/pki/intermediate/private/intermediate.key
chmod 400 ~/pki/intermediate/private/intermediate.key
openssl req -config ~/pki/intermediate/openssl.cnf -new -sha384 \
  -key ~/pki/intermediate/private/intermediate.key -subj "/O=SecurityLab/CN=SecurityLab Intermediate CA" \
  -out ~/pki/intermediate/intermediate.csr
openssl ca -config ~/pki/root/openssl.cnf -extensions v3_intermediate_ca -days 1825 -notext -md sha384 -batch \
  -in ~/pki/intermediate/intermediate.csr -out ~/pki/intermediate/certs/intermediate.crt
cat ~/pki/intermediate/certs/intermediate.crt ~/pki/root/certs/root.crt > ~/pki/ca-chain.crt
openssl verify -CAfile ~/pki/root/certs/root.crt ~/pki/intermediate/certs/intermediate.crt
REMOTE

# ---------------------------------------------------------------- 2. web server: own key + CSR
echo "== 2. web-dmz generates its own key and CSR"
WEB 'sudo mkdir -p /etc/nginx/tls && sudo chmod 755 /etc/nginx/tls &&
  sudo openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out /etc/nginx/tls/web.key &&
  sudo chmod 640 /etc/nginx/tls/web.key && sudo chgrp www-data /etc/nginx/tls/web.key &&
  sudo openssl req -new -sha256 -key /etc/nginx/tls/web.key -subj "/O=SecurityLab/CN=web.lab.local" -out /tmp/web.csr &&
  cat /tmp/web.csr' > /tmp/web.csr

# ---------------------------------------------------------------- 3. CA signs the CSR, issue a second cert for the revocation test
echo "== 3. intermediate CA signs web.lab.local (and a throw-away cert that will be revoked)"
cat /tmp/web.csr | CA 'cat > ~/pki/web.csr'
CA 'bash -s' <<'REMOTE'
set -euo pipefail
export SAN=DNS:unused
cd ~/pki
SAN="DNS:web.lab.local,IP:10.10.2.10" openssl ca -config intermediate/openssl.cnf -extensions server_cert -days 365 -notext -md sha256 -batch \
  -in web.csr -out intermediate/certs/web.crt
# a second certificate, issued only to be revoked
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out revoked.key
openssl req -new -sha256 -key revoked.key -subj "/O=SecurityLab/CN=old.lab.local" -out revoked.csr
SAN="DNS:old.lab.local" openssl ca -config intermediate/openssl.cnf -extensions server_cert -days 365 -notext -md sha256 -batch \
  -in revoked.csr -out intermediate/certs/old.crt
openssl verify -CAfile ca-chain.crt intermediate/certs/web.crt
REMOTE

# ---------------------------------------------------------------- 4. deploy certificate chain + nginx TLS
echo "== 4. deploy web certificate chain and enable HTTPS on web-dmz"
CA 'cat ~/pki/intermediate/certs/web.crt ~/pki/intermediate/certs/intermediate.crt' | WEB 'sudo tee /etc/nginx/tls/web-fullchain.crt >/dev/null'
WEB 'sudo tee /etc/nginx/sites-available/web-lab >/dev/null' <<'EOF'
server {
    listen 443 ssl default_server;
    server_name web.lab.local;
    ssl_certificate     /etc/nginx/tls/web-fullchain.crt;
    ssl_certificate_key /etc/nginx/tls/web.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    add_header X-Content-Type-Options nosniff always;
    root /var/www/lab;
    index index.html;
}
EOF
WEB 'sudo mkdir -p /var/www/lab && echo "<h1>SecurityLab intranet</h1><p>served over TLS with a certificate from the lab PKI</p>" | sudo tee /var/www/lab/index.html >/dev/null &&
  sudo rm -f /etc/nginx/sites-enabled/default && sudo ln -sf /etc/nginx/sites-available/web-lab /etc/nginx/sites-enabled/web-lab &&
  sudo nginx -t && sudo systemctl restart nginx && ss -ltn | grep -E ":443 "'

# ---------------------------------------------------------------- 5. clients trust the root CA, name resolution
echo "== 5. clients: name resolution (hosts file) for web.lab.local"
for port in 2204 2205; do
  $SSH -p $port lab@127.0.0.1 'grep -q web.lab.local /etc/hosts || echo "10.10.2.10 web.lab.local" | sudo tee -a /etc/hosts >/dev/null'
done

# ---------------------------------------------------------------- 6. CRL
echo "== 6. revoke old.lab.local and publish a CRL"
CA 'bash -s' <<'REMOTE'
set -euo pipefail
export SAN=DNS:unused
cd ~/pki
openssl ca -config intermediate/openssl.cnf -revoke intermediate/certs/old.crt -crl_reason keyCompromise
openssl ca -config intermediate/openssl.cnf -gencrl -out intermediate/crl/intermediate.crl
cat intermediate/crl/intermediate.crl >/dev/null && echo "CRL written"
REMOTE
echo "PKI build finished"
