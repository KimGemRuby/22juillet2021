# bokador-link — conception

Kit qui établit et maintient une liaison SSH **permanente, persistante et auto-réparatrice**
entre un PC Windows (« bokador », le client) et un VPS Linux (le serveur).

Ce document est le contrat entre les composants. Toute divergence entre le code et ce
document est un bug de l'un ou de l'autre.

## 1. Objectifs et non-objectifs

Objectifs :

- La liaison se rétablit seule après : coupure réseau, redémarrage du VPS, redémarrage ou
  mise en veille du PC, plantage de `ssh.exe`, suppression accidentelle d'une tâche planifiée.
- Boucle de rétroaction à deux niveaux, chacun surveillant l'autre :
  superviseur (processus long) ↔ chien de garde (tâche périodique), et PC ↔ VPS (battement de cœur).
- Installation en une commande, idempotente ; désinstallation complète en une commande.
- Rien n'est modifié en dehors du périmètre du kit (voir §7).

Non-objectifs :

- Le kit ne crée, ne déplace, ne copie et n'affiche jamais de clé privée existante.
- Il ne modifie pas `sshd_config`, le pare-feu ni `authorized_keys` du VPS.
- Il n'installe aucun service entrant sur le PC (pas d'OpenSSH Server).
- Aucune adresse IP, aucun nom d'utilisateur réel, aucun secret dans le dépôt : tout est
  passé en paramètre à l'installation.

## 2. Arborescence du dépôt

```
windows/Install-BokadorLink.ps1      installateur (lancé depuis le dépôt)
windows/Uninstall-BokadorLink.ps1    désinstallateur
windows/Get-BokadorLinkStatus.ps1    état lisible par un humain
windows/Link-Supervisor.ps1          processus long : maintient le tunnel
windows/Link-Watchdog.ps1            tâche périodique : boucle de rétroaction
windows/lib/BokadorLink.Common.ps1   fonctions partagées (dot-sourcées)
windows/launch-hidden.vbs            lanceur sans fenêtre (mode Interactive)
vps/bokador-link                     assistant côté VPS (bash, un seul fichier)
tests/run-tests.sh                   lance tous les tests exécutables sous Linux
tests/test-vps-unit.sh               tests unitaires de vps/bokador-link (BL_ROOT)
tests/test-integration.sh            test bout en bout avec un sshd local
tests/ps-static-check.py             contrôles statiques des .ps1
docs/DESIGN.md                       ce document
```

## 3. Règles de codage

### PowerShell

- Compatible **Windows PowerShell 5.1** (celui livré avec Windows). Interdits : opérateur
  ternaire, `??`, `?.`, `&&`, `||` entre commandes, `ForEach-Object -Parallel`,
  `Join-String`, `ConvertFrom-Json -AsHashtable`, `-Depth` de `ConvertFrom-Json`,
  `Start-Process` pour les appels dont on lit la sortie.
- Fichiers `.ps1` **ASCII pur** (PS 5.1 lit les fichiers sans BOM en ANSI). Les messages
  destinés à l'utilisateur sont en français sans accents.
- Style conventionnel multi-lignes : un `param(...)` par bloc sur ses propres lignes,
  accolade ouvrante en fin de ligne, `else`/`catch`/`finally` sur une nouvelle ligne ou
  après `}`. (Ce style n'est pas contrôlé automatiquement.)
- `Set-StrictMode -Version 2.0` et `$ErrorActionPreference = 'Stop'` en tête de chaque script.
- Tout exécutable natif dont on lit la sortie ou dont on borne la durée passe par
  `Invoke-BLNative` (jamais de pipeline PowerShell vers `ssh.exe` : PS 5.1 y injecterait
  des CRLF et un encodage ASCII).
- Aucune valeur de configuration n'est interpolée dans une ligne de commande sans avoir été
  validée par les expressions régulières du §4.2.

### Bash

- `#!/usr/bin/env bash`, `set -euo pipefail`, compatible bash 4.2+, passe `shellcheck` sans avertissement.
- Fins de ligne LF (imposées par `.gitattributes`).
- Le fichier de configuration côté VPS est **analysé**, jamais « sourcé ».

## 4. Côté Windows

### 4.1 Répertoire d'installation

`$BLRoot` vaut, par ordre de priorité : la variable d'environnement `BOKADORLINK_HOME` ;
sinon, pour un script situé dans `<racine>\bin\`, le parent de `$PSScriptRoot` si
`<racine>\config.json` existe ; sinon `$env:LOCALAPPDATA\BokadorLink`.

```
config.json                      configuration (§4.2)
ssh_config                       configuration SSH générée, passée avec -F (§4.3)
known_hosts                      clés d'hôte propres au kit (TOFU, §4.6 étape 3)
state.json                       état du chien de garde (§4.5)
bin\                             copie des scripts : Link-Supervisor.ps1, Link-Watchdog.ps1,
                                 Get-BokadorLinkStatus.ps1, Uninstall-BokadorLink.ps1,
                                 lib\BokadorLink.Common.ps1, launch-hidden.vbs, vps\bokador-link
logs\supervisor.log  logs\watchdog.log  logs\install.log  logs\ssh-tunnel.err.log
run\supervisor.pid   run\tunnel.pid     run\stop.flag
tasks\BokadorLink-Tunnel.xml     définitions exportées, pour l'auto-réparation
tasks\BokadorLink-Watchdog.xml
```

Les journaux tournent à 1 Mo (3 archives conservées). Les fichiers d'état sont écrits de
façon atomique (fichier temporaire puis remplacement).

Un fichier pid contient du JSON : `{ "Pid": 1234, "StartTimeUtc": "<ISO 8601>" }`. Un
processus n'est reconnu comme « le nôtre » que si le pid existe, que son nom correspond
(`ssh` ou `powershell`) et que son heure de démarrage concorde à 5 secondes près. Cela évite
de tuer un processus étranger après réutilisation du pid.

### 4.2 `config.json`

```json
{
  "SchemaVersion": 1,
  "HostAlias": "bokador-link-vps",
  "VpsHost": "<hôte>",
  "VpsPort": 22,
  "VpsUser": "root",
  "IdentityFile": "C:\\chemin\\vers\\la\\cle",
  "SshExe": "C:\\Windows\\System32\\OpenSSH\\ssh.exe",
  "Forwards": [],
  "WatchdogMinutes": 3,
  "VpsHelper": "/usr/local/sbin/bokador-link",
  "VpsSideInstalled": true,
  "ClientLabel": "<COMPUTERNAME assaini>",
  "TaskMode": "S4U",
  "InstalledAtUtc": "<ISO 8601>"
}
```

Validation (à l'écriture **et** à chaque lecture ; une configuration invalide arrête le
script avec une erreur claire) :

| Champ | Règle |
|---|---|
| `VpsHost` | `^[A-Za-z0-9]([A-Za-z0-9.\-]{0,252}[A-Za-z0-9])?$` ou IPv6 `^[0-9A-Fa-f:]{2,39}$` |
| `VpsUser` | `^[a-z_][a-z0-9_\-]{0,31}$` |
| `VpsPort` | entier 1..65535 |
| `HostAlias` | `^[A-Za-z0-9][A-Za-z0-9\-]{0,62}$` |
| `VpsHelper` | `^/[A-Za-z0-9/._\-]{1,200}$` |
| `ClientLabel` | `^[A-Za-z0-9._\-]{1,64}$` |
| `WatchdogMinutes` | entier 1..60 |
| `Forwards[i]` | `^(L\|R) (127\.0\.0\.1\|localhost):([0-9]{1,5}) ([A-Za-z0-9.\-]{1,253}):([0-9]{1,5})$` |
| `IdentityFile`, `SshExe` | chemin absolu existant, sans `"` ni saut de ligne |

Un `Forwards[i]` `"R 127.0.0.1:22022 127.0.0.1:3389"` devient l'argument
`-R 127.0.0.1:22022:127.0.0.1:3389`. Seules les liaisons en boucle locale sont acceptées.
Liste vide par défaut : le tunnel est alors une simple session maintenue ouverte.

### 4.3 `ssh_config` généré

```
Host bokador-link-vps
    HostName <VpsHost>
    Port <VpsPort>
    User <VpsUser>
    IdentityFile "<IdentityFile, séparateurs />"
    IdentitiesOnly yes
    BatchMode yes
    PasswordAuthentication no
    StrictHostKeyChecking yes
    UserKnownHostsFile "<BLRoot>/known_hosts" "<USERPROFILE>/.ssh/known_hosts"
    ServerAliveInterval 30
    ServerAliveCountMax 3
    TCPKeepAlive yes
    ConnectTimeout 15
    ConnectionAttempts 1
    ExitOnForwardFailure yes
    LogLevel ERROR
```

Le `~/.ssh/config` de l'utilisateur n'est **jamais** modifié : tous les appels utilisent
`ssh.exe -F "<BLRoot>\ssh_config"`. Tous les chemins sont absolus (le mode S4U ne garantit
pas la résolution de `~`).

Seuls des mots-clés reconnus par OpenSSH 7.7 sont employés : c'est la plus ancienne version
livrée avec Windows 10, et un mot-clé inconnu fait échouer `ssh.exe` dès la lecture du
fichier. En particulier, pas de `KbdInteractiveAuthentication` (apparu en 8.7) : `BatchMode
yes` suffit à interdire toute invite.

### 4.4 `lib/BokadorLink.Common.ps1` — API

Fonctions (toutes préfixées `BL`), signatures indicatives :

- `Get-BLRoot` → chaîne. `Get-BLPaths` → table de hachage de tous les chemins du §4.1.
- `Test-BLConfigObject -Config $obj` → liste d'erreurs (vide si valide).
  `Read-BLConfig` → objet validé (lève une erreur sinon). `Write-BLConfig -Config $obj`.
- `Write-BLLog -Name <supervisor|watchdog|install> -Level <INFO|WARN|ERROR> -Message <texte>`.
- `ConvertTo-BLForwardArgs -Forwards <string[]>` → `string[]` (`-L`/`-R` + spécification).
- `Join-BLArguments -ArgumentList <string[]>` → ligne de commande Windows correctement
  échappée (règles de `CommandLineToArgvW` : guillemets si espace/tabulation/guillemet ou
  chaîne vide, doublement des antislashs précédant un guillemet).
- `Invoke-BLNative -FilePath -ArgumentList -StdinBytes <byte[]> -TimeoutSec <int>` →
  `@{ ExitCode; StdOut; StdErr; TimedOut }`. Utilise `System.Diagnostics.Process`, sans
  fenêtre, lectures asynchrones de stdout/stderr (pas d'interblocage), écrit `StdinBytes`
  tels quels puis ferme stdin (stdin fermé immédiatement si absent), tue l'arbre de
  processus au dépassement du délai.
- `Invoke-BLSsh -Config -RemoteCommand <texte> [-StdinBytes] [-TimeoutSec 30] [-ExtraOptions <string[]>]`
  → même résultat ; exécute `ssh.exe -F <ssh_config> [options] <HostAlias> <RemoteCommand>`.
- `Test-BLTcp -HostName -Port -TimeoutMs` → booléen (connexion TCP brute).
- `Write-BLPidFile -Path -Process`, `Get-BLTrackedProcess -Path -ExpectedName` → processus ou `$null`.
- `Read-BLState` → objet (valeurs par défaut si absent/corrompu). `Write-BLState -State`.
- `Get-BLTaskNames` → `@{ Tunnel = 'BokadorLink-Tunnel'; Watchdog = 'BokadorLink-Watchdog' }`.
- `Test-BLTask -Name` → `@{ Exists; Enabled; State }`.
  `Repair-BLTask -Name` → ré-enregistre depuis `tasks\<Name>.xml` si absente, réactive si
  désactivée ; renvoie la liste des actions faites.
- `Get-BLClassifiedSshFailure -Result` → `network | auth | hostkey | timeout | unknown`
  d'après le code de sortie 255 et stderr (`Permission denied`, `Host key verification failed`,
  `REMOTE HOST IDENTIFICATION HAS CHANGED`, `Connection timed out`, `Connection refused`,
  `Could not resolve hostname`, `No route to host`).

### 4.5 Boucles

**Superviseur** (`Link-Supervisor.ps1`, tâche `BokadorLink-Tunnel`) :

1. Prend le mutex nommé `Global\BokadorLink-Supervisor` (repli sur `Local\` si refusé).
   S'il est déjà pris : sortie 0. Écrit `run\supervisor.pid`.
2. Boucle infinie :
   a. si `run\stop.flag` existe : tue le tunnel suivi, sortie 0 ;
   b. lance `ssh.exe -F <ssh_config> -E <logs\ssh-tunnel.err.log> -n -N -T <args de redirection> <HostAlias>`
      (les diagnostics de ssh vont dans le fichier via `-E` : aucun flux redirigé à vider,
      et le pid suivi est bien celui de `ssh.exe`), écrit `run\tunnel.pid` ;
   c. attend la fin par tranches de 5 s ; toutes les 10 minutes, appelle
      `Repair-BLTask` sur la tâche du chien de garde (le superviseur répare le chien de garde) ;
   d. à la fin du processus : journalise le code de sortie et la durée. Durée ≥ 300 s :
      délai remis à 2 s. Sinon délai = min(délai × 2, 60 s). Attend le délai (plus un aléa
      de 0 à 1 s), puis recommence.
3. Toute exception non prévue est journalisée, puis la boucle continue après 30 s. Le
   script ne se termine que sur `stop.flag` ou mutex déjà pris.

**Chien de garde** (`Link-Watchdog.ps1`, tâche `BokadorLink-Watchdog`, toutes les
`WatchdogMinutes` minutes) — une exécution = un tour de la boucle de rétroaction, budget
total 150 s :

1. Mutex `Global\BokadorLink-Watchdog` (sortie 0 si déjà pris). Charge config et état.
2. **Mesure** :
   - `Supervisor` : `Get-BLTrackedProcess run\supervisor.pid powershell` non nul ;
   - `Tunnel` : `Get-BLTrackedProcess run\tunnel.pid ssh` non nul ;
   - `Probe` : si `VpsSideInstalled`, `Invoke-BLSsh "<VpsHelper> heartbeat <ClientLabel>"`
     et la sortie contient une ligne `^BOKADOR_LINK_OK ([0-9]+) (up|down|unknown)$` ;
     sinon `Invoke-BLSsh "echo BOKADOR_LINK_OK"`. Cette sonde ouvre une connexion neuve :
     elle valide réseau, clé d'hôte et authentification de bout en bout, et dépose le
     battement de cœur sur le VPS ;
   - `Forwards` : pour chaque `R` : `Invoke-BLSsh "<VpsHelper> probe-port <port>"` renvoie
     `PORT <port> OPEN` ; pour chaque `L` : `Test-BLTcp 127.0.0.1 <port>`. Vrai si la liste est vide.
     (Les sondes `R` sont ignorées si `VpsSideInstalled` est faux.)
3. **Décision / réparation** — fonction récursive `Invoke-BLRepairCycle -Depth n`, profondeur
   maximale 3 ; après chaque action, on re-mesure et on rappelle la fonction :
   - tout est vrai → sain, fin ;
   - `Probe` faux et `Test-BLTcp VpsHost VpsPort` faux → cause `network` : rien à réparer
     localement, fin (le prochain tour réessaiera) ;
   - `Probe` faux avec cause `auth` ou `hostkey` → **aucune action automatique** (jamais
     d'acceptation automatique d'une clé d'hôte modifiée), état marqué `NeedsHuman`, fin ;
   - `Supervisor` faux → `Repair-BLTask Tunnel` puis `Start-ScheduledTask`, attente 15 s, récursion ;
   - `Tunnel` faux ou `Forwards` faux alors que `Probe` est vrai → tue le `ssh` suivi
     (uniquement celui de `run\tunnel.pid`), le superviseur le relance ; attente 15 s, récursion.
4. **Auto-contrôle** : `Repair-BLTask Tunnel` (le chien de garde répare le superviseur).
5. Écrit `state.json`, journalise une ligne de synthèse, code de sortie 0 si sain, 1 sinon.

`state.json` :

```json
{
  "SchemaVersion": 1,
  "LastRunUtc": "", "Healthy": false, "LastOkUtc": "",
  "ConsecutiveFailures": 0, "LastFailureReason": "none",
  "NeedsHuman": false,
  "RepairsTotal": 0, "LastRepairUtc": "", "LastRepairAction": "",
  "VpsView": "unknown",
  "Checks": { "Supervisor": false, "Tunnel": false, "Probe": false, "Forwards": false }
}
```

`LastFailureReason` ∈ `none | network | auth | hostkey | timeout | tunnel | supervisor | forwards | unknown`.

### 4.6 Installateur `Install-BokadorLink.ps1`

Paramètres : `-VpsHost` (obligatoire), `-VpsUser root`, `-VpsPort 22`, `-IdentityFile`
(facultatif), `-Forward <string[]>`, `-WatchdogMinutes 3`, `-SkipVps`, `-InteractiveOnly`
(ne tente pas S4U), `-DryRun` (décrit sans rien modifier).

Codes de sortie : `0` liaison saine ; `1` échec ; `2` intervention humaine requise (aucune
clé fonctionnelle : la clé publique à autoriser est affichée) ; `3` client OpenSSH absent.

Étapes :

0. Analyse tous les `.ps1` du kit avec `[System.Management.Automation.Language.Parser]::ParseFile` ;
   arrêt à la moindre erreur (rien n'a encore été modifié).
1. Localise `ssh.exe`, `ssh-keygen.exe` (`Get-Command`, puis `%SystemRoot%\System32\OpenSSH`).
   Absent → message expliquant `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0`, sortie 3.
2. Choix de la clé. Candidats : `-IdentityFile` si fourni ; sinon les fichiers de
   `%USERPROFILE%\.ssh` qui ont un `.pub` jumeau, ceux dont le nom contient `vps` en premier.
   Chaque candidat est testé sans rien écrire :
   `ssh -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -i <clé> -p <port> <user>@<host> "echo BOKADOR_LINK_OK"`
   avec la vérification de clé d'hôte de l'étape 3. La première qui répond est retenue.
   Aucune ne fonctionne → génère `%USERPROFILE%\.ssh\bokador-link_ed25519` (sans phrase de
   passe, seulement s'il n'existe pas), affiche la clé **publique** et la ligne à ajouter
   au `authorized_keys` du VPS, sortie 2.
3. Clé d'hôte. Si `ssh-keygen -F <hôte>` la trouve dans le `known_hosts` de l'utilisateur :
   `StrictHostKeyChecking=yes` partout. Sinon, premier contact en
   `StrictHostKeyChecking=accept-new` avec `UserKnownHostsFile=<BLRoot>\known_hosts`, et
   l'empreinte enregistrée est affichée pour vérification. Une clé d'hôte **modifiée**
   arrête toujours l'installation.
4. Crée `$BLRoot`, copie les scripts dans `bin\`, écrit `config.json` et `ssh_config`.
   `vps\bokador-link` est copié octet pour octet (LF conservés).
5. Sauf `-SkipVps` et si `VpsUser` est `root` : envoie `vps/bokador-link` par stdin
   (`Invoke-BLSsh -StdinBytes`, CRLF convertis en LF par sécurité) avec la commande distante
   `umask 022; cat > <VpsHelper>.new && chmod 755 <VpsHelper>.new && mv -f <VpsHelper>.new <VpsHelper> && <VpsHelper> install`
   et attend `BOKADOR_LINK_INSTALLED`. Échec ou utilisateur non root → avertissement,
   `VpsSideInstalled = false` (le chien de garde se rabat sur la sonde simple).
6. Tâches planifiées (module `ScheduledTasks`) :
   - mode **S4U** tenté d'abord (sauf `-InteractiveOnly`) : principal
     `-UserId <DOMAINE\utilisateur> -LogonType S4U -RunLevel Limited`, déclencheurs
     `AtStartup` + `AtLogOn` pour la tâche tunnel ; action directe
     `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<bin>\<script>.ps1"`.
     Aucune fenêtre, fonctionne sans session ouverte.
   - en cas de refus (droits insuffisants) : mode **Interactive**, déclencheur `AtLogOn` de
     l'utilisateur courant, action `wscript.exe "<bin>\launch-hidden.vbs" "<bin>\<script>.ps1"`
     (pas de fenêtre qui clignote).
   - Réglages communs : `-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
     -MultipleInstances IgnoreNew`, pas de réveil de la machine. Tunnel :
     `-ExecutionTimeLimit` nul (illimité), `-RestartCount 999 -RestartInterval 1 min`.
     Chien de garde : `-ExecutionTimeLimit 5 min`, déclencheur `-Once` répété toutes les
     `WatchdogMinutes` minutes sans durée limite, plus `AtLogOn` (et `AtStartup` en S4U).
   - Exporte chaque tâche vers `tasks\<Nom>.xml` (`Export-ScheduledTask`).
7. Supprime `run\stop.flag`, démarre la tâche tunnel, attend jusqu'à 45 s l'apparition de
   `run\tunnel.pid`, lance un tour de chien de garde, affiche l'état
   (`Get-BokadorLinkStatus.ps1`), sortie 0 si sain, 1 sinon.

Relancer l'installateur est sûr : il arrête proprement l'existant (`stop.flag`, arrêt des
tâches), remplace les fichiers et ré-enregistre les tâches.

### 4.7 Désinstallation et état

`Uninstall-BokadorLink.ps1 [-KeepVps] [-KeepLogs]` : crée `stop.flag`, arrête et supprime
les deux tâches, tue le tunnel suivi, exécute `<VpsHelper> uninstall` sur le VPS (sauf
`-KeepVps` ou côté VPS non installé), supprime `$BLRoot` (sauf `logs\` avec `-KeepLogs`).
Ne touche ni aux clés ni au `known_hosts` de l'utilisateur.

`Get-BokadorLinkStatus.ps1 [-Json]` : affiche configuration (sans le contenu de la clé),
état des tâches, processus suivis, contenu de `state.json`, 10 dernières lignes du journal
du chien de garde. Code de sortie 0 si `Healthy`, 1 sinon.

## 5. Côté VPS : `vps/bokador-link`

Un seul fichier bash, installé en `/usr/local/sbin/bokador-link`, exécuté par root.

Variables d'environnement réservées aux tests : `BL_ROOT` (préfixe de tous les chemins
ci-dessous, vide par défaut), `BL_NO_SYSTEMD=1` (écrit les unités mais n'appelle jamais
`systemctl`), `BL_FORCE_CRON=1` (force le repli cron), `BL_NOW` (époque simulée).

Choix du planificateur par `install` : `BL_FORCE_CRON=1` → cron ; sinon `BL_NO_SYSTEMD=1` →
unités écrites sans `systemctl` ; sinon systemd présent (`/run/systemd/system` et
`systemctl`) → unités + `systemctl daemon-reload` + `enable --now` du minuteur ; sinon cron.
Le repli cron exige le répertoire `/etc/cron.d` (présent dès que cron est installé) : sans
lui, `install` échoue (code 1) avant d'écrire quoi que ce soit.

Le script s'installe là où le client l'a déposé (`VpsHelper`, par défaut
`/usr/local/sbin/bokador-link`) : `install` résout son propre chemin absolu
(`readlink -f "$0"`) et c'est ce chemin qu'il écrit dans l'unité systemd ou la ligne cron.
Ce chemin n'est pas préfixé par `BL_ROOT`.

Chemins (tous préfixés par `BL_ROOT`) :

```
/var/lib/bokador-link/heartbeat   époque du dernier battement (une ligne)
/var/lib/bokador-link/status      "<up|down> <époque du changement>"
/var/lib/bokador-link/client      dernière étiquette client reçue
/etc/bokador-link/config          KEY=VALUE ; seule clé : STALE_AFTER (secondes, défaut 600, 60..86400)
/etc/bokador-link/notify          crochet facultatif, exécuté sur transition : notify <up|down> <âge>
/etc/systemd/system/bokador-link-check.service   (oneshot : bokador-link check)
/etc/systemd/system/bokador-link-check.timer     (OnBootSec=2min, OnUnitActiveSec=5min)
/etc/cron.d/bokador-link          repli sans systemd : */5 * * * * root <chemin> check
```

Sous-commandes (sortie standard = contrat lu par le client ; diagnostics sur stderr) :

| Commande | Effet | Sortie / code |
|---|---|---|
| `version` | — | `bokador-link <version>` / 0 |
| `install` | crée les répertoires, écrit et active le minuteur systemd (ou cron), idempotent ; sans systemd ni `/etc/cron.d`, rien n'est écrit | dernière ligne `BOKADOR_LINK_INSTALLED <version>` / 0 ; sans systemd ni `/etc/cron.d` : 1, sans cette ligne |
| `uninstall [--purge]` | désactive et supprime minuteur/cron, supprime `/var/lib/bokador-link`, (`--purge` : aussi `/etc/bokador-link`), se supprime en dernier | `BOKADOR_LINK_UNINSTALLED` / 0 |
| `heartbeat [étiquette]` | écrit `heartbeat` (atomique), `client` si l'étiquette respecte `^[A-Za-z0-9._-]{1,64}$`, puis exécute la logique de `check` | `BOKADOR_LINK_OK <époque> <up\|down\|unknown>` / 0 |
| `probe-port <port>` | port numérique 1..65535, connexion TCP à `127.0.0.1:<port>`, délai 5 s | `PORT <port> OPEN` / 0 ou `PORT <port> CLOSED` / 1 ; argument invalide : 2 |
| `status` | — | `status=<up\|down\|unknown> heartbeat_age=<s\|none> since=<époque\|none> stale_after=<s> version=<v>` / 0 |
| `check` | âge ≤ `STALE_AFTER` → `up`, sinon `down` ; jamais de battement → `unknown` (pas de fichier `status`, pas de notification). Sur transition : `logger -t bokador-link` si disponible, puis crochet `notify` (délai 30 s, échec ignoré mais journalisé) | rien / 0 |

Toute commande inconnue : usage sur stderr, code 2. Le script refuse de s'exécuter si
`BL_ROOT` est vide et que l'utilisateur n'est pas root (code 3), sauf pour `version`.
L'ordre des contrôles est donc : commande connue (code 2), puis root (code 3) ; une
commande inconnue est une erreur d'usage quel que soit l'utilisateur.

Ainsi chaque extrémité vérifie l'autre : le PC lit `up|down|unknown` dans la réponse au
battement (champ `VpsView`), et le VPS détecte seul un PC silencieux via son minuteur.

## 6. Tests exécutables sous Linux

- `shellcheck` sur `vps/bokador-link` et `tests/*.sh`.
- `tests/test-vps-unit.sh` : chaque sous-commande avec `BL_ROOT` temporaire, `BL_NO_SYSTEMD=1`
  et `BL_NOW` (formats de sortie exacts, transitions `unknown → up → down → up`, crochet
  `notify`, étiquettes et ports invalides, idempotence d'`install`, `uninstall`).
- `tests/test-integration.sh` : démarre un `sshd` jetable sur `127.0.0.1` (port libre, clés
  temporaires, `SetEnv BL_ROOT=… BL_NO_SYSTEMD=1 PATH=…`), puis rejoue **exactement** les
  commandes distantes du client Windows : envoi par stdin + `install`, `heartbeat`, `status`,
  `probe-port` fermé, ouverture d'un tunnel inverse `ssh -N -R` puis `probe-port` ouvert,
  mort du tunnel puis port refermé, battement périmé puis `down` et crochet appelé. Son
  `ssh_config` client est recopié à la main de §4.3 ; le test vérifie que ses mots-clés sont
  ceux de §4.3, dans le même ordre.
- `tests/ps-static-check.py` : fichiers `.ps1` en ASCII pur ; pas de jeton réservé à
  PowerShell 7, dont `ConvertFrom-Json -Depth` ; analyse syntaxique avec la grammaire
  tree-sitter (heuristique : ce n'est pas l'analyseur de PowerShell). Cette grammaire est
  **obligatoire** : sans elle, l'étape échoue (`pip install tree-sitter tree-sitter-powershell`) ;
  chaque fonction `*-BL*` appelée, verbes composés compris (`ConvertTo-BL*`), est définie dans
  la bibliothèque commune ou dans le fichier appelant ; chaque nom de fichier qui porte une
  extension du kit (`.ps1`, `.vbs`, `.json`, `.log`, `.xml`, `.pid`, `.flag`) figure au §4 ; les
  mots-clés du `ssh_config` produit par `New-BLSshConfigText` sont ceux du §4.3, dans le même ordre.

Limite connue : les scripts PowerShell ne sont **pas exécutés** par ces tests (pas de
PowerShell ni de Planificateur de tâches sous Linux ici). L'étape 0 de l'installateur
refait une vraie analyse syntaxique sur la machine cible avant toute modification. La
classification des échecs ssh (`Get-BLClassifiedSshFailure`, §4.4) n'est pas exécutée non
plus : les tests vérifient seulement le code de sortie 255 et le texte de stderr produit par ssh.

Limites connues, décisions en attente (le code se comporte comme décrit) :

- Le crochet `notify` s'exécute pendant `heartbeat`, après la ligne `BOKADOR_LINK_OK` : la
  session ssh du client ne se termine qu'à la fin du crochet (au plus 30 s, plus la marge
  d'arrêt). Le détacher demande de décider où son journal est écrit, car la session peut
  disparaître avec elle.
- Un `ssh.exe` bloqué sans quitter n'est pas détecté : `probe-port` vérifie seulement que le
  VPS accepte la connexion TCP, et le chien de garde ne fait pas circuler de données dans le
  tunnel (§4.5).
- Un saut d'horloge du VPS peut produire une paire `down` / `up` parasite, ou laisser `up`
  pendant un retour en arrière (un âge négatif est ramené à 0).
- Les variables réservées aux tests (`BL_ROOT`, `BL_NOW`, `BL_NO_SYSTEMD`, `BL_FORCE_CRON`) sont
  lues hors des tests. Un client distant ne peut pas les définir par défaut (`AcceptEnv` de
  sshd), mais un shell d'administration qui les exporte les applique.

## 7. Périmètre des modifications

| Machine | Ce que le kit crée ou modifie | Ce qu'il ne touche jamais |
|---|---|---|
| PC | `%LOCALAPPDATA%\BokadorLink\`, deux tâches planifiées `BokadorLink-*`, éventuellement une **nouvelle** clé `~\.ssh\bokador-link_ed25519` si aucune clé existante ne fonctionne | clés existantes, `~\.ssh\config`, `~\.ssh\known_hosts`, pare-feu, services, tâches existantes |
| VPS | `/usr/local/sbin/bokador-link`, `/var/lib/bokador-link/`, `/etc/bokador-link/`, unités `bokador-link-check.*` (ou `/etc/cron.d/bokador-link`) | `sshd_config`, `authorized_keys`, pare-feu, Docker, autres services |
