# action-compute-tag

Composite Action, die den Container-Image-Tag für ein PR-Event oder
einen manuellen Trigger berechnet - je nachdem, ob es sich um einen
Preview-Build (PR offen/aktualisiert) oder einen finalen Release
(PR gemerged) handelt, und ob das Ziel `master`/`main`, ein
`release/X.Y` oder ein `lts/X.Y` Branch ist.

## Branch-Modell

| Branch | Zweck |
|---|---|
| `master`/`main` | aktuell veröffentlichte Version |
| `release/X.Y` | Entwicklung der nächsten Version, wird beim Release nach `main` gemerged |
| `lts/X.Y` | Wartung einer abgelösten Version (z.B. CVE-Fixes), bleibt dauerhaft bestehen |

Vor dem Merge von `release/X.Y` nach `main` wird die bisherige Version
als `lts/`-Branch vom letzten Tag dieser Version angelegt:

```bash
git branch lts/1.5 1.5.7
git push origin lts/1.5
```

## Regeln

| Situation | Ergebnis |
|---|---|
| PR gegen `master`/`main` offen/aktualisiert | `<letzter_master_tag>-<run_id>` |
| PR gegen `master`/`main`, Source-Branch ist `release/X.Y` | schon `X.Y.0-<run_id>` (nicht der alte master-Tag) |
| `hotfix/*`/`bugfix/*` nach `master`/`main` gemerged | Patch-Bump, z.B. `1.5.6` → `1.5.7` |
| `release/X.Y` selbst nach `master`/`main` gemerged | finaler Tag `X.Y.0` (ohne Suffix) - ab hier zählt `master` von `X.Y.x` weiter |
| PR gegen `release/X.Y` offen/aktualisiert **oder** dorthin gemerged | immer `X.Y.0-<run_id>` - wird nie hochgezählt |
| PR gegen `lts/X.Y` offen/aktualisiert | `<letzter_X.Y_tag>-<run_id>` |
| PR nach `lts/X.Y` gemerged | Patch-Bump innerhalb `X.Y`, z.B. `1.5.7` → `1.5.8` |
| PR von `release/*` gegen `lts/*` | Fehler - Fixes per Cherry-Pick übernehmen |
| `lts/X.Y` ohne Tag `X.Y.Z` | Fehler - Branch vom letzten `X.Y`-Tag anlegen |
| PR geschlossen ohne Merge | kein Tag (`skip=true`) |
| PR ist Draft | kein Tag (`skip=true`), ab "Ready for review" normale Regeln |
| `upmerge/**` als Ziel- oder Source-Branch | kein Tag (`skip=true`) |
| Event steht in `SKIP_EVENTS` (Default: `push`) | kein Tag (`skip=true`) |
| `workflow_dispatch` | wird immer wie ein offener/aktualisierter PR behandelt (Preview, nie final) |

Die Versionsbasis für `release/X.Y` und `lts/X.Y` wird **aus dem
Branch-Namen** abgeleitet, nie aus der Commit-Historie - ein von
`master` abgezweigter Branch übernimmt dadurch nicht versehentlich die
master-Version.

Für `master`/`main` und `lts/X.Y` werden nur Tags berücksichtigt, die
auf dem jeweiligen Branch erreichbar sind (`git tag --merged`). Ein
Patch-Tag auf `lts/1.5` beeinflusst daher nicht den nächsten Tag auf
`main` und umgekehrt.

## Fixes über mehrere Versionen

1. Fix nach `main` (aktuelle Version) → Patch-Tag
2. Fix per `git cherry-pick -x` in jeden betroffenen `lts/X.Y` → Patch-Tag je Version
3. Fix in den laufenden `release/X.Y` übernehmen

## Verwendung

```yaml
concurrency:
  group: compute-tag-${{ github.event.pull_request.base.ref }}
  cancel-in-progress: false

steps:
  - name: Checkout PR head
    uses: actions/checkout@v4
    with:
      ref: ${{ github.event.pull_request.head.sha }}
      fetch-depth: 0
      fetch-tags: true

  - name: Compute tag
    id: tag
    uses: <ORG>/action-compute-tag@v2
    with:
      event-name: pull_request
      base-ref: ${{ github.event.pull_request.base.ref }}
      head-ref: ${{ github.event.pull_request.head.ref }}
      pr-action: ${{ github.event.action }}
      pr-merged: ${{ github.event.pull_request.merged }}

  - name: Use the tag
    if: steps.tag.outputs.skip != 'true'
    run: echo "Tag ist ${{ steps.tag.outputs.version }}"
```

`fetch-depth: 0` und `fetch-tags: true` beim Checkout sind Pflicht,
sonst kann das Skript keine bestehenden Tags/Branches sehen.

Die `concurrency`-Gruppe pro Ziel-Branch verhindert, dass zwei
gleichzeitige Merges in denselben Branch denselben Patch-Tag berechnen.

## Inputs

| Input | Pflicht | Default | Beschreibung |
|---|---|---|---|
| `event-name` | ja | - | `pull_request`, `workflow_dispatch` oder `push` |
| `base-ref` | ja | - | Ziel-Branch des PRs (`github.event.pull_request.base.ref`) bzw. der manuell gewählte Branch bei `workflow_dispatch` |
| `head-ref` | nein | `""` | Source-Branch des PRs (`github.event.pull_request.head.ref`); bei allen PR-Aktionen übergeben, sonst werden `upmerge/**` und `release/*` → `lts/*` nicht erkannt |
| `pr-action` | nein | `""` | `github.event.action` (`opened`\|`synchronize`\|`reopened`\|`edited`\|`closed`\|`ready_for_review`); bei `workflow_dispatch` leer lassen |
| `pr-merged` | nein | `"false"` | `github.event.pull_request.merged` als String; nur relevant, wenn `pr-action` = `closed` |
| `pr-draft` | nein | `""` | Override für den Draft-Status (`true`/`false`); leer = automatisch aus `github.event.pull_request.draft` |
| `skip-events` | nein | `"push"` | kommagetrennte Events, bei denen immer `skip=true` ausgegeben wird |
| `main-branches` | nein | `"main,master"` | kommagetrennte Namen der Hauptbranches |
| `release-prefix` | nein | `"release/"` | Präfix der Release-Branches vor `X.Y` |
| `lts-prefix` | nein | `"lts/"` | Präfix der Wartungsbranches vor `X.Y` |

## Outputs

| Output | Beschreibung |
|---|---|
| `version` | Der berechnete Tag, z.B. `1.6.0-4821` oder `1.5.7`. Leer, wenn `skip` = `"true"`. |
| `skip` | `"true"`, wenn kein Tag erzeugt werden soll - in dem Fall nachfolgende Build-Steps überspringen. |

## Branch-Namensschema

Erwartet wird:

- `master` oder `main` als Hauptbranch
- `release/X.Y` für Release-Branches (z.B. `release/1.6`)
- `lts/X.Y` für Wartungsbranches (z.B. `lts/1.5`)
- jeweils genau ein Punkt, keine dritte Versionsstelle im Branch-Namen
- Namen und Präfixe sind konfigurierbar (siehe unten)
- beliebige andere Branch-Namen (`hotfix/*`, `bugfix/*`, `feature/*`, ...)
  als Source-Branches

### Eigene Branch-Namen

Das Schema lässt sich über die Inputs `main-branches`,
`release-prefix` und `lts-prefix` ändern (im Skript als
`MAIN_BRANCHES`, `RELEASE_PREFIX`, `LTS_PREFIX`). Ein leerer Wert
fällt auf den Default zurück.

```yaml
- uses: <ORG>/action-compute-tag@v2
  with:
    # ... wie oben
    main-branches: trunk
    release-prefix: dev/
    lts-prefix: support/
```

Präfixe werden wörtlich verglichen (Sonderzeichen wie `.` werden
maskiert). `RELEASE_PREFIX` und `LTS_PREFIX` dürfen nicht gleich sein.

Beispiel: `MAIN_BRANCHES=trunk`, `RELEASE_PREFIX=dev/`,
`LTS_PREFIX=support/` → `trunk`, `dev/1.7`, `support/1.5`.

## Versionierung

Diese Action wird per Tag referenziert (`@v2`). Bei Änderungen an der
Logik einen neuen Tag setzen und die aufrufenden Workflows bewusst
aktualisieren, statt `@main` zu referenzieren - sonst ändert sich das
Verhalten in allen Repos gleichzeitig ohne Vorwarnung.
