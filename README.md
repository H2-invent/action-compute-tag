# action-compute-tag

Composite Action, die den Container-Image-Tag für ein PR-Event oder
einen manuellen Trigger berechnet - je nachdem, ob es sich um einen
Preview-Build (PR offen/aktualisiert) oder einen finalen Release
(PR gemerged) handelt, und ob das Ziel `master`/`main` oder ein
`release/X.Y` Branch ist.

## Regeln

| Situation | Ergebnis |
|---|---|
| PR gegen `master`/`main` offen/aktualisiert | `<letzter_master_tag>+<run_id>` |
| PR gegen `master`/`main`, Source-Branch ist `release/X.Y` | schon `X.Y.0+<run_id>` (nicht der alte master-Tag) |
| PR gegen `release/X.Y` offen/aktualisiert **oder** dorthin gemerged | immer `X.Y.0+<run_id>` - wird nie hochgezählt |
| `hotfix/*`/`bugfix/*` nach `master`/`main` gemerged | Patch-Bump, z.B. `1.5.6` → `1.5.7` |
| `release/X.Y` selbst nach `master`/`main` gemerged | finaler Tag `X.Y.0` (ohne Suffix) - ab hier zählt `master` von `X.Y.x` weiter |
| PR geschlossen ohne Merge | kein Tag (`skip=true`) |
| `workflow_dispatch` | wird immer wie ein offener/aktualisierter PR behandelt (Preview, nie final) |

Die Versionsbasis wird **immer aus dem Ziel-/Source-Branch-Namen**
abgeleitet, nie aus der Commit-Historie - ein von `master` abgezweigter
Branch übernimmt dadurch nicht versehentlich die master-Version, wenn
er gegen einen `release/X.Y` Branch geöffnet wird.

## Verwendung

```yaml
- name: Checkout PR head
  uses: actions/checkout@v4
  with:
    ref: ${{ github.event.pull_request.head.sha }}
    fetch-depth: 0
    fetch-tags: true

- name: Compute tag
  id: tag
  uses: <ORG>/action-compute-tag@v1
  with:
    event-name: pull_request
    base-ref: ${{ github.event.pull_request.base.ref }}
    head-ref: ${{ github.event.pull_request.head.ref }}
    pr-action: ${{ github.event.action }}
    pr-merged: ${{ github.event.pull_request.merged }}

- name: Use the tag
  if: steps.tag.outputs.skip != 'true'
  run: echo "Tag ist ${{ steps.tag.outputs.tag }}"
```

`fetch-depth: 0` und `fetch-tags: true` beim Checkout sind Pflicht,
sonst kann das Skript keine bestehenden Tags/Branches sehen.

## Inputs

| Input | Pflicht | Default | Beschreibung |
|---|---|---|---|
| `event-name` | ja | - | `pull_request` oder `workflow_dispatch` |
| `base-ref` | ja | - | Ziel-Branch des PRs (`github.event.pull_request.base.ref`) bzw. der manuell gewählte Branch bei `workflow_dispatch` |
| `head-ref` | nein | `""` | Source-Branch des PRs (`github.event.pull_request.head.ref`); nur bei `pull_request` relevant |
| `pr-action` | nein | `""` | `github.event.action` (`opened`\|`synchronize`\|`reopened`\|`edited`\|`closed`); bei `workflow_dispatch` leer lassen |
| `pr-merged` | nein | `"false"` | `github.event.pull_request.merged` als String; nur relevant, wenn `pr-action` = `closed` |

## Outputs

| Output | Beschreibung |
|---|---|
| `tag` | Der berechnete Tag, z.B. `1.6.0+4821` oder `1.5.7`. Leer, wenn `skip` = `"true"`. |
| `skip` | `"true"`, wenn kein Tag erzeugt werden soll (PR geschlossen ohne Merge) - in dem Fall nachfolgende Build-Steps überspringen. |

## Branch-Namensschema

Erwartet wird:

- `master` oder `main` als Hauptbranch
- `release/X.Y` für Release-Branches (z.B. `release/1.6`) - genau ein
  Punkt, keine dritte Versionsstelle im Branch-Namen
- beliebige andere Branch-Namen (`hotfix/*`, `bugfix/*`, `feature/*`, ...)
  als Source-Branches

Passt euer Schema davon ab (z.B. drei Versionsstellen im Branch-Namen),
muss `compute-container-tag.sh` in diesem Repo angepasst werden
(`RELEASE_BRANCH_REGEX`).

## Versionierung

Diese Action wird per Tag referenziert (`@v1`). Bei Änderungen an der
Logik einen neuen Tag setzen und die aufrufenden Workflows bewusst
aktualisieren, statt `@main` zu referenzieren - sonst ändert sich das
Verhalten in allen Repos gleichzeitig ohne Vorwarnung.