# TP03 — Registre privé et supply chain : rapport

## Contenu

| Fichier | Rôle |
|---|---|
| [`registry/compose.yml`](registry/compose.yml) | registre TLS + htpasswd, UI, mirror Docker Hub |
| [`registry/config.yml`](registry/config.yml), [`registry/mirror-config.yml`](registry/mirror-config.yml) | configuration montée (`configs:`) |
| [`registry/gen-certs.sh`](registry/gen-certs.sh) | CA interne + certificat serveur (SAN `registry.local`, `localhost`, `127.0.0.1`) + installation de la CA côté client |
| [`registry/gen-htpasswd.sh`](registry/gen-htpasswd.sh) | comptes `ci` et `dev` en bcrypt (coût 10) |
| [`registry-api.sh`](registry-api.sh) | client de l'API Registry v2 (curl + jq) |
| [`retention.sh`](retention.sh) | garde les N tags hors semver les plus récents |
| [`TAGGING.md`](TAGGING.md) | politique de tags |
| [`release-gate.sh`](release-gate.sh) | porte de release |
| [`verified-run.sh`](verified-run.sh) | bonus B3 : `docker run` conditionné à `cosign verify` |
| `supply-chain/` | `sbom.json`, `cosign.pub` (la clé privée est gitignorée), sorties de scan / signature / gate |
| `*.txt` | transcripts des étapes |

Mise en route :

```bash
cd registry
./gen-certs.sh && ./gen-htpasswd.sh
echo "127.0.0.1 registry.local" | sudo tee -a /etc/hosts
docker compose up -d --wait
# daemon : "registry-mirrors": ["http://localhost:5001"] dans /etc/docker/daemon.json (Docker Desktop : ~/.docker/daemon.json), puis redémarrage
```

### Contraintes du poste et adaptations

- **Pas de droits sudo** : l'entrée `/etc/hosts` pour `registry.local` n'a pas pu être ajoutée. Côté
  `curl`, le nom est résolu avec `--resolve registry.local:5000:127.0.0.1` et le certificat est **vérifié
  strictement** (`--cacert certs/ca.crt`, pas de `-k`). Côté daemon Docker, j'ai utilisé `localhost:5000`
  (présent dans le SAN). Attention : `127.0.0.0/8` fait partie des *insecure registries* par défaut du
  daemon, donc la validation TLS côté daemon n'est stricte qu'avec le nom `registry.local`.
- **Docker Desktop** : la CA est installée dans `~/.docker/certs.d/<hôte>:5000/ca.crt` (équivalent de
  `/etc/docker/certs.d` pour le daemon de la VM), le `daemon.json` est `~/.docker/daemon.json`.
- Le `credsStore` `desktop` (basé sur `pass`, non initialisé) empêchait `docker login` d'enregistrer les
  identifiants : `DOCKER_CONFIG` dédié au TP, sans `credsStore`.

## 1. Registre sécurisé

Validation ([`validation-registry.txt`](validation-registry.txt)) :

| Test | Résultat |
|---|---|
| `curl https://registry.local:5000/v2/` (CA interne) | `401 UNAUTHORIZED` |
| sans la CA | `SSL certificate problem: unable to get local issuer certificate` |
| `curl -u dev:dev-pull-2024 …/v2/_catalog` | `{"repositories":["shopapi"]}` |
| mauvais mot de passe | `401` |
| `docker login localhost:5000 -u ci` puis `docker push …/shopapi:1.4.2` | `Login Succeeded`, push OK |
| `docker info` | `RegistryConfig.Mirrors = ["http://localhost:5001/"]` |
| `docker pull alpine:3.20` (1er) | 7,3 s ; le mirror reçoit `HEAD /v2/library/alpine/manifests/3.20` + blobs, et liste `library/alpine` dans son catalogue |
| `docker rmi` + `docker pull alpine:3.20` (2e) | **1,1 s**, servi par le mirror depuis son volume (chaque requête apparaît 2× dans ses logs) |
| UI `http://localhost:8081` | liste des dépôts (proxy nginx de l'UI vers `https://registry:5000`, donc pas de CORS) |

Choix : configuration par fichier monté (`configs:`) au lieu de variables d'environnement, volumes nommés
`registry-data` / `mirror-data`, `storage.delete.enabled: true`, `healthcheck` sur `/` (répond 200 sans
authentification, alors que `/v2/` répond 401), `restart: unless-stopped`, rotation des logs.

### Question : `htpasswd` suffit-il en entreprise ?

Non. Démonstration : avec `registry:2`, **tout compte authentifié a tous les droits**. Le compte `dev`
censé être en lecture seule a pu pousser `dev-test:1` (et pourrait supprimer des manifestes). Le registre
de la distribution ne gère ni rôles, ni droits par dépôt.

Limites de htpasswd + `registry:2` : pas de RBAC, pas d'annuaire (LDAP/AD/OIDC/SSO), mots de passe
partagés dans un fichier à redéployer, pas d'audit des actions, pas de quotas, pas d'immutabilité des
tags, garbage-collect manuel et hors ligne, aucune analyse de vulnérabilités, pas de réplication.

Ce qu'apportent **Harbor, Nexus, Artifactory, ECR/ACR/GAR** :
- **RBAC** par projet/dépôt (lecture, push, admin), comptes robots pour la CI, SSO (OIDC/LDAP, IAM cloud) ;
- **scan intégré** (Trivy dans Harbor, Xray dans Artifactory, Inspector/Defender/Artifact Analysis dans le cloud)
  et politiques « pas de pull si CVE critique » ;
- **immutabilité des tags** (règles `1.*` non réécrivables), **politiques de rétention** et GC planifié ;
- **réplication** entre sites/régions et **proxy cache** de Docker Hub/GHCR intégrés ;
- **quotas** de stockage par projet, **audit log**, vérification de signatures cosign/Notation à l'entrée.

## 2. API du registre

Transcript : [`api-session.txt`](api-session.txt).

- Dépôts : `GET /v2/_catalog` ; tags : `GET /v2/<dépôt>/tags/list`.
- Digest : `HEAD /v2/<dépôt>/manifests/<tag>` avec `Accept:` listant les types OCI **et** Docker v2 ;
  en-tête `Docker-Content-Digest`. Sans le bon `Accept`, le registre répond `404` pour un index OCI (les
  images poussées par le store containerd de Docker Desktop sont des index).
- Suppression : `DELETE /v2/<dépôt>/manifests/<digest>` → `202 Accepted` (la suppression par **tag** n'existe pas).
- GC : `docker compose exec registry registry garbage-collect /etc/docker/registry/config.yml`, puis
  `docker compose restart registry` pour vider le cache `inmemory` des descripteurs de blobs.

**Deux tags sur le même manifeste** : `candidate` et `build-105` pointaient sur `sha256:fe4163ea…`.
Supprimer « candidate » par son digest a fait disparaître **les deux tags** : on supprime un manifeste,
et tous les tags qui le référencent disparaissent avec lui. D'où la règle de `retention.sh` : ne jamais
supprimer un digest partagé avec un tag conservé ou un tag semver.

**Constat important sur `--delete-untagged`** : un premier essai avec
`garbage-collect --delete-untagged` a **cassé les images de tous les dépôts** (`shopapi` et les tags
`demo` restants renvoyaient `404`, 40 Mo de blobs supprimés : [`api-session-delete-untagged-bug.txt`](api-session-delete-untagged-bug.txt)).
Les images poussées par Docker Desktop (store containerd) sont des **index OCI** ; leurs manifestes enfants
ne portent pas de tag et `registry:2.8` les considère comme « untagged » → supprimés. Bug connu de
distribution v2.8 ; ne pas utiliser `--delete-untagged` avec des index (multi-arch, attestations). J'ai
réinitialisé le volume et refait la séance sans cette option. Contrepartie : sans elle, seul le manifeste
d'index est collecté, les manifestes enfants et leurs couches restent (44,4 → 44,2 Mo). C'est une raison de
plus pour passer à un registre d'entreprise (Harbor gère correctement les index).

`retention.sh demo 2` (dry-run puis réel) : garde `build-104` et `build-103` (les plus récents d'après le
champ `.created` du blob de configuration), supprime `build-102` et `build-101`, conserve `1.0.0` et `1.1.0`
(semver).

## 3. Politique de tags

Voir [`TAGGING.md`](TAGGING.md). Retag sans pull démontré avec `crane` en conteneur
([`crane.txt`](crane.txt)) : `crane tag localhost:5000/shopapi:1.4.2 1.4`, puis `1` et `sha-2fdfd4c` ;
tous ont le même digest et les logs du registre ne montrent que 3 `PUT /v2/shopapi/manifests/<tag>`,
sans aucun upload de blob.

## 4. SBOM, scan, signature

Transcripts : [`supply-chain/scan.txt`](supply-chain/scan.txt), [`supply-chain/cosign.txt`](supply-chain/cosign.txt).

**SBOM** : `syft shopapi:1.4.2 -o spdx-json` → **134 paquets** (paquets apk + modules npm + binaire `node 20.20.2`).

**Scan** : sur l'image livrée au TP01 (`alpine:3.21.2`, `node:20.18.1`), trivy trouve
**25 CVE HIGH/CRITICAL corrigeables** (OpenSSL 3.3.2 : 10 CVE dont CVE-2026-31789 CRITICAL ; musl ; zlib).
La base épinglée à une version **patch** de janvier 2025 ne reçoit plus les correctifs. Correction
apportée au Dockerfile du TP01 : `node:20.20.2-alpine3.23` + `alpine:3.23.7` → **0 CVE**, image 175 Mo.
Leçon : épingler une version est indispensable à la reproductibilité, mais impose un processus de mise à
jour (Renovate/Dependabot + rebuild planifié). Note : Node 20 est en fin de vie depuis avril 2026, la
prochaine étape est Node 22 (`node:22.23.4-alpine3.23`).

À l'inverse, `shopapi:legacy` affiche 0 CVE OS corrigeable (Ubuntu à jour car `apt-get update` lors du
build du jour) mais `trivy --scanners secret` **retrouve la clé AWS du TP01** : `CRITICAL: AWS
(aws-access-key-id) /app/.env:4 (added by 'COPY . /app')`.

**Signature** (clé `cosign.key` sans mot de passe pour le TP, `--tlog-upload=false` : pas de publication
dans le journal public Rekor depuis un registre privé, d'où `--insecure-ignore-tlog=true` à la vérification) :

```
cosign sign   --key cosign.key  localhost:5000/shopapi@sha256:d01cdb29…    # on signe un digest
cosign verify --key cosign.pub  localhost:5000/shopapi:1.4.2               # OK : docker-manifest-digest sha256:d01cdb29…
cosign attest --key cosign.key --type spdxjson --predicate sbom.json …      # verify-attestation : 134 paquets
```

**Ce que la signature crée dans le registre** : aucun nouveau dépôt (le `_catalog` reste `demo shopapi`),
mais deux **tags** dans le dépôt de l'image, nommés d'après le digest signé :
`sha256-d01cdb29….sig` (signature) et `sha256-d01cdb29….att` (attestation SBOM). Ce sont des
artefacts OCI ordinaires (`cosign tree` les liste).

**Re-push d'une image modifiée sous le même tag** : le tag `1.4.2` pointe alors sur un nouveau digest
(`sha256:9bc556b2…`) et `cosign verify …:1.4.2` → `Error: no signatures found` (exit 10), alors que
`cosign verify …@sha256:d01cdb29…` reste valide. **La signature suit le digest, pas le tag.** Conséquences :
signer et déployer par digest, rendre les tags de release immuables, vérifier la signature au moment
du déploiement (bonus B3).

## 5. Porte de release

[`release-gate.sh`](release-gate.sh) `IMAGE [--push REGISTRY_IMAGE]` exécute **tous** les contrôles puis
liste les échecs (plus utile en CI qu'un arrêt au premier problème). Transcript :
[`supply-chain/release-gate.txt`](supply-chain/release-gate.txt).

| Image | Labels OCI | Non-root | HEALTHCHECK | CVE corrigeables | Secrets | Verdict |
|---|---|---|---|---|---|---|
| `shopapi:legacy` | ✘ revision, source | ✘ root | ✘ | ✔ | ✘ clé AWS | **REFUSÉ** (5 échecs), exit 1 |
| `shopapi:1.4.2` (base alpine 3.21.2) | ✔ | ✔ | ✔ | ✘ 25 | ✔ | **REFUSÉ** (1 échec), exit 1 |
| `shopapi:1.4.2` (base alpine 3.23.7) | ✔ | ✔ | ✔ | ✔ | ✔ | **ACCEPTÉ**, exit 0 |

Pour l'image acceptée avec `--push localhost:5000/shopapi:1.4.2` : push, SBOM syft (134 paquets),
`cosign sign` et `cosign attest` sur la référence **par digest** renvoyée par le push, puis `cosign verify`.
Le script affiche en dernier la référence `dépôt@sha256:…` à utiliser pour le déploiement.

## Bonus

### B3 — `verified-run.sh`

`./verified-run.sh localhost:5000/shopapi:1.4.2 --rm -- node -e "console.log(process.version)"` →
`✔ signature vérifiée`, puis lancement **par digest** (`v20.20.2`). Sur `localhost:5000/demo:1.1.0`
(jamais signée) : `✘ signature invalide ou absente … exécution refusée`, exit 1. Lancer par le digest
vérifié évite une course : un re-push du tag entre la vérification et le `docker run` serait sans effet.
En production, on applique cette règle côté orchestrateur (Kyverno / sigstore policy-controller sur
Kubernetes, ou Notation + plugin d'admission) plutôt qu'avec un wrapper contournable.

### B1 — scan continu (analyse)

`trivy image --download-db-only` sur un poste/CI planifié, puis `trivy server --listen 0.0.0.0:4954` avec
le cache partagé : les clients (`trivy image --server http://trivy:4954`) ne téléchargent plus la base
(~60 Mo, rate-limitée par GHCR) et les résultats sont cohérents entre l'équipe et la CI.

### B2 — keyless (analyse)

`cosign sign` sans `--key` : certificat éphémère délivré par **Fulcio** après authentification OIDC
(compte GitHub, ou identité du workflow GitHub Actions), signature inscrite dans le journal de transparence
public **Rekor**. Avantages : aucune clé privée à stocker/faire tourner, identité vérifiable
(`--certificate-identity`, `--certificate-oidc-issuer`), révocation implicite (certificat de 10 min).
Inconvénients : dépendance à des services publics (ou à un Sigstore auto-hébergé), publication des
métadonnées (nom de l'image, identité) dans un journal public, inadapté aux environnements isolés.

### B4 — scanner le SBOM (analyse)

`trivy sbom supply-chain/sbom.json` analyse l'inventaire au lieu de l'image : quand une CVE est publiée
6 mois après le build, on rescanne en quelques secondes **tous les SBOM** des images déployées (stockés
ou attachés comme attestations) sans re-tirer ni décompresser les images, et on sait immédiatement quelles
images sont concernées.
