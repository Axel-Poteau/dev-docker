# TP08 — Durcir les conteneurs pour la production : rapport

## Livrables

| Fichier | Rôle |
|---|---|
| [`audit.sh`](audit.sh) | audit rejouable des conteneurs en cours (code retour ≠ 0 si écart) |
| [`compose.hardened.yml`](compose.hardened.yml) | surcharge durcie de la stack TP04, commentée directive par directive |
| [`hardened.sh`](hardened.sh) | raccourci `base TP04 + prod + hardened` (`./hardened.sh up -d --wait`, `./hardened.sh smoke`) |
| [`experiences.sh`](experiences.sh) → [`experiences.txt`](experiences.txt) | une expérience par mesure (étape 2) |
| [`essais-caps.sh`](essais-caps.sh) → [`essais-caps.txt`](essais-caps.txt) | capacités minimales PostgreSQL/Traefik par essai/erreur, filtrage du proxy de socket |
| [`daemon.json`](daemon.json), [`daemon-checks.txt`](daemon-checks.txt) | configuration daemon proposée, effet d'`icc` |
| `audit-avant-dev.txt`, `audit-avant-prod.txt`, `audit-apres.txt` | sorties `audit.sh` avant/après |
| `docker-bench-avant.txt`, `docker-bench-apres.txt` | sorties de docker-bench-security |

Lancement :

```bash
./hardened.sh up -d --wait          # --pull never si le registre n'est pas joignable
./hardened.sh smoke                 # smoke test du TP04
./audit.sh --filter label=com.docker.compose.project=shop
```

## 1. Mesurer

### `audit.sh`

Pour chaque conteneur (`docker ps -q "$@"`, donc filtrable), un seul `docker inspect` avec un template
Go qui sort : `Config.User`, `HostConfig.Privileged`, `CapDrop`/`CapAdd`, `ReadonlyRootfs`, `Memory`,
`PidsLimit`, `SecurityOpt`, les montages. Chaque contrôle donne ✔ ou ✘, le total des ✘ est le code de
sortie.

Une exception se déclare **sur le conteneur**, avec le label `audit.allow=<contrôle>,…`, et apparaît
en `~` (le proxy de socket a forcément la socket montée). Elle est donc visible dans le compose et
relue en revue, au lieu de se cacher dans une liste blanche du script.

Piège rencontré : avec `IFS=$'\t'`, bash fusionne les champs vides consécutifs (la tabulation est un
séparateur « blanc »), et les colonnes se décalent quand `CapDrop` est vide. J'utilise donc `|` comme
séparateur.

### Résultats sur la stack TP04

| Stack | Conteneurs | Écarts | Détail |
|---|---|---|---|
| dev (`compose.yml` + override) | 5 | **29** | rien n'est durci : capacités par défaut, rootfs RW, aucune limite, db/proxy/redis en root, socket montée dans Traefik |
| prod (`+ compose.prod.yml`) | 6 | **10** | `pids_limit` absent partout (6), db en root avec un rootfs RW (2), Traefik en root (1), socket montée dans Traefik (1) |
| **durcie** (`+ compose.hardened.yml`) | 7 | **0** | une exception documentée : `sock` sur `socket-proxy` |

### docker-bench-security

Résultat : 105 contrôles, **32 WARN / 33 PASS** avant, **31 WARN / 34 PASS** après. Le « Score: 0 »
affiché n'a pas de sens : l'image `docker/docker-bench-security` date de janvier 2019 et son calcul de
score ne marche plus avec un moteur 28.x. Sous Docker Desktop, les sections 1 à 3 (partition, auditd,
fichiers systemd, `/etc/docker`) testent la VM et pas mon poste, je ne les retiens pas.

Les 5 WARN que je juge prioritaires :

| # | Contrôle | Pourquoi c'est prioritaire | Traitement |
|---|---|---|---|
| 5.31 | Docker socket shared: `shop-proxy-1` | donner la socket revient à donner root sur l'hôte, même en `:ro` (le `:ro` ne porte que sur le fichier, pas sur l'API) | socket retirée de Traefik ; seul `socket-proxy` la voit, avec filtrage (§3) |
| 5.4 / 5.9 | `buildx_buildkit_shop0` en `--privileged` et `--net host` | un conteneur privilégié a accès à tous les périphériques et à toutes les capacités | builder `docker-container` du TP02 : à arrêter hors build (`docker buildx stop shop`), ou passer au builder `docker` par défaut |
| 5.3 | capacités ajoutées : db (5), proxy (1) | chaque capacité élargit ce qu'une RCE peut faire | db en uid 70 et Traefik en nobody : **0 capacité** (le contrôle passe en PASS après) |
| 5.12 / 5.10 / 5.28 | rootfs RW, pas de limite mémoire ni de PID | persistance d'un attaquant, déni de service de l'hôte | `read_only`, `memory` et `pids` partout ; il ne reste que les conteneurs du registre TP03 (hors périmètre) |
| 2.8 / 2.18 | pas d'userns, pas de `no-new-privileges` global | sans userns, root dans le conteneur = root sur l'hôte en cas d'évasion | `daemon.json` (§4) |

Les WARN qui restent après durcissement :

- 5.1 AppArmor : Docker Desktop n'en charge pas (bonus B4 non traité) ;
- 5.11 « CPU restrictions » : le script de 2019 regarde `CpuShares`, pas `NanoCpus` (`cpus:`), donc
  c'est un faux positif ;
- 5.13 port publié sur `0.0.0.0` : à corriger en prod avec `127.0.0.1:` ou l'IP de l'interface publique ;
- 5.14 `on-failure:5` : on garde volontairement `unless-stopped` ;
- les conteneurs du registre TP03.

## 2. Expériences — [`experiences.txt`](experiences.txt)

| Mesure | Expérience | Résultat observé | Ce qu'il faut retenir |
|---|---|---|---|
| `--read-only` | `touch /x` | `Read-only file system` | |
| | `--tmpfs /tmp` puis `touch /tmp/x` | OK, monté `rw,nosuid,nodev,noexec` | le tmpfs est `noexec` par défaut : un binaire déposé dans `/tmp` ne s'exécute pas |
| `--cap-drop ALL` | `CapEff` | `a80425fb` (14 capacités) → `0` | |
| | `ping` vers la passerelle | **réussit sans NET_RAW** | Docker pose `net.ipv4.ping_group_range=0 2147483647` : ping passe par une socket ICMP « datagram ». Avec `--sysctl ping_group_range="1 0"`, il faut `NET_RAW` |
| | `nc -l -p 80` | **réussit sans NET_BIND_SERVICE** | Docker pose `net.ipv4.ip_unprivileged_port_start=0` |
| | `chown nobody` | `Operation not permitted` → OK avec `CHOWN` | |
| | `apk add curl` | **réussit sans capacité** | root écrit dans des fichiers qui lui appartiennent ; le blocage vient du rootfs RO, pas des capacités |
| | écrire dans un dossier `nobody` en 700 | `Permission denied` → OK avec `DAC_OVERRIDE` | c'est le cas de l'entrypoint postgres (cf. §3) |
| `no-new-privileges` | `passwd` et `su` sont `-rwsr-xr-x root` | | |
| | copie setuid root de `id`, lancée en nobody | `euid=0(root)` → **`euid` disparaît** | `NoNewPrivs: 1` : le bit setuid est ignoré à l'`execve` |
| `--pids-limit 50` | 100 `sleep &` | `can't fork: Resource temporarily unavailable` (sans limite : 104 processus) | la fork bomb reste dans le conteneur |
| `--memory 32m` | `x='a'*100_000_000` | code 137, **`OOMKilled=true`** ; passe avec 128m | `--memory-swap` égal à `--memory`, sinon le swap masque le problème |
| `--user 1000` | `id` | `uid=1000 gid=0(root)` | sans `:gid`, le groupe reste 0 : toujours préciser `uid:gid` |
| | écrire dans un volume rempli par root | `Permission denied` → OK après `chown -R 1000:1000` | l'image doit préparer le dossier (`chown` au build) ou un job d'init doit le faire, sinon le non-root casse les volumes existants |
| seccomp | `unshare --user` | `Operation not permitted` → OK avec `seccomp=unconfined` | `Seccomp: 2` (mode filtre) contre `0` |
| | décompte sur le profil moby | sur **373** appels système x86_64, **294** sont autorisés sans condition ; **79** sont refusés par défaut (EPERM), certains rouverts par une capacité ou un filtre d'argument | refusés : `bpf`, `mount`, `umount2`, `unshare`, `setns`, `kexec_load`, `init_module`, `reboot`, `keyctl`, `add_key`, `open_by_handle_at` (évasion « shocker »), `userfaultfd`, `perf_event_open`… |

## 3. Stack durcie — [`compose.hardened.yml`](compose.hardened.yml)

Une ancre `x-hardening` (`read_only`, `cap_drop: [ALL]`, `no-new-privileges`) s'applique à tous les
services. Chaque service ajoute ensuite ses `tmpfs` ciblés et ses limites
`deploy.resources.limits.{cpus,memory,pids}`.

### Capacités : ce que j'ai trouvé par essai/erreur ([`essais-caps.txt`](essais-caps.txt))

**PostgreSQL**, avec l'entrypoint officiel démarré en root. Il fait `chown`/`chmod` sur PGDATA puis
`su-exec postgres`. Je pars d'un volume neuf à chaque essai et je retire une capacité à la fois.

| Capacités | Résultat | Log |
|---|---|---|
| aucune | ÉCHEC | `chmod: /var/lib/postgresql/data: Operation not permitted` |
| CHOWN DAC_OVERRIDE FOWNER SETGID SETUID (TP04) | OK | |
| sans CHOWN | OK | le volume nommé est déjà `70:70` (copié depuis l'image), le `chown` n'a rien à faire |
| sans DAC_OVERRIDE | ÉCHEC | `find: /var/lib/postgresql/data: Permission denied` (dossier 700 de postgres) |
| sans FOWNER | OK | le `chmod` est en `\|\| :` dans l'entrypoint |
| sans SETGID / SETUID | ÉCHEC | `failed switching to "postgres": operation not permitted` |
| **`user: "70:70"`, aucune capacité** | **OK** | l'entrypoint n'a plus rien à chown ni à changer d'utilisateur |

En root, le minimum est donc **DAC_OVERRIDE + SETGID + SETUID**. Démarrer directement en uid 70
supprime le besoin de capacités. Il faut seulement que le volume appartienne à 70:70, ce qui est
automatique pour un volume nommé initialisé par l'image (mais pas pour un bind mount). Le socket unix
et le fichier de verrou passent dans un tmpfs `/var/run/postgresql` en `uid=70,gid=70`.

**Traefik** : aucune capacité nécessaire, même pour écouter sur `:80`, grâce à
`ip_unprivileged_port_start=0`. Il tourne en `65534:65534` et le `cap_add: [NET_BIND_SERVICE]` du
TP04 disparaît (`!reset []`).

**Redis** : `user: redis`, comme au TP04. Sans ça, l'entrypoint tente un `chown` en root.

### Proxy de socket

```
Traefik ──tcp://socket-proxy:2375──▶ socket-proxy (HAProxy) ──▶ /var/run/docker.sock:ro
         réseau "socket" internal: true
```

- Traefik : `volumes: !reset []`, `TRAEFIK_PROVIDERS_DOCKER_ENDPOINT=tcp://socket-proxy:2375`, et un
  `depends_on` sur le proxy healthy.
- `tecnativa/docker-socket-proxy:0.3.0` avec `CONTAINERS=1 EVENTS=1 VERSION=1 PING=1 POST=0`. Le proxy
  est sur le réseau `socket` (`internal`), joignable uniquement par Traefik.
- Durcissement du proxy lui-même :
  - l'entrypoint d'origine réécrit `haproxy.cfg` dans `/usr/local/etc`, ce qui casse avec `read_only`.
    Je le remplace par un `sed` vers le tmpfs `/tmp` ;
  - le proxy tourne en `user: "65534:0"`. La socket est `root:root 660` : le gid 0 suffit pour y
    accéder, sans que le processus soit root.
- **Fuite découverte** : `CONTAINERS=1` autorise tout `GET /containers/*`, y compris
  `/containers/<id>/archive?path=/run/secrets/db_password`. Avec le proxy par défaut, **j'ai lu le
  mot de passe BDD en clair** (fin d'`essais-caps.txt`). J'ai donc ajouté une règle HAProxy : sous
  `/containers/`, seuls `json` (liste) et `<id>/json` (inspection) passent.

Ce que Traefik obtient maintenant par le proxy :

| Requête | Code |
|---|---|
| `GET /version`, `/containers/json`, `/containers/<id>/json`, `/events` | 200 |
| `GET /containers/<id>/archive`, `/containers/<id>/logs`, `/images/json`, `/secrets` | 403 |
| `POST /containers/create`, `POST …/kill`, `DELETE /containers/<id>` | 403 |

### Validation

```
$ ./hardened.sh up -d --wait --pull never     → 7 conteneurs Healthy (socket-proxy, proxy, api ×2, worker, db, redis)
$ ./hardened.sh smoke                         → /ready ok, X-Cache HIT, commande confirmée par le worker : OK
$ ./audit.sh --filter label=com.docker.compose.project=shop
  … aucun écart sur 7 conteneur(s)            (cf. audit-apres.txt)
```

Pièges de fusion Compose rencontrés :

- `security_opt` est une liste concaténée : la prod pose déjà `no-new-privileges`, donc la fusion le
  dupliquait (`items at 0 and 1 are equal`). Corrigé avec `!override` ;
- même problème pour `tmpfs: /tmp` (`target /tmp already mounted`), corrigé avec `!override` ;
- `pids_limit` combiné à `deploy.resources.limits` donne `can't set distinct values on 'pids_limit'
  and 'deploy.resources.limits.pids'`. Il faut utiliser `deploy.resources.limits.pids`.

## 4. Côté daemon — [`daemon.json`](daemon.json)

| Option | Justification |
|---|---|
| `"no-new-privileges": true` | valeur par défaut pour tous les conteneurs, même ceux lancés à la main. Effet de bord : `sudo`/`su` cessent de marcher dans les images qui en dépendent (rare en prod, c'est voulu) |
| `"icc": false` | bloque le trafic conteneur ↔ conteneur sur le **bridge par défaut** (`docker0`) uniquement |
| `"live-restore": true` | un redémarrage ou une mise à jour du daemon ne tue plus les conteneurs. Incompatible avec Swarm |
| `"userland-proxy": false` | ports publiés via iptables au lieu d'un processus `docker-proxy` par port ; l'IP source réelle est conservée |
| `"log-driver": "local"` + `max-size`/`max-file` | rotation par défaut (le disque plein du legacy, CIS 2.12) ; format compressé. `docker logs` continue de marcher |
| `"userns-remap": "default"` | root dans le conteneur devient l'uid 100000+ sur l'hôte (utilisateur `dockremap`) : une évasion ne donne plus root |
| `default-ulimits.nofile` | une seule limite par défaut, pas de `nproc`, voir le second point ci-dessous |
| `default-address-pools` | sous-réseaux prévisibles, sans collision avec le LAN de l'entreprise |

**Effets de bord d'`icc: false`** ([`daemon-checks.txt`](daemon-checks.txt)) :

- je l'ai simulé sur un bridge dédié (`com.docker.network.bridge.enable_icc=false`). Résultat :
  conteneur → conteneur **bloqué**, alors que l'accès depuis l'hôte vers un port publié marche
  toujours ;
- sur la stack, **aucun effet**. Elle n'utilise que des bridges utilisateur (`shop_front`,
  `shop_back`, `shop_socket`), auxquels l'option daemon ne s'applique pas. La segmentation passe par
  les réseaux et `internal: true` ;
- ça casse les conteneurs lancés « à la main » sur le bridge par défaut qui se parlent entre eux
  (anciens `--link`).

**Effets de bord d'`userns-remap`** :

- le daemon utilise un autre répertoire, `/var/lib/docker/100000.100000/`. Les images et
  **volumes existants « disparaissent »** : ils sont toujours dans `/var/lib/docker/volumes`, mais le
  daemon ne les voit plus ;
- après migration, les fichiers appartenant à `0:0` ou `70:70` apparaissent dans le conteneur comme
  `nobody:nogroup` (uid non mappé) et deviennent illisibles. Il faut les re-propriétariser avec un
  décalage (`chown -R 100070:100070` pour pgdata) ou faire un dump/restore (TP05) ;
- les bind mounts de l'hôte (`secrets/db_password.txt`) doivent être lisibles par l'uid 100000+ ;
- `--privileged`, `--pid=host`, `--net=host` nécessitent `--userns=host` au cas par cas, ce qui
  concerne par exemple docker-bench, cAdvisor et le builder buildkit du TP02 ;
- `nproc` compte par uid de l'hôte : tous les conteneurs remappés partagent les mêmes uid et donc le
  même quota. D'où `pids` par conteneur plutôt que `nproc`.

**Alternative : rootless.** Le daemon lui-même tourne sans root. C'est plus fort que `userns-remap`,
mais les ports < 1024 demandent `setcap cap_net_bind_service` sur `rootlesskit` ou un sysctl, le
réseau passe par slirp4netns/pasta (plus lent), et cAdvisor ainsi que les limites cgroup demandent
cgroup v2 avec délégation.

Sous Docker Desktop, `daemon.json` s'édite dans Settings → Docker Engine. Je ne l'ai pas appliqué sur
ce poste : `userns-remap` aurait masqué tous les volumes des TP précédents. `docker info` montre l'état
actuel : `LiveRestore=false`, `json-file`, seccomp `builtin`.

## Bonus

Non traités : B1 seccomp sur mesure, B2 rootless (pistes ci-dessus), B3 distroless (le Dockerfile
distroless existe déjà au TP01), B4 AppArmor (non disponible sous Docker Desktop).
