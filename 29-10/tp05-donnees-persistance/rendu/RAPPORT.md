# TP05 — Données : persistance, sauvegarde, restauration, montée de version

## Livrables

| Fichier | Rôle |
|---|---|
| [`backup.sh`](backup.sh) | dump `pg_dump -Fc` horodaté + vérification + sha256 ; `--raw` : copie brute du volume à froid ; rétention des 7 derniers |
| [`restore.sh`](restore.sh) | restauration d'un `.dump` (`pg_restore --clean --single-transaction`) ou d'un `.tar.gz` (volume) |
| [`checksum.sh`](checksum.sh) | empreinte des commandes (même requête que `seed.sh`) |
| [`lib.sh`](lib.sh) | paramètres communs (stack du TP04 par défaut, surchargeables) |
| [`../../tp04-compose-entreprise/rendu/compose.backup.yml`](../../tp04-compose-entreprise/rendu/compose.backup.yml) | sidecar de sauvegarde planifiée ajouté à la stack du TP04 |
| [`upgrade/upgrade-pg.sh`](upgrade/upgrade-pg.sh), [`upgrade/compose.yml`](upgrade/compose.yml) | montée de version 14 → 16 |
| Transcripts | [`etape1-anatomie.txt`](etape1-anatomie.txt), [`transcript-restauration.txt`](transcript-restauration.txt), [`transcript-sidecar.txt`](transcript-sidecar.txt), [`transcript-upgrade.txt`](transcript-upgrade.txt), [`transcript-pg-upgrade-link.txt`](transcript-pg-upgrade-link.txt), [`etape4-redis.txt`](etape4-redis.txt) |

Aucun client PostgreSQL n'est utilisé sur l'hôte : tout passe par `docker compose exec` ou des conteneurs jetables.

## 1. Anatomie du stockage

Transcript : [`etape1-anatomie.txt`](etape1-anatomie.txt).

`docker inspect … .Mounts` sur la base du TP04 : trois montages, le volume `shop_pgdata` →
`/var/lib/postgresql/data` (`Source: /var/lib/docker/volumes/shop_pgdata/_data`, dans la VM Docker
Desktop), un bind mount en lecture seule de `db/init.sql` et le bind du secret `/run/secrets/db_password`.
Le volume porte les labels `com.docker.compose.project=shop` / `volume=pgdata` ; `docker system df -v` :
`shop_pgdata` 48 Mo, 1 lien.

**Couche inscriptible vs volume** : après `touch /tmp/x` et l'écriture d'un fichier `marqueur` dans
`/var/lib/postgresql/data`, `docker diff` liste `A /tmp/x` mais **pas** `marqueur`. Tout ce qui est écrit
hors des points de montage va dans la couche inscriptible du conteneur (l'`upperdir` overlayfs,
détruite avec le conteneur) ; ce qui est écrit sous un point de montage va directement dans le volume,
indépendant du cycle de vie du conteneur. (`docker diff` montre aussi les sockets `/run/postgresql`, et les
points de montage créés pour le secret et `init.sql`.)

**Cycle de vie de `pgdata`**, testé sur une **copie** (`docker compose -p shopcopy -f compose.yml`, service
`db` seul, une ligne témoin insérée) :

| Commande | Volume | Données |
|---|---|---|
| `docker compose down` | conservé | témoin présent après `up` |
| `docker compose rm -sf db` | conservé | témoin présent |
| `docker volume prune -f` | **conservé** : depuis Docker 23, `prune` ne supprime que les volumes **anonymes** inutilisés | témoin présent |
| `docker volume prune -a -f` | **supprimé** (`-a` inclut les volumes nommés non utilisés) | perdues |
| `docker compose down -v` | **supprimé** | perdues : la base est recréée vide par `init.sql` (témoin = 0) |

(Les `prune` ont été filtrés par `--filter label=com.docker.compose.project=shopcopy` pour ne toucher à
aucun autre volume de la machine — le réflexe à avoir sur un serveur partagé.)

**Volume anonyme** : `docker run -d postgres:16.4-alpine` sans `-v` crée un volume au nom aléatoire
(`68c719b7…`) parce que l'image déclare `VOLUME /var/lib/postgresql/data`. Après `docker rm`, le volume
reste, orphelin ; avec `docker rm -v` il est supprimé. Piège classique : les données ne sont pas dans le
conteneur mais on ne sait plus à quel volume elles appartiennent (pas de nom, pas de label) ; un nouveau
`docker run` crée un **autre** volume vide (données « perdues » alors qu'elles existent encore) ; à
l'inverse, un `docker volume prune` ou `rm -v` de routine les efface définitivement.

**Bind mount, volume nommé ou tmpfs ?**
- **Volume nommé** : données d'application (bases, files d'attente). Géré par Docker, portable,
  sauvegardable avec un conteneur, permissions initialisées depuis l'image, performant.
- **Bind mount** : fichiers qui appartiennent à l'hôte ou au dépôt : code source en dev, configuration en
  lecture seule (`init.sql`, `config.yml`), secrets, répertoire de sauvegarde. Dépend de l'arborescence et
  des UID de l'hôte.
- **tmpfs** : données temporaires ou sensibles qui ne doivent jamais toucher le disque (`/tmp` d'un
  conteneur `read_only`, caches, sockets).
- **Docker Desktop (macOS/Windows, et Linux)** : les bind mounts traversent le partage de fichiers de la VM
  (virtiofs/gRPC-FUSE) : I/O nettement plus lentes, et constaté au TP04 : les événements inotify ne sont pas
  relayés. Une base sur un bind mount y est lente : toujours un volume nommé (qui vit dans la VM).

**Pourquoi `init.sql` n'est pas rejoué** : `docker-entrypoint.sh` n'exécute `initdb` puis les scripts de
`/docker-entrypoint-initdb.d` **que si `PGDATA` est vide**. Au redémarrage :
`PostgreSQL Database directory appears to contain a database; Skipping initialization` ; au premier
démarrage de la copie : `running /docker-entrypoint-initdb.d/001-init.sql`. Pour forcer une
ré-initialisation : supprimer le volume (`down -v` ou `docker volume rm shop_pgdata`) **après sauvegarde** ;
pour une évolution de schéma sur une base existante, passer par une migration (`make migrate`, TP04).

## 2. Sauvegarde et restauration

Preuve complète : [`transcript-restauration.txt`](transcript-restauration.txt).

| Étape | Résultat |
|---|---|
| `seed.sh` sur la stack du TP04 | 100 000 commandes insérées (+ 4 existantes) |
| `./checksum.sh` | `100004 6d9901973a7f51f1b1c49fd87604b5a8` |
| `./backup.sh --raw` | `shop-20261029-104511.dump` (1,6 Mo, 16 objets vérifiés par `pg_restore -l`) + `shop_pgdata-….tar.gz` (13 Mo, base arrêtée ~9 s) + `.sha256` |
| `docker compose down -v` puis `up -d --wait` | base neuve : `./checksum.sh` → `0` |
| `./restore.sh backups/shop-….dump` | sha256 vérifié, restauration en **1,0 s** |
| `./checksum.sh` | `100004 6d9901973a7f51f1b1c49fd87604b5a8` → **identique** |
| nouveau `down -v` puis `./restore.sh backups/shop_pgdata-….tar.gz` | 7,4 s, checksum **identique** |

**Quand la sauvegarde brute est-elle incohérente ?** Si on copie les fichiers pendant que PostgreSQL
tourne : les pages des tables, le WAL et `pg_control` sont copiés à des instants différents pendant que
des écritures (et des checkpoints) ont lieu. Le résultat peut être impossible à démarrer ou contenir des
pages corrompues. Pour la rendre cohérente :
- **à froid** : arrêter la base pendant la copie (choix de `backup.sh --raw` : `compose stop db` → `tar` →
  `up --wait`, ≈ 9 s d'indisponibilité) ;
- **à chaud** : `SELECT pg_backup_start('label')`, copie des fichiers, `SELECT * FROM pg_backup_stop()`, en
  conservant **les WAL** générés pendant la copie (c'est ce que fait `pg_basebackup`) ;
- ou un snapshot atomique du système de fichiers (LVM/ZFS/EBS) : équivalent à un crash, PostgreSQL rejoue le WAL au démarrage.

Le dump logique `pg_dump` est cohérent **en ligne** (snapshot MVCC), portable entre versions majeures
(cf. étape 3), mais plus lent à restaurer sur une grosse base ; la copie brute est rapide mais liée à la
version majeure et à l'architecture.

**Effets de bord observés lors de la restauration brute** (la base est arrêtée) :
- l'API a planté : `error: terminating connection due to administrator command` — l'événement `error` du
  pool `pg` n'est pas géré par `server.js`. En prod, le conteneur s'arrête et `restart: unless-stopped` le
  relance ; en dev, `node --watch` attend une modification de fichier → `docker compose restart api`.
  Recommandation à l'équipe : `pool.on('error', …)` ;
- le worker avait dépilé une commande (`BRPOP`) au moment où sa connexion était morte
  (`connection already closed`) : **la commande a été perdue** (consommation « au plus une fois »). Une
  file fiable utiliserait `BLMOVE` vers une liste « en cours » ou des Redis Streams avec acquittement.
Une restauration se fait donc **application arrêtée** (ou en maintenance), puis on redémarre l'API et le worker.

**Sidecar planifié** ([`transcript-sidecar.txt`](transcript-sidecar.txt)) :
`BACKUP_SCHEDULE="@every 1m" docker compose -f compose.yml -f compose.override.yml -f compose.backup.yml up -d --wait backup`
(image `prodrigestivill/postgres-backup-local:16`, réseau `back`, mot de passe via le secret
`POSTGRES_PASSWORD_FILE`, format custom). Deux dumps en deux minutes (`SQL backup created successfully`),
arborescence `last/`, `daily/`, `weekly/`, `monthly/` avec liens `*-latest.dump` et rotation 7 j / 4 sem. /
6 mois ; `pg_restore -l` sur le dernier dump liste les 4 tables. Le healthcheck de l'image
(`interval: 5m` sans `start_period`) bloquait `up --wait` 5 minutes : il est surchargé (30 s).
Limite : les sauvegardes restent sur le même hôte ; il faut les externaliser (bonus B2).

## 3. Montée de version majeure PostgreSQL 14 → 16

Transcript : [`transcript-upgrade.txt`](transcript-upgrade.txt).

**Changer seulement le tag** : le conteneur s'arrête aussitôt (`Exited (1)`) :
```
DETAIL:  The data directory was initialized by PostgreSQL version 14, which is not compatible with this version 16.4.
FATAL:  database files are incompatible with server
```
Le format **physique** des fichiers (catalogues système, pages) change entre versions majeures ; un
binaire 16 ne sait pas lire un `PGDATA` 14. Il faut convertir les données : dump/restore logique ou
`pg_upgrade`. (Les mineures — 14.12 → 14.13 — ne changent pas le format : simple changement de tag.)
Le volume, lui, n'est pas modifié : remettre le tag 14 redémarre la base normalement.

**`upgrade-pg.sh`** (version et volume pilotés par `.env` : `PG_TAG`, `PG_VOLUME`) :

```
[10:57:10] version source : 14.13
[10:57:10] checksum avant  : 100000 6bca9e4b6b501c220a408fecb17b39a2
[10:57:10] pg_dumpall (rôles + toutes les bases) et pg_dump -Fc shop
[10:57:12] arrêt de PostgreSQL 14.13 (le volume pgdata est conservé) — début de l'indisponibilité
[10:57:12] démarrage de PostgreSQL 16.4 sur le volume neuf pgdata16
[10:57:18] restauration : rôles (globals) puis base shop (pg_restore)
[10:57:19] fin de l'indisponibilité : 7 s
[10:57:19] checksum après  : 100000 6bca9e4b6b501c220a408fecb17b39a2
[10:57:19] VERDICT : OK, données identiques. PostgreSQL 16.4 actif (pgdata16) ; pgdata conservé pour le retour arrière.
```

Si les checksums diffèrent, le script repasse automatiquement sur PG14 et son volume. Il lance aussi
`vacuumdb --analyze-only` (les statistiques du planificateur ne sont pas dans le dump).

**Retour arrière** (testé) : `printf 'PG_TAG=14.13-alpine\nPG_VOLUME=pgdata\n' > .env && docker compose up -d --wait`
→ `14.13`, même checksum. Attention : les écritures faites sur PG16 après la bascule ne sont pas dans
`pgdata` ; un retour arrière tardif impose de dumper PG16 et de restaurer dans PG14 (possible seulement si
aucune fonctionnalité propre à 16 n'est utilisée). On ne supprime `pgdata` qu'après une période de validation.

**`pg_dumpall` vs `pg_dump`** : `pg_dump` exporte **une** base (formats texte, custom `-Fc`, répertoire
`-Fd` parallélisable), sans les objets globaux. `pg_dumpall` exporte **tout le cluster** : rôles, mots de
passe, tablespaces, droits et toutes les bases, en SQL texte uniquement (`--globals-only` pour ne garder
que les rôles). Le script prend les deux : `pg_dumpall` comme filet de sécurité complet, `globals` +
`pg_dump -Fc` pour une restauration contrôlée et rapide.

**Pourquoi un nouveau volume** : l'ancien reste intact et redémarrable tel quel : c'est le retour arrière,
instantané et sûr. Écraser l'ancien volume rendrait toute erreur (dump incomplet, extension manquante,
problème de collation) irréversible, et un PG16 démarré sur un volume non vide ne ferait pas d'`initdb`.

**Réduire l'indisponibilité** (7 s ici pour 100 000 lignes, mais proportionnelle à la taille avec un dump) :
- `pg_restore -j N` (format `-Fc`/`-Fd`) pour paralléliser ;
- **`pg_upgrade --link`** : conversion des catalogues seulement, les fichiers de données sont réutilisés
  par liens durs → durée quasi indépendante du volume de données (bonus B1 ci-dessous) ;
- **réplication logique** PG14 → PG16 (`CREATE PUBLICATION` / `CREATE SUBSCRIPTION`) : la nouvelle base se
  synchronise pendant que l'ancienne sert le trafic, puis bascule de quelques secondes (resynchroniser les
  séquences, changer `DB_HOST`).

## 4. Redis

| Mode | Perte maximale |
|---|---|
| `--save 60 1` (snapshot RDB si ≥ 1 écriture en 60 s) | jusqu'à ~60 s d'écritures (tout ce qui suit le dernier snapshot), davantage si le `fork` du snapshot échoue |
| `--appendonly yes` (AOF, `appendfsync everysec` par défaut) | ~1 s d'écritures ; `appendfsync always` → aucune (au prix des performances) |

Dans notre stack ([`etape4-redis.txt`](etape4-redis.txt)), Redis tourne avec `--appendonly yes`
(`appendfsync everysec`, plus les snapshots RDB par défaut `3600 1 300 100 60 10000`) et contient :
- le **cache** `products` (TTL 30 s) : reconstruit depuis PostgreSQL au prochain `MISS`, aucune persistance nécessaire ;
- la **file `orders:queue`** : une commande non encore traitée qui disparaît reste `pending` en base (et
  n'est jamais confirmée). C'est elle qui justifie l'AOF `everysec` : perte bornée à ~1 s de commandes en
  cas de crash. La source de vérité reste PostgreSQL ; un job de rattrapage des commandes `pending`
  anciennes couvrirait le reste.

L'AOF est donc justifié, mais Redis ne doit pas être sauvegardé comme la base : la reconstruction depuis
PostgreSQL est le plan de reprise.

## Bonus

### B1 — `pg_upgrade --link` ([`transcript-pg-upgrade-link.txt`](transcript-pg-upgrade-link.txt))

Sur une **copie** du volume PG14, placée dans un volume unique contenant `14/data` (les liens durs
exigent que l'ancien et le nouveau répertoire soient sur le même système de fichiers : deux volumes
distincts ne conviennent pas) :
`docker run --rm -v pgupg:/var/lib/postgresql -e PGUSER=shop -e POSTGRES_INITDB_ARGS="-U shop" tianon/postgres-upgrade:14-to-16 --link`
→ `Linking user relation files ok`, `Upgrade Complete` en **3,3 s** (contre 7 s pour dump/restore), puis
PG16 démarré sur `16/data` : `100000 6bca9e4b6b501c220a408fecb17b39a2`, identique.
Contrepartie : après démarrage du nouveau cluster, l'ancien ne doit plus être démarré (fichiers partagés)
→ retour arrière uniquement depuis une sauvegarde. Avertissement observé : `database "shop" has no actual
collation version` — à traiter (`ALTER DATABASE shop REFRESH COLLATION VERSION` après vérification des index).

### B2, B3, B4 (non réalisés, pistes)

- **B2** : `pg_dump -Fc … | age -r <clé publique> > dump.age`, puis envoi avec `mc cp` vers un MinIO
  (`minio/minio` + bucket versionné avec verrouillage d'objet) : la sauvegarde quitte l'hôte et ne peut
  plus être effacée par un `down -v` ni par un attaquant.
- **B3** : volume NFS (`driver_opts: {type: nfs, o: "addr=…,rw", device: ":/export/pg"}`) : les données
  survivent à la perte de l'hôte et un autre nœud peut remonter le volume, mais la latence réseau pèse sur
  la base et le verrouillage NFS est risqué pour PostgreSQL ; la sauvegarde se fait côté stockage
  (snapshots du NAS). La HA d'une base passe plutôt par la réplication que par un stockage partagé.
- **B4** : `archive_mode=on`, `archive_command='cp %p /wal-archive/%f'` vers un volume dédié +
  `pg_basebackup` ; restauration : base de référence + `restore_command` + `recovery_target_time = '<T-5min>'`.
