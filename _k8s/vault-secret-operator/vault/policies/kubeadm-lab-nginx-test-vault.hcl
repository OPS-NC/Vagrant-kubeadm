# Policy Vault : lecture seule des secrets de l'appli nginx-test-vault dans le moteur kubeadm-lab/.
# Moindre privilège : l'appli ne voit QUE son sous-dossier nginx-test-vault/, rien d'autre.
# KV-v2 => les données sont sous <mount>/data/<path> et les métadonnées sous <mount>/metadata/<path>.

path "kubeadm-lab/data/nginx-test-vault/*" {
  capabilities = ["read"]
}

path "kubeadm-lab/metadata/nginx-test-vault/*" {
  capabilities = ["read"]
}
