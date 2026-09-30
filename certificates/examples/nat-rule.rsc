# Example temporary dst-nat rule used only while Certbot performs HTTP-01
# validation. Adjust interfaces/addresses to your own network before use.
#
# Keep the comment in sync with NAT_RULE_COMMENT in letsencrypt-sync.sh.

/ip firewall nat
add chain=dstnat protocol=tcp dst-port=80 action=dst-nat \
    to-addresses=192.0.2.80 to-ports=80 \
    comment="letsencrypt-webroot" disabled=yes