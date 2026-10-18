# Changelog

## [1.1.0] — 2026-10-18

Mise à niveau sécurité au niveau de pi-sandbox 1.1.0 (macOS).

> **À faire après la mise à jour** : stocker les clés avec `.\install.ps1`,
> supprimer les variables `setx`
> (`[Environment]::SetEnvironmentVariable('<NOM>', $null, 'User')`), puis
> **faire la rotation** des clés DeepSeek / OpenAI / Tavily : elles ont
> transité en clair (ligne de commande de docker, environnement du conteneur,
> registre) et peuvent figurer dans les transcripts du volume `pi-agent-home`.

### Security
- `pi.ps1` refuse de monter le repo, un de ses sous-dossiers ou un parent, ainsi
  que `~\.pi\bin`, les profils PowerShell 5.1/7 et le dossier Démarrage : l'agent
  pouvait réécrire `pi.ps1` / `pi.config.ps1`, exécutés sur l'hôte au lancement
  suivant. Chemins résolus (junctions, noms 8.3, `subst`) et comparés sans casse.
- Un dossier ajouté à `$ALLOWED` est écrit entre quotes simples échappées : un
  dossier nommé `x$(calc)` exécutait `calc` à chaque lancement.
- Clés API dans le Gestionnaire d'identifiants Windows au lieu de `setx`, jamais
  dans la ligne de commande de `docker.exe`, retirées de l'environnement du shell
  à la sortie.
- Sidecar keyproxy : DeepSeek, OpenAI et Tavily ne voient que la valeur `proxy`
  dans le conteneur. Réseau privé par session, sidecar durci, orphelins supprimés
  (propriétaire = PID + heure de démarrage).
- rtk vérifié par SHA-256 (`v1.0.1`), hashes repinnés par l'updater.
- Lock de l'updater récupéré s'il est orphelin (un updater tué désactivait les
  mises à jour pour toujours).

### Changed
- Projet renommé `pi-sandbox-windows` (il n'utilise pas WSL directement : seul Docker Desktop s'en sert).
- `pi.config.ps1` ignoré par git, créé depuis `pi.config.example.ps1`.
- `install.ps1` ne réécrit plus `settings.json` (extensions conservées) ;
  l'opt-in DeepSeek fusionne au lieu d'écraser. Les extensions sont installées
  par pi depuis `config/settings.json`.
- `IMAGE` / `VOLUME` / `RTK_VOLUME` lus depuis la config partout.
- L'updater suit pi et rtk, garde `Dockerfile.pi` en UTF-8, supprime
  l'ancienne image par ID, ne bloque jamais plus de 2 s par sonde.
- Image : Python ajouté ; caches dans le volume (`XDG_CACHE_HOME`).
- Settings alignés : `npm:@dietrichgebert/ponytail`, `npm:pi-deepseek-peak`,
  modèle `deepseek-flash`.

### Fixed
- Dossier courant reconnu sans tenir compte de la casse (doublons dans `$ALLOWED`).
- Un dossier manquant dans `$ALLOWED` est ignoré au lieu de bloquer le lancement ;
  deux dossiers de même nom ne se masquent plus.
- `pi.ps1` / `install.ps1` ne changent plus le dossier courant du shell appelant.
- PowerShell 7.3+ : passage d'arguments forcé en mode `Legacy`.

## [0.1.1]

Portage PowerShell de pi-sandbox 0.1.1.
