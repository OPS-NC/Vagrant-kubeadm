# Policy Vault : émission de certificats TLS (VaultPKISecret).
# Moteur "pki" monté sur pki/ ; on autorise uniquement l'émission via le role "demo".
# Le role PKI contraint les domaines/durées autorisés (cf. vault/00-secrets-engines.sh).

path "pki/issue/demo" {
  capabilities = ["create", "update"]
}

# Révocation du certificat à la suppression du VaultPKISecret (revoke=true).
path "pki/revoke" {
  capabilities = ["create", "update"]
}
