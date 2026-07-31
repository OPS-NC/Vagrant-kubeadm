# Policy Vault : lecture seule d'un secret KV-v2 pour le VaultStaticSecret.
# Moindre privilège : on autorise UN chemin précis, pas "secret/*".
#
# KV-v2 : le chemin de lecture des données est <mount>/data/<path> (pas <mount>/<path>).
# Ici mount=kvv2, path=demo/app -> secret écrit sous kvv2/demo/app.

path "kvv2/data/demo/app" {
  capabilities = ["read"]
}

# Métadonnées (versions) : utile pour lire une version précise (VaultStaticSecret.spec.version).
path "kvv2/metadata/demo/app" {
  capabilities = ["read"]
}
