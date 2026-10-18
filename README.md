# pi-sandbox-windows 1.1.0

> Lance l'agent de codage [pi](https://github.com/earendil-works/pi-mono) dans un
> conteneur Docker isolé sur Windows — **directement depuis PowerShell**, comme
> sur mac. L'agent ne voit **que les dossiers que tu listes** — jamais ton
> profil, `~\.ssh`, `~\.pi\agent` de l'hôte, ni la valeur de tes clés API.
> Il a des limites : voir [ce que la sandbox ne protège pas](#ce-que-la-sandbox-ne-protège-pas).

Port Windows/PowerShell de pi-sandbox (macOS/OrbStack). Tout ce qui suit
`.\install.ps1` est automatique : chaque lancement de `pi` vérifie les nouvelles
versions de pi et de rtk et reconstruit l'image en arrière-plan si besoin.

## Prérequis

- **Docker Desktop** (Windows), backend WSL2 par défaut. Vérifie dans
  *Settings → General* que **« Expose daemon on tcp://localhost:2375 without
  TLS » est désactivé** : activé, le conteneur pourrait piloter Docker, donc l'hôte.
- **PowerShell 5.1** (préinstallé) ou PowerShell 7. Pas besoin d'ouvrir WSL.

## Fichiers

| Fichier | Rôle |
|---------|------|
| `Dockerfile.pi` | Image : Node 24 + pi + git + ripgrep + Python + rtk (hash SHA-256 vérifié) |
| `install.ps1` | Setup : image, config, hook rtk, clés API, launcher |
| `pi.ps1` | Lance le conteneur (+ sidecar keyproxy), vérifie les mises à jour |
| `update-pi-sandbox.ps1` | Suit pi et rtk, repinne les hashes, reconstruit l'image |
| `pi.config.example.ps1` | Modèle de config ; copié en `pi.config.ps1` (ignoré par git) au 1er lancement |
| `lib/pi-sandbox.ps1` | Fonctions partagées (chemins protégés, clés, lock…) |
| `proxy/keyproxy.mjs` | Sidecar qui ajoute les vraies clés aux requêtes sortantes |
| `config/settings*.json` | Défauts pi (extensions, modèle DeepSeek si opt-in) |
| `config/models.json` | URLs des providers via keyproxy, monté en lecture seule |
| `tests/` | Tests Pester |

## Installation

```powershell
cd "E:\DEV perso\Other projects\pi-sandbox-windows"
.\install.ps1
```

L'installeur construit l'image, initialise le volume `pi-agent-home` (sans
écraser un `settings.json` existant), installe le hook rtk, propose DeepSeek,
**demande tes clés API** (saisie masquée, stockées dans le Gestionnaire
d'identifiants Windows) et installe le launcher `pi` dans `%USERPROFILE%\.pi\bin`
(`pi.cmd` pour cmd/PowerShell, `pi` pour Git Bash). Ouvre un **nouveau** terminal ensuite.

Les extensions déclarées dans `config/settings.json` sont installées par pi au
premier lancement. Relancer `.\install.ps1` conserve celles ajoutées avec `!pi install`.

## Configuration

Tout vit dans `pi.config.ps1` (chemins **Windows**) :

```powershell
$ALLOWED = @(                      # dossiers que le conteneur peut voir
  "E:\DEV perso\Other projects\mon-projet"
)
$API_KEYS = @("TAVILY_API_KEY", "OPENAI_API_KEY")
$DOCKER_ARGS = @("-e", "PI_SKIP_VERSION_CHECK=1")
```

Ne liste **jamais** pi-sandbox-windows, un de ses sous-dossiers ou un parent (`E:\`,
ton profil) : `pi.ps1` les ignore, comme les dossiers de profil PowerShell et
`~\.pi\bin`. Les chemins sont comparés sans tenir compte de la casse, après
résolution des junctions, noms courts (`DEVPER~1`) et lecteurs `subst`.

## Clés API

Stockées dans le **Gestionnaire d'identifiants Windows**, cible
`pi-sandbox:<NOM>`. Pour ajouter ou changer une clé, relance `.\install.ps1`
(une clé déjà présente est gardée : supprime-la d'abord avec
`cmdkey /delete:pi-sandbox:OPENAI_API_KEY`). N'utilise jamais
`cmdkey /pass:<clé>` : la clé finirait dans l'historique.

Au lancement, DeepSeek / OpenAI / Tavily ne vont qu'au sidecar keyproxy : pi
reçoit la valeur `proxy`, le sidecar ajoute la vraie clé aux requêtes vers ces
3 API. Les clés ne passent jamais dans la ligne de commande de `docker.exe`.

Une variable définie dans le shell courant (`$env:OPENAI_API_KEY = …`) l'emporte
sur le Gestionnaire, pour un lancement. **N'utilise plus `setx`** : la clé est
alors en clair dans le registre et héritée par tous les process ; `pi.ps1`
avertit si une clé y est encore.

Limite : contrairement au Trousseau macOS, tout programme lancé sous ton compte
peut lire un identifiant générique. Le gain porte sur le registre en clair,
l'héritage par tous les process et la fuite vers l'agent, pas sur un malware local.

## Utilisation

```powershell
pi   # depuis PowerShell, cmd ou Git Bash
```

- **Dans un dossier autorisé** → seul ce dossier est monté, à son chemin réel
  (`E:\...` apparaît en `/e/...` dans le conteneur).
- **Ailleurs** → `y` ajoute le dossier à `$ALLOWED` et relance confiné, `n`
  monte tous les dossiers autorisés sous `/workspace/<nom>` (`api`, `api-2` si
  deux dossiers ont le même nom ; un dossier absent est ignoré).

Les montages sont figés au démarrage : édite `pi.config.ps1`, quitte (`Ctrl-D`), relance.

## Extensions

```
!pi install npm:@author/package
/reload
```

Elles persistent dans le volume `pi-agent-home` et tournent avec les droits de
l'agent : n'installe que des sources de confiance.

## Mises à jour

Automatiques : à chaque lancement, `pi.ps1` compare les versions de pi et rtk
embarquées aux dernières publiées et reconstruit l'image en arrière-plan
(`logs\update-<date>.log`). Le hash de rtk est repinné depuis son
`checksums.txt` ; sans hash, pas de mise à jour. Manuel :

```powershell
.\update-pi-sandbox.ps1           # reconstruit maintenant
.\update-pi-sandbox.ps1 -Status   # up-to-date ou stale:<quoi>
```

## Modèles locaux (llama.cpp)

L'extension [pi-llama-cpp](https://pi.dev/packages/pi-llama-cpp) accède à
llama.cpp sur l'hôte via `host.docker.internal:8083` (voir `llamaServerUrl`
dans `config/settings.json`). Autre URL : `"-e", "LLAMA_SERVER_URL=…"` dans
`$DOCKER_ARGS` (ce n'est pas un secret, pas dans `$API_KEYS`).

`llama-server --host 0.0.0.0` l'expose aussi à ton réseau local ; garde le
pare-feu Windows actif pour ce port.

## Ce que la sandbox ne protège pas

- **Les fichiers des dossiers autorisés** sont lisibles : `.env`, tokens,
  identifiants. Garde tes secrets ailleurs.
- **Les clés peuvent être dépensées**, y compris chez un autre provider
  proxifié que celui du modèle choisi. Ne garde que les clés utiles et fixe un
  plafond de dépense sur chacune.
- **Les clés sans route** (autres que DeepSeek, OpenAI, Tavily) sont passées
  en clair à l'agent ; `pi.ps1` l'affiche au lancement.
- **N'utilise jamais `/login` dans pi** : la clé serait enregistrée là où l'agent la lit.
- **Les services de l'hôte** restent joignables via `host.docker.internal`
  (llama.cpp, mais aussi tout autre serveur local).
- **Les fichiers écrits peuvent s'exécuter sur l'hôte** : hooks git,
  `core.fsmonitor` dans `.git/config`, `.vscode/tasks.json`, scripts npm,
  `.ps1` / `.bat`. Piège : `core.fsmonitor` est exécuté par le simple
  `git status` que lance un prompt posh-git / oh-my-posh en entrant dans le
  dossier. Relis les changements de l'agent avant de lancer quoi que ce soit.

## Tests

```powershell
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck   # Windows n'a que Pester 3.4
Invoke-Pester .\tests
node .\proxy\keyproxy.mjs --selftest
```

## Dépannage

| Problème | Solution |
|----------|----------|
| `failed to connect ... docker` | Démarre Docker Desktop, attends le vert, relance |
| `⚠ skipping …` | Le dossier est le repo, un parent ou un dossier de profil : choisis un sous-dossier de projet |
| `⚠ folder not found: ...` | Corrige le chemin dans `$ALLOWED` |
| Provider non authentifié | `cmdkey /list` doit montrer `pi-sandbox:<NOM>` ; sinon relance `.\install.ps1` |
| `--network … conflicts with keyproxy` | Retire `--network` de `$DOCKER_ARGS` |
| Launcher `pi` inconnu | Ouvre un nouveau terminal, ou relance `.\install.ps1` |
