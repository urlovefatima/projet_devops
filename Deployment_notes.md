# Déploiement d'Ollama et Open WebUI sur Kubernetes

**Namespace :** `llm-app` | **Cluster :** minikube | **Modèles (déploiement Kubernetes) :** `llama3.2:3b`, `qwen2.5:0.5b`, `tinyllama:latest`

## 1. Vue d'ensemble

Ce projet recrée sur Kubernetes un déploiement Docker Compose composé de deux applications : **Ollama**, qui exécute les modèles de langage, et **Open WebUI**, une interface web qui envoie les requêtes à Ollama. Tous les manifestes sont organisés avec Kustomize dans `k8s/base/` et `k8s/overlays/dev/`, et sont appliqués avec `kubectl apply -k k8s/overlays/dev`.

## 2. Rôle de chaque ressource Kubernetes

| Ressource | Nom(s) | Rôle |
|---|---|---|
| Namespace | `llm-app` | Regroupe toutes les ressources du projet et les isole des autres charges de travail du cluster. Il peut être supprimé en une seule commande pour tout nettoyer. |
| ConfigMap | `ollama-config`, `openwebui-config` | Stocke la configuration non sensible (`OLLAMA_BASE_URL`, `OLLAMA_KEEP_ALIVE`, `OLLAMA_MAX_LOADED_MODELS`, `OLLAMA_NUM_PARALLEL`) en dehors de l'image du conteneur. Les Deployments la chargent via `envFrom`, donc changer une configuration ne demande ni de modifier le Deployment ni de reconstruire une image. |
| PersistentVolumeClaim | `ollama-pvc` (10Gi), `openwebui-pvc` (5Gi) | Réserve un espace de stockage durable pour les modèles téléchargés et pour les données d'Open WebUI. |
| Deployment | `ollama`, `open-webui` | Décrit l'état souhaité de chaque application (image, ports, ressources, probes, volumes). Kubernetes maintient un pod actif et le recrée en cas d'échec. |
| Service | `ollama` (11434), `open-webui` (8080) | Donne à chaque application une adresse interne stable et un nom DNS, puisque l'IP d'un pod change à chaque redémarrage. |
| Ingress | `open-webui` | Expose l'interface web à l'extérieur du cluster sur `openwebui.local`, via un contrôleur Ingress NGINX. `kubectl port-forward` a servi d'alternative lorsque le contrôleur Ingress n'était pas activé sur une machine donnée. |

Les deux Deployments utilisent `replicas: 1` et la stratégie de mise à jour `Recreate`. Les volumes sont en `ReadWriteOnce`, donc un seul pod peut les monter à la fois ; une mise à jour progressive (`RollingUpdate`) laisserait l'ancien et le nouveau pod se disputer le même volume et la même mémoire limitée.

**Requests et limits.** Chaque conteneur déclare des requests CPU et mémoire (la quantité réservée par l'ordonnanceur) et des limits (le maximum autorisé). Le nœud minikube étant limité en mémoire, trois petits modèles ont été utilisés plutôt que des modèles plus lourds (`mistral:7b`, `deepseek-r1:8b`), ce qui permet de garder des limites modestes :

| Conteneur | Requests | Limits |
|---|---|---|
| Ollama | 500m CPU, 1Gi | 2 CPU, 3Gi |
| Open WebUI | 250m CPU, 512Mi | 1 CPU, 1Gi |

`OLLAMA_MAX_LOADED_MODELS=1` ne garde qu'un seul modèle en mémoire à la fois, ce qui laisse assez de marge pour le plus gros des trois modèles (`llama3.2:3b`, environ 2 Go) et son contexte.

## 3. Communication entre les services

```
Navigateur
  │  Ingress (openwebui.local) ou kubectl port-forward
  ▼
Service open-webui :8080  ──►  Pod open-webui
                                   │  OLLAMA_BASE_URL = http://ollama:11434
                                   ▼
                          Service ollama :11434  ──►  Pod ollama  ──►  PVC ollama-pvc
```

1. L'utilisateur accède à Open WebUI via l'Ingress ou le port-forward, qui ciblent le Service `open-webui` sur le port 8080.
2. Le Service redirige le trafic vers le pod dont le label correspond à son sélecteur (`app: open-webui`).
3. Open WebUI lit `OLLAMA_BASE_URL=http://ollama:11434` depuis son ConfigMap. Le nom `ollama` est résolu par le DNS interne du cluster (CoreDNS) vers l'IP du Service `ollama`, qui transmet la requête au pod portant le label `app: ollama`.
4. Ollama charge le modèle demandé depuis son volume et renvoie la réponse par le même chemin.

Les deux Services sont de type `ClusterIP` : Ollama n'est accessible que depuis l'intérieur du cluster, et le seul point d'entrée depuis l'extérieur est l'interface Open WebUI. L'API d'Ollama n'est donc jamais exposée directement au monde extérieur.

## 4. Pourquoi les PersistentVolumeClaims sont nécessaires

Le système de fichiers d'un conteneur est éphémère : quand un pod est supprimé, évincé ou redémarré, tout ce qui a été écrit à l'intérieur est perdu. Deux types de données doivent survivre :

- **Les modèles d'Ollama** (`/root/.ollama`). Les trois modèles pèsent ensemble plusieurs gigaoctets. Sans PVC, il faudrait les retélécharger à chaque redémarrage du pod, ce qui est lent et gaspille de la bande passante.
- **Les données d'Open WebUI** (`/app/backend/data`) : comptes utilisateurs, réglages et historique des conversations.

Un PVC sépare le cycle de vie des données de celui du pod. La claim est liée à un volume, et tout nouveau pod qui monte `ollama-pvc` ou `openwebui-pvc` retrouve les données exactement là où le pod précédent les a laissées. Dans ce déploiement, supprimer le pod Ollama (`kubectl delete pod -l app=ollama`) ne fait pas disparaître les modèles : une fois le nouveau pod démarré, `ollama list` affiche toujours les trois modèles, ce qui confirme que le PVC fonctionne bien.

## 5. Rôle des probes liveness, readiness et startup

Les probes permettent à Kubernetes de vérifier la santé d'un conteneur plutôt que de supposer qu'un processus en cours d'exécution fonctionne correctement. Chaque application utilise les trois types, sur `/` pour Ollama et `/health` pour Open WebUI.

- **Startup probe.** S'exécute en premier et désactive les deux autres probes tant qu'elle n'a pas réussi. Des applications comme Ollama et Open WebUI peuvent mettre longtemps à démarrer, donc cette probe laisse jusqu'à cinq minutes (`periodSeconds: 5`, `failureThreshold: 60`). Sans elle, un démarrage lent pourrait être pris pour un échec et le conteneur redémarré avant même d'avoir eu la chance de finir de démarrer.
- **Readiness probe.** Décide si le pod doit recevoir du trafic. En cas d'échec, le pod continue de tourner mais est retiré de la liste des endpoints du Service. Cela évite que des requêtes arrivent vers une application pas encore prête, par exemple Open WebUI avant qu'Ollama ne soit disponible.
- **Liveness probe.** Détecte un conteneur qui tourne mais reste bloqué. Après plusieurs échecs consécutifs, Kubernetes redémarre le conteneur.

Les délais des trois probes sont volontairement généreux (5 à 10 secondes, plusieurs échecs tolérés) plutôt que la valeur par défaut d'1 seconde. Lors des premiers tests sur une machine à la mémoire limitée, ce délai par défaut provoquait des erreurs répétées `context deadline exceeded` sur Ollama, entraînant le redémarrage d'un conteneur simplement lent, pas défaillant. Une liveness probe trop stricte peut transformer un simple ralentissement en boucle de redémarrages (`CrashLoopBackOff`).

## 6. Différence entre Docker Compose et Kubernetes

| | Docker Compose | Kubernetes |
|---|---|---|
| Portée | Une seule machine | Un cluster de plusieurs nœuds |
| Gestion des pannes | Simple politique de redémarrage | Auto-réparation : les pods sont recréés, ceux en échec sont retirés du trafic ou redémarrés |
| Mises à jour | Recréation des conteneurs | Mises à jour progressives et retours en arrière (rollback) |
| Réseau | Réseau Compose, noms de service | Services, DNS interne au cluster, Ingress |
| Stockage | Volumes Docker | PersistentVolumes et PersistentVolumeClaims, indépendants du pod |
| Configuration | `environment` et `.env` dans un seul fichier | ConfigMaps et Secrets, objets séparés |
| Vérifications de santé | `healthcheck` optionnel | Probes startup, readiness et liveness, chacune avec un rôle distinct |
| Ressources | Limites optionnelles | Requests (utilisées pour l'ordonnancement) et limits (appliquées à l'exécution) |
| Mise à l'échelle | Manuelle | Déclarative (`replicas`, HorizontalPodAutoscaler) |

Lors de la migration de cette pile de Compose vers Kubernetes, chaque élément Compose se traduit par une ou plusieurs ressources Kubernetes : un service Compose devient un Deployment plus un Service, les `volumes` deviennent des PVC, `environment` devient un ConfigMap, les `ports` deviennent un Service et un Ingress, et `depends_on` est en pratique remplacé par les readiness probes. Compose est plus simple à écrire et bien adapté au développement local sur une seule machine. Kubernetes demande davantage d'objets, mais offre en retour une résilience face aux redémarrages, un contrôle explicite des ressources, et un déploiement portable d'un cluster à l'autre.

## 7. Difficultés rencontrées (déploiement de base)

La principale difficulté a été la mémoire. La machine de développement disposait de 8 Go de RAM installés, mais seulement environ 5,9 Go utilisables par Windows, car environ 2 Go étaient réservés au GPU intégré. En plus de cela, `.wslconfig` demandait 6 Go pour WSL2, plus que ce que la machine pouvait réellement fournir, ce qui provoquait du swap. Cela s'est traduit par un pod Ollama bloqué à l'état `Unknown`, avec `kubectl describe pod` montrant des probes liveness et readiness en échec avec l'erreur `context deadline exceeded`, et finalement le conteneur se terminant de façon inattendue.

Diagnostiquer ce problème a demandé de vérifier la mémoire réellement disponible sur la machine (`systeminfo`, `Get-CimInstance Win32_PhysicalMemory`), de corriger `.wslconfig` à une valeur inférieure à la RAM utilisable, et de redimensionner minikube en conséquence. Comme les modèles nécessaires pour une comparaison complète (`mistral:7b`, `deepseek-r1:8b`) ne tenaient pas dans ce budget, le déploiement Kubernetes a été réduit à trois modèles plus légers — `llama3.2:3b`, `qwen2.5:0.5b` et `tinyllama:latest` — qui restent ensemble largement sous la limite mémoire configurée sur le Deployment Ollama, tout en couvrant trois familles de modèles différentes.

Cette expérience a directement influencé plusieurs choix de conception décrits plus haut : des délais de probe généreux plutôt que la valeur par défaut d'1 seconde, un seul replica par Deployment avec la stratégie `Recreate` pour éviter que deux pods se disputent la même mémoire limitée, et des limites de ressources dimensionnées pour les modèles réellement utilisés plutôt que pour les plus gros modèles disponibles.

## 8. Fonctionnalités bonus

Face aux mêmes contraintes de mémoire décrites à la section 7, les fonctionnalités bonus ont été implémentées et validées via un **pipeline GitHub Actions** plutôt que sur la machine de développement locale. Chaque push sur `k8s/**` ou sur le fichier de workflow déclenche un job qui provisionne un cluster Kubernetes éphémère (`kind`) sur les serveurs de GitHub, applique les manifestes, puis exécute une série de vérifications réelles sur ce cluster. Cette approche contourne entièrement la limite de RAM locale tout en produisant un résultat reproductible et vérifiable de façon indépendante : n'importe qui ayant accès au dépôt peut relancer exactement le même pipeline et obtenir le même résultat, ce qu'une simple capture d'écran locale ne permet pas.

### 8.1 Overlays Kustomize

Les manifestes sont séparés entre `k8s/base/` (les 9 ressources principales plus le HPA) et `k8s/overlays/dev/`, qui réduit les requests/limits CPU et mémoire et plafonne le HPA à 2 replicas afin que l'ensemble tienne confortablement sur un runner CI. L'overlay est assemblé avec `kubectl kustomize k8s/overlays/dev`, à la fois comme vérification locale et comme première étape du pipeline CI (`kubectl kustomize ... > rendered.yaml`).

### 8.2 Pipeline GitHub Actions

Le workflow (`.github/workflows/validate-k8s.yaml`) comporte deux jobs :

- **`validate`** : assemble l'overlay dev avec Kustomize et vérifie sa conformité aux schémas Kubernetes officiels avec `kubeconform`, entièrement hors ligne (aucun cluster requis pour cette étape).
- **`deploy`** : crée un cluster `kind`, applique l'overlay dev, attend que les deux Deployments soient prêts (`kubectl rollout status`), puis exécute les vérifications du HPA et du monitoring décrites ci-dessous dans ce même job, afin qu'elles partagent le même cluster actif.

### 8.3 HorizontalPodAutoscaler (HPA)

Un `open-webui-hpa` cible le Deployment Open WebUI et fait varier le nombre de replicas entre 1 et 2 (dans l'overlay dev) selon l'utilisation du CPU (70 %) et de la mémoire (80 %). Pour prouver qu'il scale réellement et n'est pas qu'un manifeste inutilisé, le pipeline installe `metrics-server`, lance un pod de charge éphémère qui envoie de nombreuses requêtes concurrentes vers Open WebUI, puis interroge `kubectl get hpa` toutes les 10 secondes. Lors du run enregistré, l'utilisation du CPU est montée à environ 470 % de la valeur demandée, et le HPA a fait passer Open WebUI de 1 à 2 replicas, son maximum configuré, confirmant que l'autoscaler réagit bien à une charge réelle.

### 8.4 Monitoring Prometheus et Grafana

Un namespace `monitoring` héberge un petit couple Prometheus/Grafana, déployé dans le même cluster `kind` :

- **Prometheus** est configuré avec le job de scrape cAdvisor standard de Kubernetes (via le proxy de nœud de l'API server, authentifié avec un jeton de ServiceAccount), qui remonte l'utilisation réelle du CPU et de la mémoire pour chaque conteneur du cluster, y compris les pods de `llm-app`.
- **Grafana** est provisionné automatiquement (source de données et dashboard sous forme de ConfigMaps) avec un tableau de bord affichant l'utilisation CPU par pod, l'utilisation mémoire par pod, et l'état des cibles, le tout filtré sur le namespace `llm-app`.

Le pipeline vérifie cette pile de deux façons : il interroge directement l'API HTTP de Prometheus (`/api/v1/targets` et des requêtes PromQL de CPU/mémoire par pod) et affiche les valeurs réelles et actuelles dans les logs du job ; et il utilise un navigateur headless (Playwright) pour se connecter à Grafana, ouvrir le tableau de bord, attendre que les panneaux affichent de vraies données, puis enregistrer une capture d'écran de la page entière, que le workflow met à disposition en téléchargement comme artefact du run.

### 8.5 Difficultés rencontrées lors de la construction du pipeline bonus

La construction de ce pipeline a fait apparaître plusieurs problèmes distincts, chacun retracé jusqu'à une ligne de log précise puis corrigé :

- Un patch Kustomize pointait vers un seul fichier contenant trois documents séparés par `---` ; le champ `patches:` exige un seul document par fichier, le patch a donc été séparé en trois fichiers distincts (un par ressource ciblée).
- Le runner GitHub-hosted n'avait pas `kubectl` préinstallé dans tous les jobs, corrigé en ajoutant une étape explicite `azure/setup-kubectl`.
- `kubectl apply --dry-run=client` tente malgré tout de contacter un cluster pour résoudre les types de ressources, même avec `--validate=false`, ce qui échoue quand aucun cluster n'existe encore ; cette étape a été remplacée par `kubeconform`, un validateur de schéma entièrement hors ligne.
- Le conteneur Open WebUI subissait des `OOMKilled` répétés (code de sortie 137) car la limite mémoire de l'overlay dev (512Mi) était trop basse pour son empreinte réelle au démarrage ; la faire passer à 1Gi a résolu la boucle de redémarrages.

Ce parcours de débogage est en soi instructif : il montre qu'un pipeline CI fait apparaître de vrais problèmes d'infrastructure (structure d'un patch, outil manquant, mémoire insuffisante) de la même façon qu'un déploiement local le ferait, mais avec un journal clair et horodaté pour chaque tentative.

## 9. Conclusion

Le déploiement satisfait toutes les conditions requises : les deux pods atteignent l'état `Running`, aucun pod n'entre en `CrashLoopBackOff` ni ne reste bloqué en `Pending`, Open WebUI communique correctement avec Ollama via le DNS interne du cluster, et les trois modèles sont visibles dans l'interface et répondent correctement aux requêtes. En plus de cela, quatre fonctionnalités bonus — overlays Kustomize, pipeline CI/CD GitHub Actions, HorizontalPodAutoscaler testé sous charge réelle, et pile de monitoring Prometheus/Grafana — ont été implémentées et validées de bout en bout dans ce même pipeline, transformant une contrainte matérielle en argument pour construire une infrastructure vérifiable indépendamment de toute machine particulière.