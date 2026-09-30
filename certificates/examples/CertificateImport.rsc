# RouterOS source for a system script named CertificateImport.
#
# The Linux helper uploads fullchain.pem and privkey.pem to the router root.
# This script imports them and removes the temporary files afterwards.

/certificate import file-name=fullchain.pem passphrase=""
/certificate import file-name=privkey.pem passphrase=""
/file remove [find name="fullchain.pem"]
/file remove [find name="privkey.pem"]