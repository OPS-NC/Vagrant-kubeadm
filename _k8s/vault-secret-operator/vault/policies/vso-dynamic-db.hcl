# Policy Vault : génération de credentials DB éphémères (VaultDynamicSecret).
# Le moteur "database" est monté sur db/ ; on lit le role "demo-app" qui produit
# un couple user/password temporaire (lease) à chaque appel.

path "db/creds/demo-app" {
  capabilities = ["read"]
}

# Renouvellement / révocation des leases par VSO (rotation avant expiration,
# révocation à la suppression du VaultDynamicSecret quand revoke=true).
path "sys/leases/renew" {
  capabilities = ["update"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
