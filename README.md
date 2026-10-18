# pi-sandbox-wsl

> Lance l'agent de codage [pi](https://github.com/earendil-works/pi-mono) dans un
> conteneur Docker isolé sur Windows — **directement depuis PowerShell**, comme
> sur mac. L'agent ne voit **que les dossiers que tu listes** et Internet —
> jamais ton home, `~/.ssh` ni `~/.pi/agent` de l'hôte.

Port Windows/PowerShell de pi-sandbox (macOS/OrbStack). Tout ce qui suit
`.\install.ps1` est automatique : chaque lancement de `pi` vérifie les nouvelles
versions et reconstruit l'image en arrière-plan si besoin, config et extensions
persistent, et rtk compresse la sortie bash — aucune étape manuelle.

## Prérequis

- **Docker Desktop** (Windows), backend WSL2 par défaut.
- **PowerShell 5.1+** (préinstallé) ou PowerShell 7. Pas besoin d'ouvrir WSL :
  tout se lance depuis PowerShell, cmd ou Windows Terminal.

```powershell
docker version   # doit répondre "server: x.y.z"
```

## Fichiers

| Fichier | Rôle |
|---------|------|
| `Dockerfile.pi` | Image : Node 24 + pi + git + ripgrep + rtk |
| `install.ps1` | Setup unique : image, config, extensions, launcher |
| `pi.ps1` | Lance le conteneur (lit `pi.config.ps1`, vérifie les mises à jour) |
| `update-pi-sandbox.ps1` | Vérifie pi.dev pour une pi plus récente, reconstruit l'image |
| `pi.config.ps1` | Toute la config : dossiers autorisés (chemins Windows `E:\...`), clés API, options docker |
| `config/settings.json` | Défauts de modèle (aucun provider par défaut — pi demande au 1er lancement) |
| `config/settings.deepseek.json` | Défauts DeepSeek (installé seulement si opt-in) |

## Installation

```powershell
cd "E:\DEV perso\Other projects\pi-sandbox-wsl"
.\install.ps1
```

Ce que ça fait :

1. Vérifie Docker et démarre Docker Desktop si besoin.
2. Construit l'image pi (Node 24, pi épinglé à `0.84.3` — voir `Dockerfile.pi`).
3. Installe la config modèle dans le volume `pi-agent-home` (pas de provider par
   défaut ; niveau de réflexion `high`).
4. Installe les extensions prédéfinies (ponytail, pi-web-access, pi-plan-mode,
   pi-ask-mode).
5. Installe le hook **rtk** (compresse la sortie bash) et crée le volume
   `rtk-data` pour que son historique survive à la recréation du conteneur.
6. Demande si tu veux DeepSeek : `y` installe `pi-deepseek-peak`, restaure les
   défauts deepseek et ajoute `DEEPSEEK_API_KEY` à `pi.config.ps1`.
7. Affiche les clés API à définir (`setx NAME "value"`, `TAVILY_API_KEY`
   toujours optionnelle).
8. Installe le launcher `pi` dans `%USERPROFILE%\.pi\bin` (ajouté au PATH utilisateur) :
   - `pi.cmd` pour cmd et PowerShell
   - `pi` (script bash avec shebang) pour Git Bash
   Ouvre un **nouveau** terminal après l'install.

Relancer `.\install.ps1` reconstruit l'image avec **la même version épinglée** et
réinitialise la config du volume. Ça ne met pas à jour pi — les mises à jour ont
lieu au lancement (voir plus bas).

## Configuration

Tout vit dans `pi.config.ps1` (chemins **Windows**, pas WSL) :

```powershell
$ALLOWED = @(                      # dossiers que le conteneur peut voir
  "E:\DEV perso\Other projects\pi-sandbox-wsl"
)
$API_KEYS = @("TAVILY_API_KEY", "OPENAI_API_KEY")   # transmises si définies
$IMAGE = "pi-sandbox"
$VOLUME = "pi-agent-home"          # sessions, config, extensions (persistent)
$RTK_VOLUME = "rtk-data"           # historique rtk
$WORKSPACE = "/workspace"
$DOCKER_ARGS = @("-e", "PI_SKIP_VERSION_CHECK=1")   # ex. "--network none"
```

> ⚠ `~/.pi/agent` de l'hôte n'est **jamais monté** : sessions, config et
> extensions de pi vivent dans le volume nommé `pi-agent-home` ; l'historique
> rtk dans `rtk-data`. Les deux sont isolés de l'hôte.

## Utilisation

`pi` fonctionne depuis **PowerShell**, **cmd** et **Git Bash** (installé par install.ps1) :

```powershell
pi   # depuis n'importe quel shell — un nouveau terminal est nécessaire après l'install
```

Ou directement :

```powershell
.\pi.ps1   # depuis le dossier pi-sandbox-wsl (PowerShell uniquement)
```

- **Dans un dossier autorisé** → le conteneur monte uniquement ce dossier et pi
  démarre là (fonctionne depuis les sous-dossiers). Le footer montre
  l'emplacement réel, ex. `/e/DEV perso/Other projects/pi-sandbox-wsl (main)`
  (le chemin Windows `E:\...` apparaît en `/e/...` dans le conteneur).
- **Ailleurs** → pi demande s'il faut ajouter le dossier courant à `$ALLOWED` ;
  `y` pour le whitelister et relancer confiné, `n` pour monter tous les dossiers
  autorisés sous `/workspace/<nom>`.

Dans la session : `!pwd` montre où tu es, `/reload` recharge les extensions
fraîchement ajoutées.

### Ajouter / retirer un dossier autorisé

Les montages sont figés au démarrage du conteneur : édite `$ALLOWED` dans
`pi.config.ps1`, quitte la session (`Ctrl-D`), relance. Sessions et config sont
conservées — seuls les montages changent. Ou laisse pi te le demander à la
volée avec le prompt `[y/N]`.

## Extensions

Depuis la session pi (recommandé) :

```
!pi install npm:@author/package
!pi install git:github.com/user/repo
!curl -L -o ~/.pi/agent/extensions/my-ext.ts https://url/file.ts
/reload
```

Depuis l'hôte :

```powershell
docker run --rm -v pi-agent-home:/root/.pi/agent pi-sandbox install npm:@author/package
```

Les extensions persistent entre les lancements (volume `pi-agent-home`).
Désinstallation avec `!pi uninstall npm:@author/package`.

> 🔒 Les extensions tournent avec les permissions du processus pi : dans le
> conteneur elles ne peuvent pas toucher l'hôte au-delà des dossiers montés.
> N'installe que des sources de confiance.

## Mettre à jour pi

Automatique : à chaque lancement, `pi.ps1` compare la version embarquée à la
dernière version de pi.dev et reconstruit l'image en arrière-plan
(`logs\update-<date>.log`). Quitte et relance pour l'utiliser.

Manuel :

```powershell
.\update-pi-sandbox.ps1    # reconstruit maintenant (bloquant)
.\update-pi-sandbox.ps1 -Status   # up-to-date ou stale:<v>
```

## Modèles locaux (llama.cpp)

L'extension [pi-llama-cpp](https://pi.dev/packages/pi-llama-cpp) est installée par
défaut : elle donne accès à tes modèles GGUF servis par llama.cpp sur l'hôte.

- Lance llama.cpp sur l'hôte (Windows) :
  `llama-server --host 0.0.0.0 --port 8083 --models-preset ...` (ou `--model ...`)
- Le conteneur y accède via `host.docker.internal` (le `localhost` du conteneur,
  c'est le conteneur) : `config/settings.json` contient déjà
  `"llamaServerUrl": "http://host.docker.internal:8083"`.
- Autre port ? Édite `config/settings.json` (ou définis `LLAMA_SERVER_URL` sur
  l'hôte — déjà dans `$API_KEYS`, donc transmis au conteneur).
- Les modèles sont auto-détectés par l'extension (pas de noms à configurer).

## Dépannage

| Problème | Solution |
|----------|----------|
| `docker: command not found` | Docker Desktop n'est pas installé, ou le CLI n'est pas dans le PATH Windows |
| `failed to connect ... docker` | Démarre Docker Desktop, attends le vert, relance |
| `⚠ folder not found: ...` | Corrige le chemin dans `$ALLOWED` (chemins Windows `E:\...`) |
| pi ne voit pas un dossier | Vérifie `$ALLOWED` et relance après l'édition |
| Pas de clé API trouvée | `setx NAME "value"` puis **nouveau** terminal, ou défini-la dans ton profil PowerShell |
| Launcher `pi` inconnu | Ouvre un nouveau terminal (PATH utilisateur mis à jour par install.ps1), ou relance `.\install.ps1` |
