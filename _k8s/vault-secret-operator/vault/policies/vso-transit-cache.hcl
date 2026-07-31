# Policy Vault : chiffrement du cache client de l'opérateur (clientCache.storageEncryption).
# VSO chiffre/déchiffre son cache local via une clé Transit dédiée "vso-client-cache".
# Cette policy est portée par le ServiceAccount DE L'OPÉRATEUR (role vso-transit), pas par
# les apps. Elle ne donne aucun accès aux secrets métier — uniquement encrypt/decrypt.

path "transit/encrypt/vso-client-cache" {
  capabilities = ["create", "update"]
}
path "transit/decrypt/vso-client-cache" {
  capabilities = ["create", "update"]
}
