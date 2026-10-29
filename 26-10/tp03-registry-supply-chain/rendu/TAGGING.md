# Politique de tags des images Shop SAS

## Tags produits par la CI

| Tag | Exemple | Produit quand | Mutable ? | Usage |
|---|---|---|---|---|
| `MAJ.MIN.PATCH` (semver complet) | `shopapi:1.4.2` | tag git `v1.4.2` | **Immuable** | prod, préprod, rollback |
| `MAJ.MIN` | `shopapi:1.4` | même release | mutable (suit le dernier patch) | environnements de dev/test qui veulent les correctifs |
| `MAJ` | `shopapi:1` | même release | mutable | idem, déconseillé hors dev |
| `sha-<commit court>` | `shopapi:sha-2fdfd4c` | chaque build de `main` | **Immuable** | traçabilité build ↔ commit, déploiement d'intégration |
| `pr-<n>` | `shopapi:pr-42` | chaque push sur une PR | mutable | environnements éphémères de revue, purgé à la fermeture de la PR |
| `main` | `shopapi:main` | chaque build de `main` | mutable | env. d'intégration « dernière version » |
| `latest` | — | **jamais en prod** | mutable | toléré seulement pour les outils locaux |

Règles :

1. **Un tag semver complet n'est jamais réécrit.** Une correction donne `1.4.3`, pas un nouveau `1.4.2`.
   `release-gate.sh` est le seul chemin vers ces tags (compte `ci`).
2. Les tags `sha-*` sont la clé de traçabilité : le label `org.opencontainers.image.revision` de l'image doit
   être égal au commit du tag.
3. Rétention (`retention.sh`) : on garde les 10 tags hors semver les plus récents par dépôt ; les tags
   semver ne sont jamais supprimés automatiquement.
4. Retag **sans pull** (le manifeste est recopié sous un autre nom, aucun blob n'est transféré) :
   ```bash
   crane tag registry.local:5000/shopapi:sha-2fdfd4c 1.4.2      # promotion d'un build en release
   skopeo copy docker://registry.local:5000/shopapi:1.4.2 docker://registry.local:5000/shopapi:1.4
   ```
   Démonstration : [`crane.txt`](crane.txt), les logs du registre ne montrent que des `PUT /v2/shopapi/manifests/<tag>`.

## Pourquoi `latest` est interdit en prod

- **Ce n'est pas « la dernière version »** : c'est simplement le tag par défaut quand on n'en précise pas.
  Il pointe sur ce qui a été poussé en dernier avec ce nom, y compris un build de branche.
- **Non reproductible** : deux nœuds qui tirent `latest` à une heure d'écart peuvent exécuter deux images
  différentes. Un rollback « vers latest » ne veut rien dire.
- **Cache trompeur** : un nœud qui a déjà `latest` ne le re-tire pas (`pull_policy: missing`) ; un autre si.
- **Pas d'audit** : impossible de savoir quelle version a tourné au moment d'un incident (c'est l'incident
  du vendredi soir : une `latest` réécrite).
- **Signature** : la signature cosign est attachée au **digest**, pas au tag ; un tag mutable peut être
  déplacé vers une image non signée (démontré dans [`supply-chain/cosign.txt`](supply-chain/cosign.txt) :
  après re-push sous `1.4.2`, `cosign verify` → `no signatures found`).

## Référencer une image par digest dans un `compose.yml`

Le digest (`sha256:…` du manifeste) est l'identifiant **immuable** du contenu. Le tag reste lisible pour
l'humain mais seul le digest est utilisé pour le pull :

```yaml
services:
  api:
    # tag pour la lisibilité, digest pour l'immutabilité : Docker ignore le tag quand un digest est présent
    image: registry.local:5000/shopapi:1.4.2@sha256:d01cdb29e942defb71ba75504a8b3f567d96d607de11de2c4038f5f8edb7a96c
```

Obtenir le digest :

```bash
./registry-api.sh digest shopapi 1.4.2                                  # HEAD /v2/shopapi/manifests/1.4.2
crane digest registry.local:5000/shopapi:1.4.2
docker buildx imagetools inspect registry.local:5000/shopapi:1.4.2 --format '{{.Manifest.Digest}}'
```

Pour une image multi-architecture, c'est le digest de l'**index** qu'on référence (chaque nœud
résout ensuite le manifeste de sa plateforme). La mise à jour des digests dans les fichiers compose
est automatisée par la CI (Renovate / Dependabot savent mettre à jour `image@sha256:`).
