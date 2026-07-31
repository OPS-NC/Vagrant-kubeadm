#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "markdown-it-py[linkify]>=3.0",
#   "mdit-py-plugins>=0.4",
#   "Pygments>=2.18",
# ]
# ///
"""
build.py — génère `docs/index.html` à partir des README du dépôt.

Page unique et autonome : aucun CDN, aucun asset externe, aucun serveur.
Le markdown est converti au build (markdown-it-py, CommonMark + tables) et
coloré par Pygments ; le JS embarqué ne gère que navigation, recherche, langue,
thème et boutons « copier ».

Utilisation :
    ./docs/build.py                  # uv installe les deps à la volée (PEP 723)
    uv run docs/build.py --out /tmp/doc.html
    uv run docs/build.py --strict    # échoue si un lien interne ne résout pas
    make docs

BILINGUE : chaque page existe en deux versions, dans le MÊME dossier —
l'anglais porte le nom canonique (`README.md`, `CLAUDE.md`, `UPGRADE.md`), le
français son miroir (`LISEZ-MOI.md`, `MISE-A-JOUR.md`), cf.
MIROIRS. L'anglais est la langue par défaut ; le sélecteur EN/FR de la barre
latérale bascule tout le site et l'URL (`#fr/_k8s-longhorn-readme`).

AJOUTER UNE PAGE : rien à faire, tout `*.md` du dépôt est découvert
automatiquement. Seuls le regroupement du menu et l'emoji viennent de
GROUPES / EMOJIS ci-dessous ; un dossier inconnu tombe dans « Autres ».
"""

from __future__ import annotations

import argparse
import base64
import html
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

from markdown_it import MarkdownIt
from markdown_it.token import Token
from mdit_py_plugins.anchors import anchors_plugin
from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import get_lexer_by_name
from pygments.util import ClassNotFound

RACINE = Path(__file__).resolve().parent.parent

# Dossiers jamais explorés (dépendances, artefacts, sortie du générateur).
EXCLUS = {".git", ".vagrant", ".terraform", "node_modules", "docs", "iso", "_out"}

# Pages publiées MÊME si git les ignore. Volontairement VIDE : la page est publiée
# sur GitHub Pages, où le build ne dispose que des fichiers versionnés. Y forcer un
# dossier local produirait une page locale différente de la page publiée, et
# risquerait d'y exposer une configuration privée (domaine réel, clés d'appli).
# Un addon qui doit apparaître dans la doc doit donc être versionné.
FORCER: set[str] = set()

# --- Langues ----------------------------------------------------------------
# nom du fichier anglais (canonique) -> nom de son miroir français, même dossier.
MIROIRS = {
    "README.md":          "LISEZ-MOI.md",
    "UPGRADE.md":         "MISE-A-JOUR.md",
    "TROUBLESHOOTING.md": "DEPANNAGE.md",
}

# Pages ANGLAIS SEULEMENT par choix : pas de miroir français, et donc pas de badge
# « pas encore traduit » — ce serait signaler un oubli là où il y a une décision.
# CLAUDE.md s'adresse aux agents de code, dont la langue de travail est l'anglais.
SANS_MIROIR = {"CLAUDE.md"}
LANGUES = ("en", "fr")
LANGUE_DEFAUT = "en"

# Dépôt public du projet, épinglé ici plutôt que dans le gabarit HTML : c'est la
# seule URL externe de la page, et le lecteur d'une copie hors ligne doit pouvoir
# retrouver la source. Le pictogramme est un SVG INLINE (cf. lien_depot) : la page
# est auto-contenue, donc pas de badge shields.io ni d'icône servie par un CDN.
DEPOT_URL = "https://github.com/OPS-NC/Vagrant-kubeadm"

# Bannière « English · Français » posée en tête de chaque fichier pour les
# lecteurs de GitHub. La page HTML a son propre sélecteur : on la retire.
RE_BANNIERE = re.compile(r"<!--\s*i18n\s*-->.*?<!--\s*/i18n\s*-->\s*", re.DOTALL)

# Libellés de l'interface. Tout texte visible du gabarit passe par ici.
LIBELLES: dict[str, dict[str, str]] = {
    "en": {
        "recherche":       "Search…   /",
        "recherche_aria":  "Search a page",
        "sommaire":        "On this page",
        "copier":          "Copy",
        "copie":           "Copied!",
        "echec":           "Failed",
        "vers_clair":      "Switch to light theme",
        "vers_sombre":     "Switch to dark theme",
        "menu":            "Open the menu",
        "langue_aria":     "Documentation language",
        "source":          "Source:",
        "sections":        "sections",
        "badge":           "untracked",
        "badge_titre":     "Not in git: local directory",
        "badge_langue":    "EN",
        "badge_langue_titre": "Not translated yet — English page shown",
        "depot":           "GitHub repository",
        "sous_titre":      "Kubernetes lab built with kubeadm on VirtualBox, driven by Vagrant.",
    },
    "fr": {
        "recherche":       "Rechercher…   /",
        "recherche_aria":  "Rechercher une page",
        "sommaire":        "Sur cette page",
        "copier":          "Copier",
        "copie":           "Copié !",
        "echec":           "Échec",
        "vers_clair":      "Passer en clair",
        "vers_sombre":     "Passer en sombre",
        "menu":            "Ouvrir le menu",
        "langue_aria":     "Langue de la documentation",
        "source":          "Source :",
        "sections":        "sections",
        "badge":           "non commité",
        "badge_titre":     "Absent de git : dossier local",
        "badge_langue":    "EN",
        "badge_langue_titre": "Pas encore traduit — page anglaise affichée",
        "depot":           "Dépôt GitHub",
        "sous_titre":      "Lab Kubernetes monté avec kubeadm sur VirtualBox, piloté par Vagrant.",
    },
}

# --- Plan du menu -----------------------------------------------------------
# (titres par langue, emoji, chemins ANGLAIS ou dossiers, dans l'ordre d'affichage)
GROUPES: list[tuple[dict[str, str], str, list[str]]] = [
    ({"en": "The lab",       "fr": "Le lab"},           "🏠",
     ["README.md", "kubeadm/UPGRADE.md", "TROUBLESHOOTING.md"]),
    ({"en": "Platform",      "fr": "Plateforme"},       "📦", ["_k8s/README.md"]),
    ({"en": "Networking",    "fr": "Réseau"},           "🌐",
     ["_k8s/cilium", "_k8s/calico", "_k8s/envoy-gateway", "_k8s/self-signed",
      "_k8s/cert-manager"]),
    ({"en": "Storage",       "fr": "Stockage"},         "💾",
     ["_k8s/longhorn", "_k8s/local-path-storage", "_k8s/minio-s3"]),
    ({"en": "Secrets",       "fr": "Secrets"},          "🔐",
     ["_k8s/vault-cluster", "_k8s/vault-secret-operator"]),
    ({"en": "Databases",     "fr": "Bases de données"}, "🗄️",
     ["_k8s/cloudnative-pg"]),
    ({"en": "Observability", "fr": "Observabilité"},    "👁️",
     ["_k8s/observability", "_k8s/node-problem-detector", "_k8s/chaos-kube"]),
    ({"en": "Security",      "fr": "Sécurité"},         "🛡️",
     ["_k8s/kyverno", "_k8s/trivy-operator"]),
    ({"en": "Demos",         "fr": "Démos"},            "🧪",
     ["_k8s/argocd", "_k8s/wordpress-example"]),
    # En dernier, volontairement : CLAUDE.md ne s'adresse pas au lecteur du lab mais
    # aux agents de code, et il occupait la 2e place du menu.
    ({"en": "AI agent",      "fr": "Agent IA"},         "🤖", ["CLAUDE.md"]),
]
AUTRES = {"en": "Other", "fr": "Autres"}

EMOJIS: dict[str, str] = {
    "README.md":                                  "🏠",
    "CLAUDE.md":                                  "🤖",
    "TROUBLESHOOTING.md":                         "🚑",
    "kubeadm/UPGRADE.md":                           "⬆️",
    "_k8s/README.md":                             "📦",
    "_k8s/cilium/README.md":                      "🐝",
    "_k8s/calico/README.md":                      "🐆",
    "_k8s/envoy-gateway/README.md":               "🚪",
    "_k8s/self-signed/README.md":                 "🔏",
    "_k8s/cert-manager/README.md":                "📜",
    "_k8s/longhorn/README.md":                    "🐮",
    "_k8s/local-path-storage/README.md":          "📁",
    "_k8s/minio-s3/README.md":                    "🪣",
    "_k8s/minio-s3/cluster/README.md":            "🧺",
    "_k8s/vault-cluster/README.md":               "🔒",
    "_k8s/vault-secret-operator/README.md":       "🔑",
    "_k8s/vault-secret-operator/k8s/README.md":   "☸️",
    "_k8s/vault-secret-operator/vault/README.md": "⚙️",
    "_k8s/cloudnative-pg/README.md":              "🐘",
    "_k8s/observability/README.md":               "📈",
    "_k8s/node-problem-detector/README.md":       "🩺",
    "_k8s/chaos-kube/README.md":                  "🐒",
    "_k8s/kyverno/README.md":                     "⚖️",
    "_k8s/trivy-operator/README.md":              "🔎",
    "_k8s/argocd/README.md":                      "🐙",
    "_k8s/wordpress-example/README.md":           "📝",
}

# Encarts : un marqueur en tête de citation choisit la couleur. Les deux langues
# partagent la table, d'où les marqueurs FR *et* EN.
ENCARTS: list[tuple[str, tuple[str, ...]]] = [
    ("danger", ("⚠️", "🚨", "❌", "attention", "danger", "jamais", "ne pas", "ne jamais",
                "never", "do not", "don't", "warning")),
    ("astuce", ("💡", "✅", "🎯", "astuce", "conseil", "bon à savoir",
                "tip", "good to know")),
    ("info",   ("ℹ️", "📌", "📝", "🔍", "nb ", "nb :", "note", "remarque", "réf",
                "ref", "reminder")),
]


# ===========================================================================
#  Découverte des pages
# ===========================================================================

def git(*args: str) -> str:
    """Appelle git dans le dépôt ; chaîne vide si git est absent ou en erreur."""
    try:
        return subprocess.run(["git", "-C", str(RACINE), *args],
                              capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def ignores(chemins: list[str]) -> set[str]:
    """Sous-ensemble des chemins que git ignore (ex. le projet local proxmox/).

    On documente le dépôt, pas les dossiers de travail locaux — mais un fichier
    simplement *untracked* reste publié, avec un badge.
    """
    if not chemins:
        return set()
    try:
        res = subprocess.run(["git", "-C", str(RACINE), "check-ignore", "--stdin"],
                             input="\n".join(chemins), capture_output=True, text=True,
                             check=False)
        return set(res.stdout.split())      # rc=1 quand rien n'est ignoré : normal
    except FileNotFoundError:
        return set()


def lire(chemin: str) -> str:
    """Texte d'une page, bannière de langue retirée."""
    return RE_BANNIERE.sub("", (RACINE / chemin).read_text(encoding="utf-8"), count=1).lstrip()


def decouvrir() -> list[dict]:
    """Liste les documents du dépôt (une entrée par paire EN/FR), selon GROUPES."""
    suivis = set(git("ls-files", "*.md").split())
    trouves = sorted(
        p.relative_to(RACINE).as_posix()
        for p in RACINE.rglob("*.md")
        if not (EXCLUS & set(p.relative_to(RACINE).parts))
    )
    exclus = ignores(trouves) - FORCER
    restants = [c for c in trouves if c not in exclus]

    # apparie chaque page anglaise avec son miroir français, qui sort de la liste :
    # ce n'est pas un document de plus, c'est l'autre version du même document.
    miroir_de: dict[str, str] = {}
    for chemin in list(restants):
        p = Path(chemin)
        if p.name in MIROIRS:
            fr = (p.parent / MIROIRS[p.name]).as_posix()
            if fr in restants:
                miroir_de[chemin] = fr
                restants.remove(fr)

    docs: list[dict] = []

    def prendre(chemin: str, groupe: dict[str, str], emoji_defaut: str) -> None:
        restants.remove(chemin)
        fr = miroir_de.get(chemin, chemin)      # sans miroir : le FR retombe sur l'EN
        docs.append({
            "chemin": chemin,                   # chemin canonique (anglais)
            "chemins": {"en": chemin, "fr": fr},
            "groupe": groupe,
            "emoji": EMOJIS.get(chemin, emoji_defaut),
            # sans git on ne peut rien affirmer : on ne signale rien
            "suivi": chemin in suivis or not suivis,
        })

    for groupe, emoji, entrees in GROUPES:
        for entree in entrees:
            if entree.endswith(".md"):
                if entree in restants:
                    prendre(entree, groupe, emoji)
            else:  # un dossier : ses pages canoniques, la moins profonde d'abord
                for chemin in sorted((c for c in list(restants)
                                      if c.startswith(entree + "/")
                                      and Path(c).name in MIROIRS),
                                     key=lambda c: (c.count("/"), c)):
                    prendre(chemin, groupe, emoji)

    for chemin in list(restants):     # rien ne disparaît du menu
        prendre(chemin, AUTRES, "📄")
    return docs


# ===========================================================================
#  Conversion markdown → HTML
# ===========================================================================

# Emoji en tête de titre : les README commencent par un emoji (contrat de style),
# et le générateur en ajoute un. Sans séparation, ils apparaîtraient en double.
# La répétition tolère les espaces, pour qu'un titre en portant plusieurs
# (`# 🏠 🐧 Vagrant-KubeADM`) les garde tous groupés dans l'en-tête.
RE_EMOJI_INITIAL = re.compile(
    r"^((?:[\U0001F000-\U0001FAFF←-⇿⌀-➿⬀-⯿]"
    r"[︎️‍]*[ \t]*)+)"
)


def separer_emoji(titre: str) -> tuple[str, str]:
    """Détache le ou les emoji de tête d'un titre : (emoji, reste)."""
    m = RE_EMOJI_INITIAL.match(titre)
    return (m.group(1).strip(), titre[m.end():].lstrip()) if m else ("", titre)


def sans_markdown(texte: str) -> str:
    """Texte brut d'un titre (menu, onglet, recherche) : le balisage est retiré."""
    texte = re.sub(r"`([^`]*)`", r"\1", texte)
    texte = re.sub(r"\*\*([^*]*)\*\*", r"\1", texte)
    texte = re.sub(r"\*([^*]*)\*", r"\1", texte)
    texte = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", texte)
    return texte.strip()


def ancre(titre: str) -> str:
    """Slug façon GitHub : minuscules, accents gardés, ponctuation et emoji retirés.

    Les titres du dépôt commencent par un emoji (`## 🚑 7. Dépannage`) : sans le
    `strip("-")` final, le slug hériterait d'un tiret de tête.
    """
    slug = "".join(c for c in titre.lower() if c.isalnum() or c in " -_")
    return re.sub(r"[\s-]+", "-", slug).strip("-_")


def creer_convertisseur() -> MarkdownIt:
    """CommonMark + tables + HTML brut (`<details>`) + ancres sur les titres."""
    md = (
        MarkdownIt("commonmark", {"html": True, "linkify": True, "breaks": False})
        .enable(["table", "strikethrough"])
        .use(anchors_plugin, max_level=4, permalink=True, permalinkSymbol="#",
             permalinkSpace=False, slug_func=ancre)
    )
    md.add_render_rule("fence", _rendre_fence)
    return md


def _rendre_fence(self, tokens: list[Token], idx: int, options, env) -> str:
    """Bloc de code : coloration Pygments + bouton copier + étiquette de langage.

    Le bouton n'a pas de libellé au build : il est posé par le JS dans la langue
    active, sinon basculer FR/EN laisserait des « Copier » dans la page anglaise.
    """
    jeton = tokens[idx]
    # `jeton.info` vaut " " (et non "") quand la clôture du bloc porte une espace en
    # fin de ligne — une chaîne d'espaces est TRUTHY, donc l'ancien test `if jeton.info`
    # passait, et `"".split()[0]` levait une IndexError qui tuait toute la génération.
    # On découpe d'abord, on indexe ensuite : plus de branche à faire mentir.
    morceaux = (jeton.info or "").strip().split()
    langage = morceaux[0].lower() if morceaux else ""
    try:
        corps = highlight(jeton.content, get_lexer_by_name(langage or "text"),
                          HtmlFormatter(nowrap=True))
    except ClassNotFound:
        corps = html.escape(jeton.content, quote=False)
    etiquette = {"bash": "shell", "sh": "shell", "yml": "yaml", "": "text"}.get(langage, langage)
    return (
        f'<figure class="bloc-code" data-langage="{html.escape(etiquette, quote=True)}">'
        f'<button class="copier" type="button"></button>'
        f'<pre><code>{corps}</code></pre></figure>'
    )


def genre_encart(texte: str) -> str:
    """Choisit le style d'un encart d'après le début de son texte."""
    debut = texte.lstrip().lower()[:48]
    for nom, marqueurs in ENCARTS:
        if any(m in debut for m in marqueurs):
            return nom
    return "neutre"


def preparer(jetons: list[Token]) -> tuple[str | None, list[dict]]:
    """Annote les jetons (encarts, tableaux scrollables) et relève le sommaire.

    Retourne (titre H1, sommaire) ; le H1 est retiré du corps, il sert d'en-tête.
    """
    titre_h1: str | None = None
    sommaire: list[dict] = []

    for i, jeton in enumerate(jetons):
        if jeton.type == "blockquote_open":
            # le premier inline de la citation détermine la couleur de l'encart
            suite = next((t for t in jetons[i + 1:i + 6] if t.type == "inline"), None)
            jeton.attrJoin("class", f"encart encart-{genre_encart(suite.content if suite else '')}")

        elif jeton.type == "heading_open":
            inline = jetons[i + 1]
            texte = re.sub(r"\s*#\s*$", "", inline.content).strip()
            if jeton.tag == "h1" and titre_h1 is None:
                titre_h1 = texte
                # neutralise le H1 : il est réaffiché dans l'en-tête de page
                jeton.type, jeton.tag, jeton.hidden = "html_block", "", True
                jeton.content = ""
                inline.children, inline.content = [], ""
                jetons[i + 2].hidden = True
            elif jeton.tag in ("h2", "h3"):
                sommaire.append({"niveau": jeton.tag, "titre": texte,
                                 "ancre": jeton.attrGet("id") or ""})

    return titre_h1, sommaire


def convertir(md: MarkdownIt, page: dict) -> dict:
    """Rend une page et renvoie tout ce dont le gabarit a besoin.

    Le titre est décliné en trois formes : l'emoji (détaché du H1), le titre
    formaté (le `code` du markdown devient un vrai <code>) et le titre brut
    (menu, onglet, recherche).
    """
    jetons = md.parse(page["texte"])
    titre_brut, sommaire = preparer(jetons)
    corps = md.renderer.render(jetons, md.options, {})

    # tableaux : encapsulés pour pouvoir défiler horizontalement sur mobile
    corps = corps.replace("<table>", '<div class="table-scroll"><table>')
    corps = corps.replace("</table>", "</table></div>")
    # les ancres pointent vers la route interne #<page>/<section>
    corps = re.sub(r'(class="header-anchor" href=")#',
                   rf"\1#{page['id']}/", corps)

    titre_brut = titre_brut or Path(page["chemin"]).parent.name or page["chemin"]
    emoji, titre_brut = separer_emoji(titre_brut)
    return {
        "corps": corps,
        "sommaire": sommaire,
        # l'emoji du README prime ; sinon celui de la table EMOJIS / du groupe
        "emoji": emoji or page["emoji"],
        "titre_html": md.renderInline(titre_brut),
        "titre_texte": sans_markdown(titre_brut),
    }


# ===========================================================================
#  Liens internes : `foo/README.md#ancre` → route `#en/foo-readme/ancre`
# ===========================================================================

RE_LIEN_MD = re.compile(r'href="([^":#?]+\.md)(#[^"]*)?"')
RE_ID_TITRE = re.compile(r'<h[1-6][^>]*\sid="([^"]+)"')


def resoudre(rendu: dict, index: dict[str, dict[str, str]],
             ancres: dict[str, set[str]], alertes: list[str]) -> str:
    """Réécrit les liens `*.md` du corps en routes internes de la page unique.

    Sans cette passe, `[cilium/](../cilium/README.md)` resterait un lien
    *fichier* : cliquable sur GitHub, mort sur GitHub Pages. Le fragment est
    réconcilié avec les ancres réellement générées côté cible — les ancres
    GitHub gardent le tiret de tête laissé par l'emoji du titre, les nôtres non.
    """
    base = Path(rendu["chemin"]).parent
    table = index[rendu["langue"]]

    def remplacer(m: re.Match[str]) -> str:
        # `Path(cible)` est RELATIF : `.resolve()` le résolvait contre le cwd du
        # processus et non contre RACINE. Le garde testait donc un chemin pendant que
        # `.resolve()` en calculait un autre, d'où un `ValueError: not in the subpath
        # of` NON ATTRAPÉ qui faisait planter toute la génération — dès qu'on lançait
        # build.py depuis un autre répertoire que la racine, ou dès qu'un lien sortait
        # du dépôt (`../voisin/README.md`), auquel cas `--strict` plantait au lieu de
        # signaler proprement le lien cassé.
        # On résout explicitement depuis RACINE, et on ne convertit que si la cible
        # reste dans le dépôt. `unquote` pour rester cohérent avec le traitement des
        # fragments plus bas (un nom de fichier accentué arrive percent-encodé).
        cible = (base / unquote(m.group(1))).as_posix()
        absolu = (RACINE / cible).resolve()
        if absolu.is_relative_to(RACINE):
            cible = absolu.relative_to(RACINE).as_posix()
        id_cible = table.get(cible)
        if not id_cible:
            alertes.append(f"{rendu['chemin']} → {m.group(1)} (page absente de la doc)")
            return m.group(0)
        # markdown-it percent-encode les caractères non ASCII : les ancres françaises
        # (`#-accès-distant-…`) arrivent ici en `%C3%A8`, à décoder avant comparaison.
        frag = unquote((m.group(2) or "")[1:])
        if frag:
            for essai in (frag, frag.strip("-_"), ancre(frag)):
                if essai in ancres[id_cible]:
                    frag = essai
                    break
            else:
                alertes.append(f"{rendu['chemin']} → {m.group(1)}#{frag} (ancre inconnue)")
                frag = ""
        return f'href="#{id_cible}{"/" + frag if frag else ""}"'

    return RE_LIEN_MD.sub(remplacer, rendu["corps"])


RE_IMG_SRC = re.compile(r'(<img\b[^>]*?\bsrc=")([^"]+)(")', re.IGNORECASE)
MIMES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
         ".gif": "image/gif", ".svg": "image/svg+xml", ".webp": "image/webp"}


def inliner_images(corps: str, chemin: str, alertes: list[str]) -> str:
    """Convertit les images LOCALES du corps en data: URI base64.

    Le chemin écrit dans le markdown est relatif au fichier source, donc juste
    pour GitHub ; il ne résoudrait pas depuis la page unique, qui vit ailleurs
    (`docs/index.html` en local, `_site/index.html` en CI). Plutôt que copier
    les fichiers à côté de la sortie, on les embarque : la page reste UN seul
    fichier autonome, transportable et lisible hors ligne — la promesse tenue
    partout ailleurs dans ce générateur.

    Corollaire : garder les images LÉGÈRES, elles gonflent la page d'environ
    4/3 de leur poids (surcoût du base64).
    """
    base = Path(chemin).parent

    def remplacer(m: re.Match[str]) -> str:
        src = m.group(2)
        if src.startswith(("http://", "https://", "data:", "//")):
            return m.group(0)                      # ressource externe : intacte
        fichier = (RACINE / base / unquote(src)).resolve()
        if not fichier.is_file():
            alertes.append(f"{chemin} → {src} (image introuvable)")
            return m.group(0)
        mime = MIMES.get(fichier.suffix.lower())
        if mime is None:
            alertes.append(f"{chemin} → {src} (format d'image non géré)")
            return m.group(0)
        donnees = base64.b64encode(fichier.read_bytes()).decode("ascii")
        return f"{m.group(1)}data:{mime};base64,{donnees}{m.group(3)}"

    return RE_IMG_SRC.sub(remplacer, corps)


# ===========================================================================
#  Feuille de style
# ===========================================================================

def css_pygments() -> str:
    """Thèmes de coloration Pygments, alignés sur la logique de la palette.

    Même règle que les variables CSS : le SOMBRE est le défaut, le clair ne
    s'applique que si le lecteur l'a explicitement choisi. Sans ça, les blocs de
    code resteraient colorés en thème clair sur une page sombre.
    """
    def defs(style: str, selecteur: str) -> str:
        try:
            return HtmlFormatter(style=style).get_style_defs(selecteur)
        except ClassNotFound:
            return HtmlFormatter().get_style_defs(selecteur)

    sombre = defs("github-dark", ':root:not([data-theme="light"]) .bloc-code pre')
    clair = defs("friendly", ':root[data-theme="light"] .bloc-code pre')
    return (
        f"{sombre}\n{clair}\n"
        # le fond des blocs vient de nos variables, pas du thème Pygments
        ".bloc-code pre{background:none!important}\n"
    )


PALETTE_SOMBRE = """
  --fond:#15161a; --fond-2:#1c1e23; --fond-3:#24272d;
  --texte:#e9eaec; --texte-2:#a5a9b2; --texte-3:#7a7f88;
  --bord:#2b2e35; --bord-fort:#3a3e46;
  --accent:#74a0f7; --accent-doux:#1b2436;
  --code-fond:#1a1c20;
  --danger:#f28b80; --danger-fond:#2a1c1b;
  --astuce:#6bc99a; --astuce-fond:#14231f;
  --info:#74a0f7;   --info-fond:#171f2e;
  --ombre:0 1px 2px rgba(0,0,0,.3),0 4px 14px rgba(0,0,0,.24);
"""

CSS = """
*,*::before,*::after{box-sizing:border-box}
:root{
  --fond:#fdfdfc; --fond-2:#f5f5f3; --fond-3:#ebebe7;
  --texte:#1b1c1f; --texte-2:#5b5e65; --texte-3:#8a8e95;
  --bord:#e3e3df; --bord-fort:#cecec8;
  --accent:#2f6feb; --accent-doux:#eaf1fe;
  --code-fond:#f8f8f6;
  --danger:#c4342b; --danger-fond:#fdf1f0;
  --astuce:#177f50; --astuce-fond:#eff8f3;
  --info:#2f6feb;   --info-fond:#eff4fe;
  --ombre:0 1px 2px rgba(20,20,20,.05),0 4px 12px rgba(20,20,20,.04);
  --mono:ui-monospace,"SF Mono","JetBrains Mono","Cascadia Code",Menlo,Consolas,monospace;
  --sans:system-ui,-apple-system,"Segoe UI",Inter,Roboto,"Helvetica Neue",sans-serif;
  --menu:290px; --toc:15.5rem; --texte-large:52rem;
}
/* SOMBRE PAR DÉFAUT : la palette claire ci-dessus n'est que la base, le sombre
   s'applique sauf si le lecteur a explicitement choisi le clair via la bascule.
   On n'écoute donc PAS prefers-color-scheme — c'est un choix assumé. */
:root:not([data-theme="light"]){__SOMBRE__}
html{scroll-behavior:smooth;-webkit-text-size-adjust:100%}
body{margin:0;background:var(--fond);color:var(--texte);font:16px/1.7 var(--sans);
  -webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline;text-underline-offset:3px}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:4px}

/* ---------- structure ----------
   Le sommaire est une VRAIE colonne de grille (et non un élément `fixed` compensé
   par une marge) : sinon, réserver sa place avec `margin-right` écrase le
   `margin:0 auto` du contenu et le `margin-left:auto` restant décale tout le texte
   vers la droite sur les grands écrans. */
.enveloppe{display:grid;grid-template-columns:var(--menu) minmax(0,1fr);
  min-height:100vh;align-items:start}
.menu{position:sticky;top:0;height:100vh;overflow-y:auto;background:var(--fond-2);
  border-right:1px solid var(--bord);padding:1.4rem 0 3rem;scrollbar-width:thin}
/* `width:100%` est INDISPENSABLE avec `margin-inline:auto` : des marges auto sur un
   élément de grille désactivent l'étirement sur la piste, l'élément est alors
   dimensionné en fit-content — donc plafonné à sa `max-width` (941px) quelle que
   soit la largeur réelle de la piste. Sous 941px de viewport il débordait à droite,
   avec un scroll horizontal global. Avec `width:100%` il suit la piste, et les
   marges auto ne recentrent que lorsqu'il reste de la place. */
.contenu{min-width:0;width:100%;padding:2.4rem clamp(1.2rem,4vw,3.4rem) 6rem;
  max-width:calc(var(--texte-large) + 6.8rem);margin-inline:auto}

/* ---------- menu ---------- */
/* Marque en COLONNE : le badge dépôt sur sa propre ligne. Posé en bout de la
   ligne de titre, il la rétrécissait assez pour couper « Vagrant-KubeADM » et
   l'horodatage en deux (menu à 290px). */
.marque{display:flex;flex-direction:column;align-items:flex-start;gap:.6rem;
  padding:0 1.3rem 1.1rem;font-weight:650;letter-spacing:-.01em}
.marque-titre{display:flex;align-items:center;gap:.65rem}
.marque .logo{font-size:1.5rem;line-height:1}
.marque small{display:block;font-weight:450;color:var(--texte-3);font-size:.74rem;
  letter-spacing:0;font-family:var(--mono)}
/* Badge dépôt, en haut du menu de gauche sous le titre.
   `currentColor` sur le SVG => il suit le thème clair/sombre. */
.marque .depot{display:inline-flex;align-items:center;gap:.3rem;align-self:center;
  padding:.2rem .45rem;border:1px solid var(--bord-fort);border-radius:6px;
  color:var(--texte-2);font-size:.72rem;font-weight:600;letter-spacing:0}
.marque .depot:hover{color:var(--texte);background:var(--fond-3);
  border-color:var(--texte-3);text-decoration:none}
.marque .depot svg{flex:0 0 14px;width:14px;height:14px;fill:currentColor}
.recherche{padding:0 1.1rem 1rem}
.recherche input{width:100%;padding:.5rem .7rem;border:1px solid var(--bord-fort);
  border-radius:8px;background:var(--fond);color:var(--texte);font:inherit;font-size:.87rem}
.groupe > h2{margin:0;padding:.85rem 1.35rem .35rem;font-size:.69rem;font-weight:650;
  text-transform:uppercase;letter-spacing:.09em;color:var(--texte-3)}
.menu a{display:flex;gap:.55rem;align-items:baseline;padding:.34rem 1.35rem;
  color:var(--texte-2);font-size:.89rem;border-left:2px solid transparent}
.menu a:hover{color:var(--texte);background:var(--fond-3);text-decoration:none}
.menu a.actif{color:var(--accent);background:var(--accent-doux);
  border-left-color:var(--accent);font-weight:550}
.menu a .emo{flex:0 0 1.15rem;font-size:.95rem}
.menu a .txt{min-width:0}
.menu a .chemin{display:block;font-size:.7rem;color:var(--texte-3);
  font-family:var(--mono);word-break:break-all;line-height:1.35}
.badge{display:inline-block;margin-left:.35rem;padding:0 .34rem;border-radius:4px;
  background:var(--danger-fond);color:var(--danger);font-size:.63rem;font-weight:650;
  text-transform:uppercase;letter-spacing:.04em;vertical-align:middle}
.badge-langue{background:var(--info-fond);color:var(--info)}

/* ---------- sélecteur de langue ---------- */
.langues{display:flex;gap:.3rem;padding:0 1.1rem 1rem}
.langues button{flex:1;padding:.32rem 0;border:1px solid var(--bord-fort);border-radius:7px;
  background:var(--fond);color:var(--texte-2);font:650 .74rem/1.45 var(--sans);
  letter-spacing:.05em;cursor:pointer;transition:color .12s,border-color .12s}
.langues button:hover{color:var(--accent);border-color:var(--accent)}
.langues button[aria-pressed="true"]{background:var(--accent-doux);color:var(--accent);
  border-color:var(--accent)}

/* ---------- en-tête de page ---------- */
.fil{display:flex;align-items:center;gap:.45rem;flex-wrap:wrap;margin-bottom:.55rem;
  font:.77rem/1.5 var(--mono);color:var(--texte-3)}
.page > h1{margin:.1rem 0 .35rem;font-size:clamp(1.7rem,3.4vw,2.3rem);line-height:1.18;
  letter-spacing:-.022em;font-weight:680}
.page > h1 .emo{margin-right:.45rem}
/* `code` dans un titre : gardé en monospace mais sans le cadre du code inline,
   qui alourdirait un titre de 2rem. */
.page > h1 code{font-size:.86em;font-weight:640;background:var(--fond-3);
  border:1px solid var(--bord);border-radius:7px;padding:.06em .3em}
.page h2 code,.page h3 code,.page h4 code{font-size:.9em;font-weight:inherit}
.sous-titre{margin:0 0 2.2rem;color:var(--texte-2);font-size:1.02rem;max-width:44rem}
.sous-titre > p{margin:0 0 .4rem}

/* ---------- contenu ---------- */
.page h2,.page h3,.page h4{letter-spacing:-.015em;line-height:1.3;scroll-margin-top:1.5rem}
.page h2{margin:2.9rem 0 .9rem;padding-bottom:.42rem;font-size:1.4rem;font-weight:660;
  border-bottom:1px solid var(--bord)}
.page h3{margin:2.1rem 0 .7rem;font-size:1.12rem;font-weight:640}
.page h4{margin:1.6rem 0 .5rem;font-size:1rem;font-weight:640;color:var(--texte-2)}
.page p{margin:0 0 1.05rem}
.page ul,.page ol{margin:0 0 1.1rem;padding-left:1.4rem}
.page li{margin:.28rem 0}
.page li > p{margin:.3rem 0}
.page li::marker{color:var(--texte-3)}
.page hr{margin:2.6rem 0;border:0;border-top:1px solid var(--bord)}
.page strong{font-weight:640;color:var(--texte)}
.page img{max-width:100%;height:auto}
.header-anchor{margin-left:.4rem;color:var(--texte-3);opacity:0;font-weight:400;
  text-decoration:none;transition:opacity .12s}
h2:hover>.header-anchor,h3:hover>.header-anchor,h4:hover>.header-anchor{opacity:1}

/* ---------- code ---------- */
code{font-family:var(--mono);font-size:.875em}
:not(pre) > code{background:var(--fond-3);color:var(--texte);padding:.12em .38em;
  border-radius:5px;border:1px solid var(--bord)}
.bloc-code{position:relative;margin:0 0 1.25rem;background:var(--code-fond);
  border:1px solid var(--bord);border-radius:10px;box-shadow:var(--ombre);overflow:hidden}
.bloc-code::before{content:attr(data-langage);position:absolute;top:0;right:0;
  padding:.18rem .6rem;font:600 .65rem/1.5 var(--mono);letter-spacing:.06em;
  text-transform:uppercase;color:var(--texte-3);background:var(--fond-3);
  border-left:1px solid var(--bord);border-bottom:1px solid var(--bord);
  border-bottom-left-radius:8px}
.bloc-code pre{margin:0;padding:1.55rem 1.05rem 1.05rem;overflow-x:auto;
  font-family:var(--mono);font-size:.845rem;line-height:1.62;tab-size:2}
.bloc-code code{white-space:pre}
.copier{position:absolute;top:2.35rem;right:.55rem;z-index:2;padding:.26rem .55rem;
  border:1px solid var(--bord-fort);border-radius:6px;background:var(--fond);
  color:var(--texte-2);font:550 .72rem/1 var(--sans);cursor:pointer;opacity:0;
  transition:opacity .13s,color .13s}
.bloc-code:hover .copier,.copier:focus-visible{opacity:1}
.copier:hover{color:var(--accent);border-color:var(--accent)}
.copier.ok{color:var(--astuce);border-color:var(--astuce)}

/* ---------- encarts (citations) ---------- */
.encart{margin:0 0 1.25rem;padding:.85rem 1.1rem;border-left:3px solid var(--bord-fort);
  border-radius:0 8px 8px 0;background:var(--fond-2);color:var(--texte-2)}
.encart > :last-child{margin-bottom:0}
.encart .bloc-code{margin:.75rem 0 .35rem;box-shadow:none}
.encart-danger{border-left-color:var(--danger);background:var(--danger-fond)}
.encart-astuce{border-left-color:var(--astuce);background:var(--astuce-fond)}
.encart-info{border-left-color:var(--info);background:var(--info-fond)}

/* ---------- tableaux ---------- */
.table-scroll{overflow-x:auto;margin:0 0 1.3rem;border:1px solid var(--bord);
  border-radius:10px;box-shadow:var(--ombre)}
table{width:100%;border-collapse:collapse;font-size:.895rem}
th,td{padding:.58rem .85rem;text-align:left;vertical-align:top;
  border-bottom:1px solid var(--bord)}
th{background:var(--fond-2);font-weight:640;font-size:.78rem;text-transform:uppercase;
  letter-spacing:.05em;color:var(--texte-2);white-space:nowrap}
tbody tr:last-child td{border-bottom:0}
tbody tr:hover{background:var(--fond-2)}

/* ---------- details ---------- */
details{margin:0 0 1.3rem;border:1px solid var(--bord);border-radius:10px;
  background:var(--fond-2);overflow:hidden}
details > summary{padding:.75rem 1.05rem;font-weight:600;cursor:pointer;list-style:none;
  display:flex;align-items:center;gap:.5rem}
details > summary::-webkit-details-marker{display:none}
details > summary::before{content:"›";display:inline-block;font-size:1.15rem;
  color:var(--texte-3);transition:transform .15s}
details[open] > summary::before{transform:rotate(90deg)}
details > summary:hover{background:var(--fond-3)}
details > :not(summary){margin-left:1.05rem;margin-right:1.05rem}
details > :not(summary):last-child{margin-bottom:1.05rem}

/* ---------- sommaire de droite ---------- */
.sommaire{display:none;position:sticky;top:2.4rem;max-height:calc(100vh - 5rem);
  overflow-y:auto;padding:0 1.4rem 2rem 0;font-size:.82rem}
.sommaire h2{margin:0 0 .5rem;font-size:.69rem;font-weight:650;text-transform:uppercase;
  letter-spacing:.09em;color:var(--texte-3)}
.sommaire a{display:block;padding:.18rem 0 .18rem .7rem;color:var(--texte-2);
  border-left:2px solid var(--bord);line-height:1.45}
.sommaire a:hover{color:var(--texte);text-decoration:none}
.sommaire a.actif{color:var(--accent);border-left-color:var(--accent);font-weight:550}
.sommaire a.n3{padding-left:1.5rem;font-size:.78rem}
@media (min-width:1500px){
  .enveloppe{grid-template-columns:var(--menu) minmax(0,1fr) var(--toc)}
  .sommaire{display:block}
}

/* ---------- barre mobile ---------- */
.barre{display:none;position:sticky;top:0;z-index:20;align-items:center;gap:.7rem;
  padding:.6rem .9rem;background:var(--fond);border-bottom:1px solid var(--bord)}
.barre .langues{padding:0;margin-left:auto;gap:.25rem}
.barre .langues button{padding:.3rem .45rem;min-width:2.3rem}
.bouton-icone{display:grid;place-items:center;width:2.1rem;height:2.1rem;flex:0 0 auto;
  border:1px solid var(--bord-fort);border-radius:8px;background:var(--fond);
  color:var(--texte-2);font-size:1rem;cursor:pointer}
.bouton-icone:hover{color:var(--accent);border-color:var(--accent)}
.theme-flottant{position:fixed;bottom:1.1rem;right:1.1rem;z-index:30;box-shadow:var(--ombre)}
.voile{position:fixed;inset:0;z-index:35;background:rgba(0,0,0,.45);display:none}
@media (max-width:1000px){
  /* minmax(0,1fr) et NON 1fr : une piste `1fr` garde un min-width:auto implicite,
     donc elle refuse de descendre sous la largeur intrinsèque de son contenu. Les
     blocs de code et les tableaux larges élargissaient alors la colonne au-delà du
     viewport => tout le texte débordait à droite, avec un scroll horizontal global.
     Le desktop utilisait déjà minmax(0,1fr) ; seul le mobile avait été oublié. */
  .enveloppe{grid-template-columns:minmax(0,1fr)}
  .barre{display:flex}
  .menu{position:fixed;inset:0 auto 0 0;width:min(86vw,var(--menu));z-index:40;
    transform:translateX(-100%);transition:transform .2s ease;box-shadow:var(--ombre)}
  .menu.ouvert{transform:none}
  .voile.ouvert{display:block}
  .contenu{padding:1.6rem 1.15rem 5rem}
  .theme-flottant{display:none}
}
@media print{
  .menu,.sommaire,.barre,.copier,.theme-flottant,.header-anchor,.voile,
  .langues{display:none!important}
  .enveloppe{grid-template-columns:minmax(0,1fr)}
  .page{display:block!important;page-break-after:always}
  .bloc-code,.table-scroll{box-shadow:none}
}
.page{display:none}
.page.visible{display:block}
.pied{margin-top:4rem;padding-top:1.3rem;border-top:1px solid var(--bord);
  color:var(--texte-3);font-size:.79rem;display:flex;justify-content:space-between;
  gap:1rem;flex-wrap:wrap}
""".replace("__SOMBRE__", PALETTE_SOMBRE)


JS = r"""
(() => {
  const LANGUES = __LANGUES__;
  const LIBELLES = __LIBELLES__;
  const DEFAUT = __DEFAUT__;

  const pages = [...document.querySelectorAll('.page')];
  const liens = [...document.querySelectorAll('.menu a[data-page]')];
  const menu  = document.querySelector('.menu');
  const voile = document.querySelector('.voile');
  const boite = document.querySelector('.sommaire');
  const champ = document.querySelector('.recherche input');
  let observateur = null;

  /* --- langue : mémorisée, mais toujours déduite de la page affichée --- */
  const CLE_LANGUE = 'kubeadm-doc-langue';
  const memoLangue = localStorage.getItem(CLE_LANGUE);
  let langue = LANGUES.includes(memoLangue) ? memoLangue : DEFAUT;
  const mots = () => LIBELLES[langue];

  const majLangue = (suivante) => {
    langue = suivante;
    localStorage.setItem(CLE_LANGUE, langue);
    document.documentElement.lang = langue;
    const m = mots();
    document.querySelectorAll('.arbre').forEach(a => { a.hidden = a.dataset.langue !== langue; });
    document.querySelectorAll('.langues button').forEach(b => {
      b.setAttribute('aria-pressed', String(b.dataset.langue === langue));
    });
    champ.placeholder = m.recherche;
    champ.setAttribute('aria-label', m.recherche_aria);
    document.querySelectorAll('[data-menu-toggle]').forEach(b => b.setAttribute('aria-label', m.menu));
    document.querySelectorAll('.langues').forEach(g => g.setAttribute('aria-label', m.langue_aria));
    document.querySelectorAll('[data-depot]').forEach(a => {
      a.setAttribute('aria-label', m.depot); a.setAttribute('title', m.depot);
    });
    document.querySelectorAll('.copier').forEach(b => { b.textContent = m.copier; });
    majTheme();
    if (boite.firstElementChild) boite.firstElementChild.textContent = m.sommaire;
  };

  /* --- sommaire de la page affichée + surlignage à la lecture --- */
  const construireSommaire = (page) => {
    const titres = [...page.querySelectorAll('h2[id],h3[id]')];
    observateur?.disconnect();
    if (titres.length < 3) { boite.innerHTML = ''; return; }
    boite.innerHTML = `<h2>${mots().sommaire}</h2>` + titres.map(h => {
      const libelle = h.textContent.replace(/#$/, '').trim();
      return `<a href="#${page.id}/${h.id}" data-pour="${h.id}"
                 class="${h.tagName === 'H3' ? 'n3' : ''}">${libelle}</a>`;
    }).join('');
    const ancres = new Map([...boite.querySelectorAll('a')].map(a => [a.dataset.pour, a]));
    observateur = new IntersectionObserver(entrees => {
      for (const e of entrees) {
        if (!e.isIntersecting) continue;
        ancres.forEach(a => a.classList.remove('actif'));
        ancres.get(e.target.id)?.classList.add('actif');
      }
    }, { rootMargin: '-8% 0px -80% 0px' });
    titres.forEach(h => observateur.observe(h));
  };

  /* --- routage : #<langue>/<page>/<section> ---
     L'ancien format (#<page>/<section>, sans langue) reste accepté : les liens
     déjà partagés continuent d'ouvrir la bonne page, dans la langue courante. */
  const afficher = (id, section) => {
    const cible = pages.find(p => p.id === id)
               ?? pages.find(p => p.dataset.langue === langue)
               ?? pages[0];
    if (cible.dataset.langue !== langue) majLangue(cible.dataset.langue);
    pages.forEach(p => p.classList.toggle('visible', p === cible));
    liens.forEach(a => {
      const actif = a.dataset.page === cible.id;
      a.classList.toggle('actif', actif);
      actif ? a.setAttribute('aria-current', 'page') : a.removeAttribute('aria-current');
    });
    construireSommaire(cible);
    document.title = cible.dataset.titre + ' · Vagrant-KubeADM';
    const h = section && cible.querySelector('[id="' + CSS.escape(section) + '"]');
    h ? h.scrollIntoView() : window.scrollTo(0, 0);
  };
  const route = () => {
    const parts = decodeURIComponent(location.hash.slice(1)).split('/').filter(Boolean);
    return LANGUES.includes(parts[0])
      ? { id: parts.slice(0, 2).join('/'), section: parts[2] }
      : { id: parts.length ? langue + '/' + parts[0] : '', section: parts[1] };
  };
  const router = () => { const r = route(); afficher(r.id, r.section); };

  /* --- bascule de langue : même page, autre version --- */
  document.querySelectorAll('.langues button').forEach(b => b.addEventListener('click', () => {
    const suivante = b.dataset.langue;
    if (suivante === langue) return;
    const courante = pages.find(p => p.classList.contains('visible'));
    const section = route().section;
    majLangue(suivante);
    location.hash = '#' + suivante + '/' + (courante?.dataset.doc ?? '')
                  + (section ? '/' + section : '');
    router();   /* si le hash n'a pas changé (page absente), on rend quand même */
  }));

  /* --- recherche (titre, chemin, sections) ; « / » pour cibler le champ --- */
  champ.addEventListener('input', () => {
    const q = champ.value.trim().toLowerCase();
    liens.forEach(a => { a.hidden = !!q && !a.dataset.recherche.includes(q); });
    document.querySelectorAll('.groupe').forEach(g => {
      g.hidden = ![...g.querySelectorAll('a')].some(a => !a.hidden);
    });
  });
  document.addEventListener('keydown', e => {
    if (e.key === '/' && document.activeElement !== champ) { e.preventDefault(); champ.focus(); }
    else if (e.key === 'Escape' && document.activeElement === champ) {
      champ.value = ''; champ.dispatchEvent(new Event('input')); champ.blur();
    }
  });

  /* --- copier un bloc de code --- */
  document.addEventListener('click', async e => {
    const b = e.target.closest('.copier');
    if (!b) return;
    const m = mots();
    try {
      await navigator.clipboard.writeText(b.parentElement.querySelector('code').innerText);
      b.textContent = m.copie; b.classList.add('ok');
    } catch { b.textContent = m.echec; }
    setTimeout(() => { b.textContent = mots().copier; b.classList.remove('ok'); }, 1600);
  });

  /* --- thème : SOMBRE par défaut, bascule mémorisée --- */
  const CLE = 'kubeadm-doc-theme';
  const memo = localStorage.getItem(CLE);
  if (memo) document.documentElement.dataset.theme = memo;
  function majTheme() {
    const sombre = (document.documentElement.dataset.theme || 'dark') === 'dark';
    const m = mots();
    document.querySelectorAll('[data-theme-toggle]').forEach(b => {
      b.textContent = sombre ? '☀' : '☾';
      b.title = sombre ? m.vers_clair : m.vers_sombre;
      b.setAttribute('aria-label', b.title);
    });
  }
  document.querySelectorAll('[data-theme-toggle]').forEach(b => b.addEventListener('click', () => {
    const suivant = (document.documentElement.dataset.theme || 'dark') === 'dark' ? 'light' : 'dark';
    document.documentElement.dataset.theme = suivant;
    localStorage.setItem(CLE, suivant);
    majTheme();
  }));

  /* --- menu mobile --- */
  const basculer = ouvrir => {
    menu.classList.toggle('ouvert', ouvrir);
    voile.classList.toggle('ouvert', ouvrir);
  };
  document.querySelector('[data-menu-toggle]').addEventListener('click',
    () => basculer(!menu.classList.contains('ouvert')));
  voile.addEventListener('click', () => basculer(false));
  liens.forEach(a => a.addEventListener('click', () => basculer(false)));

  addEventListener('hashchange', router);
  majLangue(langue);
  router();
})();
"""


# ===========================================================================
#  Assemblage
# ===========================================================================

def selecteur_langue(mots: dict[str, str]) -> str:
    """Boutons EN/FR. Rendu deux fois (barre latérale et barre mobile)."""
    boutons = "".join(
        f'<button type="button" data-langue="{l}" aria-pressed="false">{l.upper()}</button>'
        for l in LANGUES
    )
    return (f'<div class="langues" role="group" '
            f'aria-label="{html.escape(mots["langue_aria"], quote=True)}">{boutons}</div>')


# Marque officielle GitHub (viewBox 16x16, tracé unique). Inline car la page doit
# rester auto-contenue : aucune requête réseau au chargement.
SVG_GITHUB = (
    '<svg viewBox="0 0 16 16" aria-hidden="true" focusable="false"><path d="M8 0C3.58 0 '
    '0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01'
    '.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 '
    '1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87'
    '.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36'
    '.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 '
    '3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55'
    '.38A8.012 8.012 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg>'
)


def lien_depot(mots: dict[str, str]) -> str:
    """Badge « GitHub » de la ligne de marque, en haut du menu de gauche.

    Le libellé visible reste « GitHub » dans les deux langues (c'est un nom
    propre) ; seul l'intitulé accessible est traduit, et le JS le remet à jour
    au changement de langue (cf. majLangue).
    """
    intitule = html.escape(mots["depot"], quote=True)
    return (f'<a class="depot" href="{DEPOT_URL}" target="_blank" rel="noopener noreferrer"'
            f' data-depot title="{intitule}" aria-label="{intitule}">{SVG_GITHUB}'
            f'<span>GitHub</span></a>')


def rendre(docs: list[dict]) -> list[dict]:
    """Rend chaque document dans chaque langue (une entrée par page HTML)."""
    md = creer_convertisseur()
    rendus: list[dict] = []
    for doc in docs:
        for langue in LANGUES:
            chemin = doc["chemins"][langue]
            page = {
                "chemin": chemin,
                "emoji": doc["emoji"],
                "texte": lire(chemin),
                "id": f"{langue}/{doc['id']}",
            }
            r = convertir(md, page)
            rendus.append({
                **r,
                "id": page["id"],
                "doc": doc["id"],
                "langue": langue,
                "chemin": chemin,
                "groupe": doc["groupe"][langue],
                "suivi": doc["suivi"],
                # un document sans miroir s'affiche en anglais dans le menu français ;
                # ceux de SANS_MIROIR l'assument et ne portent pas de badge
                "traduit": (doc["chemins"]["en"] != doc["chemins"]["fr"]
                            or langue == "en" or doc["chemin"] in SANS_MIROIR),
            })
    return rendus


def construire(rendus: list[dict], version: str, alertes: list[str]) -> str:
    # index chemin → route, par langue : les liens d'une page française visent
    # les miroirs français ; le chemin anglais sert de repli (page non traduite).
    index: dict[str, dict[str, str]] = {l: {} for l in LANGUES}
    ancres: dict[str, set[str]] = {}
    for r in rendus:
        index[r["langue"]][r["chemin"]] = r["id"]
        ancres[r["id"]] = set(RE_ID_TITRE.findall(r["corps"]))
    for r in rendus:
        index[r["langue"]].setdefault(
            next(x["chemin"] for x in rendus
                 if x["doc"] == r["doc"] and x["langue"] == "en"), r["id"])

    articles: list[str] = []
    menus: dict[str, dict[str, list[str]]] = {l: {} for l in LANGUES}

    for r in rendus:
        mots = LIBELLES[r["langue"]]
        corps = inliner_images(resoudre(r, index, ancres, alertes),
                               r["chemin"], alertes)
        badges = ""
        if not r["suivi"]:
            badges += (f'<span class="badge" title="{html.escape(mots["badge_titre"], quote=True)}">'
                       f'{html.escape(mots["badge"])}</span>')
        if not r["traduit"]:
            badges += (f'<span class="badge badge-langue" '
                       f'title="{html.escape(mots["badge_langue_titre"], quote=True)}">'
                       f'{html.escape(mots["badge_langue"])}</span>')

        # premier encart promu en chapeau sous le titre (le H1 neutralisé laisse
        # des blancs en tête : d'où le lstrip avant de matcher)
        chapeau = ""
        corps = corps.lstrip()
        m = re.match(r'<blockquote class="encart[^"]*">(.*?)</blockquote>\s*', corps, re.DOTALL)
        if m:
            chapeau, corps = m.group(1), corps[m.end():]

        articles.append(
            f'<article class="page" id="{r["id"]}" data-doc="{r["doc"]}" '
            f'data-langue="{r["langue"]}" '
            f'data-titre="{html.escape(r["titre_texte"], quote=True)}">'
            f'<div class="fil"><span>{html.escape(r["chemin"])}</span>{badges}</div>'
            f'<h1><span class="emo">{r["emoji"]}</span>{r["titre_html"]}</h1>'
            f'{f"""<div class="sous-titre">{chapeau}</div>""" if chapeau else ""}'
            f'{corps}'
            f'<div class="pied">'
            f'<span>{html.escape(mots["source"])} <code>{html.escape(r["chemin"])}</code></span>'
            f'<span>{len(r["sommaire"])} {html.escape(mots["sections"])}</span></div>'
            "</article>"
        )

        recherche = html.escape(" ".join(
            [r["titre_texte"], r["chemin"], *(s["titre"] for s in r["sommaire"])]).lower(),
            quote=True)
        menus[r["langue"]].setdefault(r["groupe"], []).append(
            f'<a href="#{r["id"]}" data-page="{r["id"]}" data-recherche="{recherche}">'
            f'<span class="emo">{r["emoji"]}</span>'
            f'<span class="txt">{html.escape(r["titre_texte"])}{badges}'
            f'<span class="chemin">{html.escape(r["chemin"])}</span></span></a>'
        )

    arbres = []
    for langue in LANGUES:
        ordre = [g[0][langue] for g in GROUPES] + [AUTRES[langue]]
        nav = "".join(
            f'<nav class="groupe"><h2>{html.escape(g)}</h2>{"".join(menus[langue][g])}</nav>'
            for g in ordre if g in menus[langue]
        )
        arbres.append(f'<div class="arbre" data-langue="{langue}" hidden>{nav}</div>')

    mots = LIBELLES[LANGUE_DEFAUT]
    js = (JS.replace("__LANGUES__", json.dumps(list(LANGUES)))
            .replace("__LIBELLES__", json.dumps(LIBELLES, ensure_ascii=False))
            .replace("__DEFAUT__", json.dumps(LANGUE_DEFAUT)))

    return f"""<!doctype html>
<html lang="{LANGUE_DEFAUT}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark light">
<meta name="generator" content="docs/build.py">
<meta name="description" content="{html.escape(mots['sous_titre'], quote=True)}">
<title>Vagrant-KubeADM · Documentation</title>
<style>
{CSS}
{css_pygments()}
</style>
</head>
<body>
<div class="voile"></div>
<header class="barre">
  <button class="bouton-icone" data-menu-toggle aria-label="{html.escape(mots['menu'], quote=True)}">☰</button>
  <strong>Vagrant-KubeADM</strong>
  {selecteur_langue(mots)}
  <button class="bouton-icone" data-theme-toggle>☀</button>
</header>
<div class="enveloppe">
  <aside class="menu">
    <div class="marque">
      <div class="marque-titre">
        <span class="logo">🐧</span>
        <span>Vagrant-KubeADM<small>{html.escape(version)}</small></span>
      </div>
      {lien_depot(mots)}
    </div>
    {selecteur_langue(mots)}
    <div class="recherche">
      <input type="search" placeholder="{html.escape(mots['recherche'], quote=True)}"
             aria-label="{html.escape(mots['recherche_aria'], quote=True)}">
    </div>
    {"".join(arbres)}
  </aside>
  <main class="contenu">{"".join(articles)}</main>
  <aside class="sommaire" aria-label="{html.escape(mots['sommaire'], quote=True)}"></aside>
</div>
<button class="bouton-icone theme-flottant" data-theme-toggle>☀</button>
<script>{js}</script>
</body>
</html>
"""


def main() -> int:
    ap = argparse.ArgumentParser(description="Génère la documentation HTML du lab.")
    ap.add_argument("--out", default=str(RACINE / "docs" / "index.html"),
                    help="fichier de sortie (défaut : docs/index.html)")
    ap.add_argument("--strict", action="store_true",
                    help="échoue si un lien interne ou une ancre ne résout pas")
    args = ap.parse_args()

    docs = decouvrir()
    if not docs:
        print("Aucun fichier markdown trouvé.", file=sys.stderr)
        return 1
    for doc in docs:  # identifiant de route, stable et lisible
        doc["id"] = re.sub(r"[^a-z0-9]+", "-",
                           doc["chemin"].lower().removesuffix(".md")).strip("-")

    alertes: list[str] = []
    rendus = rendre(docs)
    sortie = Path(args.out)
    sortie.parent.mkdir(parents=True, exist_ok=True)
    sortie.write_text(
        construire(rendus, git("log", "-1", "--format=%h · %cs") or "local", alertes),
        encoding="utf-8")

    affiche = sortie.relative_to(RACINE) if sortie.is_relative_to(RACINE) else sortie
    print(f"✅ {affiche} — {len(docs)} documents × {len(LANGUES)} langues "
          f"= {len(rendus)} pages, {sortie.stat().st_size // 1024} Ko")
    for doc in docs:
        etat = "" if doc["suivi"] else "  (non commité)"
        miroir = doc["chemins"]["fr"]
        if miroir == doc["chemin"]:
            # distinguer l'oubli (à corriger) du choix assumé (SANS_MIROIR)
            etat += ("  (EN seulement, assumé)" if doc["chemin"] in SANS_MIROIR
                     else "  (⚠️ pas de miroir FR)")
            miroir = "—"
        print(f"   {doc['emoji']} {doc['chemin']:44s} ↔ {miroir}{etat}")

    if alertes:
        print(f"\n⚠️ {len(alertes)} lien(s) interne(s) non résolu(s) :", file=sys.stderr)
        for a in sorted(set(alertes)):
            print(f"   {a}", file=sys.stderr)
        if args.strict:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
