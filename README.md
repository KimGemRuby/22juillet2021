# 22juillet2021

## bokador-link

Kit qui établit et maintient une liaison SSH **permanente, persistante et auto-réparatrice**
entre un PC Windows (le client, « bokador ») et un VPS Linux.

- Le PC ouvre la connexion vers le VPS et la garde ouverte. Aucun port n'est ouvert sur le PC.
- Si la liaison tombe (coupure réseau, redémarrage du VPS ou du PC, mise en veille,
  `ssh.exe` planté), elle se rétablit seule.
- Deux boucles se surveillent mutuellement : un **superviseur** (processus long qui relance
  le tunnel) et un **chien de garde** (tâche planifiée qui mesure, répare et re-mesure).
  Chacun recrée la tâche de l'autre si elle disparaît.
- Les deux extrémités se vérifient : le PC dépose un battement de cœur sur le VPS à chaque
  tour, et le VPS détecte de son côté un PC devenu silencieux.

La conception détaillée est dans [`docs/DESIGN.md`](docs/DESIGN.md).

> **État** : conception et outillage de test en place. Les scripts décrits ci-dessous sont
> en cours d'implémentation sur cette branche ; n'exécutez rien avant leur arrivée.

### Prérequis

| Machine | Prérequis |
|---|---|
| PC | Windows 10 ou 11, Windows PowerShell 5.1 (livré avec Windows), client OpenSSH (`ssh.exe`, livré avec Windows) |
| VPS | Linux avec `bash` et `sshd` ; systemd ou cron |
| Accès | une clé SSH du PC déjà autorisée sur le VPS (sinon l'installateur en crée une et affiche la ligne à autoriser) |

### Installation

Sur le PC Windows, dans PowerShell, depuis une copie de ce dépôt :

```powershell
cd windows
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-BokadorLink.ps1 -VpsHost <IP_DU_VPS>
```

L'installateur :

1. vérifie la syntaxe de tous les scripts avant de modifier quoi que ce soit ;
2. cherche dans `%USERPROFILE%\.ssh` une clé qui ouvre déjà le VPS (aucune clé n'est copiée ni affichée) ;
3. vérifie la clé d'hôte du VPS ;
4. installe le kit dans `%LOCALAPPDATA%\BokadorLink` ;
5. dépose l'assistant `bokador-link` sur le VPS et active son minuteur ;
6. crée deux tâches planifiées, `BokadorLink-Tunnel` et `BokadorLink-Watchdog` ;
7. démarre la liaison, fait un premier tour de contrôle et affiche l'état.

Lancé dans un PowerShell **administrateur**, il enregistre les tâches en mode S4U : la
liaison démarre au démarrage de Windows, sans session ouverte. Sinon, elle démarre à
l'ouverture de session.

Options utiles :

| Option | Effet |
|---|---|
| `-VpsUser root` `-VpsPort 22` | utilisateur et port SSH du VPS |
| `-IdentityFile C:\chemin\cle` | impose la clé à utiliser |
| `-Forward "R 127.0.0.1:33389 127.0.0.1:3389"` | redirection de port à maintenir (répétable ; boucle locale uniquement). `R` : un port du VPS mène au PC. `L` : un port du PC mène au VPS |
| `-WatchdogMinutes 3` | période du chien de garde |
| `-SkipVps` | n'installe rien sur le VPS |
| `-DryRun` | décrit ce qui serait fait, sans rien modifier |

Codes de sortie : `0` liaison saine, `1` échec, `2` une clé doit être autorisée sur le VPS
(la ligne à ajouter est affichée), `3` client OpenSSH absent.

Relancer l'installateur est sans danger : il remplace proprement l'installation existante.

### Vérifier l'état

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\BokadorLink\bin\Get-BokadorLinkStatus.ps1"
```

Sur le VPS :

```bash
bokador-link status
```

Les journaux du PC sont dans `%LOCALAPPDATA%\BokadorLink\logs`.

Pour être prévenu quand le PC ne répond plus, créez sur le VPS un exécutable
`/etc/bokador-link/notify` : il est appelé avec `up` ou `down` et l'âge du dernier
battement, à chaque changement d'état.

### Désinstallation

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\BokadorLink\bin\Uninstall-BokadorLink.ps1"
```

Les deux tâches, le dossier d'installation et l'assistant côté VPS sont supprimés. Vos clés
SSH, votre `~\.ssh\config` et votre `known_hosts` ne sont jamais touchés.

### Ce que le kit ne fait pas

- Il ne modifie ni `sshd_config`, ni le pare-feu, ni `authorized_keys` du VPS.
- Il n'installe aucun service entrant sur le PC.
- Il n'accepte jamais automatiquement une clé d'hôte qui a changé : la liaison reste alors
  arrêtée et l'état indique qu'une intervention humaine est nécessaire.

### Tests

```bash
bash tests/run-tests.sh
```

Les tests s'exécutent sous Linux : `shellcheck`, tests unitaires de l'assistant VPS, test de
bout en bout contre un `sshd` local jetable, et contrôles statiques des scripts PowerShell.
Les scripts PowerShell eux-mêmes ne sont pas exécutés par ces tests ; l'installateur refait
une analyse syntaxique réelle sur le PC avant toute modification.
