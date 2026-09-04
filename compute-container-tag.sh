#!/usr/bin/env bash
#
# compute-container-tag.sh
#
# Regeln:
#   1) PR gegen master/main (z.B. von hotfix/*):
#        Preview-Tag = <letzter_tag_auf_master>+<run_id>
#
#   2) PR gegen release/X.Y offen/aktualisiert ODER dorthin gemerged
#      (egal woher, auch von master abgezweigt):
#        Tag = X.Y.0+<run_id>
#        IMMER X.Y.0 - wird NIE hochgezählt, egal wie oft in den
#        Release-Branch gemerged wird. Merge und Preview sehen für
#        Release-Branches identisch aus, nur die run_id unterscheidet
#        sich je Lauf.
#
#   3) PR nach master gemerged (merged=true, base=master):
#        a) Source-Branch ist release/X.Y
#             -> finaler Tag = X.Y.0 (ohne Suffix) - das ist der
#                "offizielle" Release. Ab jetzt zählt master von hier
#                weiter (nächster Hotfix wird X.Y.1 usw.)
#        b) Source-Branch ist alles andere (hotfix/bugfix/...)
#             -> finaler Tag = bump_patch(letzter_tag_auf_master)
#
#   4) PR geschlossen ohne Merge (egal welches Ziel):
#        -> KEIN Tag.
#
#   5) Manueller Trigger (workflow_dispatch):
#        Wird IMMER wie Fall 1/2 (Preview) behandelt, nie final -
#        unabhängig davon, welcher Branch gewählt wurde. BASE_REF ist
#        dabei der manuell gewählte Branch (z.B. per Workflow-Input).
#
# Erwartete Umgebungsvariablen:
#   GITHUB_EVENT_NAME   "pull_request" oder "workflow_dispatch"
#   GITHUB_RUN_ID       Actions Run-ID (für den Preview-Suffix)
#   PR_ACTION           bei pull_request: github.event.action
#                        (opened|synchronize|reopened|edited|closed|...)
#                        bei workflow_dispatch: wird ignoriert/nicht
#                        benötigt, intern immer als Preview behandelt.
#   PR_MERGED           nur bei pull_request+closed relevant:
#                        github.event.pull_request.merged ("true"/"false")
#   BASE_REF            bei pull_request: github.event.pull_request.base.ref
#                        bei workflow_dispatch: der manuell gewählte
#                        Branch (z.B. github.event.inputs.branch oder
#                        github.ref_name)
#   HEAD_REF            nur bei pull_request+closed(merged) relevant:
#                        github.event.pull_request.head.ref
#
# Voraussetzung im Workflow: actions/checkout mit fetch-depth: 0 UND
# fetch-tags: true, sonst sind Tags lokal nicht sichtbar.
#
# Ausgabe (nach $GITHUB_OUTPUT):
#   tag=<TAG>     nur gesetzt, wenn ein Tag berechnet wurde
#   skip=true|false   "true" wenn kein Tag erzeugt werden soll (Fall 4/5)

set -euo pipefail

MAIN_BRANCH_REGEX='^(main|master)$'
RELEASE_BRANCH_REGEX='^release/([0-9]+)\.([0-9]+)$'
SEMVER_TAG_REGEX='^[0-9]+\.[0-9]+\.[0-9]+$'

: "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME muss gesetzt sein}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID muss gesetzt sein}"
: "${BASE_REF:?BASE_REF muss gesetzt sein}"

case "${GITHUB_EVENT_NAME}" in
  pull_request)
    : "${PR_ACTION:?PR_ACTION muss gesetzt sein}"
    ;;
  workflow_dispatch)
    # Manueller Trigger verhält sich immer wie ein offener/aktualisierter
    # PR (Preview) - nie "closed", also einfach fest auf "manual" setzen,
    # damit die weiter unten stehende "PR_ACTION != closed"-Weiche greift.
    PR_ACTION="manual"
    ;;
  *)
    echo "::error::Nur GITHUB_EVENT_NAME=pull_request oder workflow_dispatch wird unterstützt." >&2
    exit 1
    ;;
esac

git fetch --tags --force --quiet || true

# Liefert den höchsten reinen Semver-Tag (X.Y.Z, kein "+..."), der auf
# $1 (Branch/Ref) erreichbar ist.
latest_semver_tag_on() {
  local ref="$1"
  local resolved_ref="$ref"

  if ! git rev-parse --verify --quiet "$ref" >/dev/null; then
    resolved_ref="origin/${ref}"
  fi

  git tag --merged "$resolved_ref" 2>/dev/null \
    | grep -E "$SEMVER_TAG_REGEX" \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -n1 || true
}

bump_patch() {
  local v="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<< "$v"
  echo "${major}.${minor}.$((patch + 1))"
}

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

write_output() {
  local tag="$1"
  local skip="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "tag=${tag}"
      echo "skip=${skip}"
    } >> "${GITHUB_OUTPUT}"
  fi
}

# Schreibt Tag, Ziel-/Source-Branch und Begründung in den Step Summary
# und in $GITHUB_OUTPUT, und beendet das Skript.
write_result() {
  local tag="$1"
  local skip="$2"
  local reason="$3"

  write_output "$tag" "$skip"

  {
    echo "## Container-Tag"
    echo ""
    echo "| Feld | Wert |"
    echo "|---|---|"
    if [ "$skip" = "true" ]; then
      echo "| Tag | _kein Tag erzeugt_ |"
    else
      echo "| Tag | \`${tag}\` |"
    fi
    echo "| Ziel-Branch | \`${BASE_REF}\` |"
    echo "| Source-Branch | $( [ -n "${HEAD_REF:-}" ] && echo "\`${HEAD_REF}\`" || echo "—" ) |"
    echo "| Event | \`${GITHUB_EVENT_NAME}\` / \`${PR_ACTION}\` |"
    echo "| Begründung | ${reason} |"
  } >> "$SUMMARY"

  if [ "$skip" != "true" ]; then
    echo "$tag"
  fi
  exit 0
}

# --- Fall: PR geschlossen ohne Merge -> nie ein Tag, egal welches Ziel ---
if [ "${PR_ACTION}" = "closed" ]; then
  : "${PR_MERGED:?Bei PR_ACTION=closed muss PR_MERGED gesetzt sein}"
  if [ "${PR_MERGED}" != "true" ]; then
    echo "PR wurde geschlossen, aber nicht gemerged - kein Tag." >&2
    write_result "" "true" "PR wurde geschlossen, aber nicht gemerged."
  fi
fi

# Ab hier: entweder PR offen/aktualisiert, oder PR gemerged.

if [[ "$BASE_REF" =~ $RELEASE_BRANCH_REGEX ]]; then
  # Fall 2: sowohl Preview (offen/aktualisiert) als auch Merge in
  # release/X.Y erzeugen denselben Tag X.Y.0+<run_id>. Bewusst
  # unabhängig von jeglicher Tag-Historie, damit ein von master
  # abgezweigter Branch (z.B. mit Tag 1.5.6) nicht fälschlich die
  # master-Version übernimmt und damit dieser Tag nie hochgezählt wird.
  MAJOR="${BASH_REMATCH[1]}"
  MINOR="${BASH_REMATCH[2]}"
  TAG="${MAJOR}.${MINOR}.0-${GITHUB_RUN_ID}"
  echo "Tag für release-Branch '${BASE_REF}': ${TAG}" >&2
  write_result "$TAG" "false" "Ziel-Branch ist ein release-Branch - Version kommt fest aus dem Branch-Namen (\`${MAJOR}.${MINOR}.0\`), unabhängig von der Tag-Historie; wird nie hochgezählt."
fi

if [[ ! "$BASE_REF" =~ $MAIN_BRANCH_REGEX ]]; then
  echo "::error::Ziel-Branch '${BASE_REF}' passt weder auf main/master noch auf release/X.Y." >&2
  exit 1
fi

# Ziel ist master/main:
if [ "${PR_ACTION}" != "closed" ]; then
  # Fall 1: Preview-Tag für einen offenen/aktualisierten PR gegen master.
  #
  # Sonderfall: kommt der PR von einem release/X.Y Branch (z.B. wird
  # release/1.5 gegen master geöffnet), soll die Preview schon die
  # neue Version zeigen (1.5.0+<run_id>) statt des alten master-Tags
  # - schließlich wird daraus beim Merge ohnehin 1.5.0.
  if [ -n "${HEAD_REF:-}" ] && [[ "$HEAD_REF" =~ $RELEASE_BRANCH_REGEX ]]; then
    MAJOR="${BASH_REMATCH[1]}"
    MINOR="${BASH_REMATCH[2]}"
    TAG="${MAJOR}.${MINOR}.0-${GITHUB_RUN_ID}"
    echo "PR von release-Branch '${HEAD_REF}' gegen '${BASE_REF}' -> Preview: ${TAG}" >&2
    write_result "$TAG" "false" "Source-Branch ist ein release-Branch - Preview zeigt schon dessen Version (\`${MAJOR}.${MINOR}.0\`) statt des alten master-Tags."
  else
    BASE_TAG="$(latest_semver_tag_on "$BASE_REF")"
    if [ -z "$BASE_TAG" ]; then
      echo "::error::Kein Semver-Tag (X.Y.Z) auf '${BASE_REF}' gefunden. Initialen Tag setzen, z.B. 0.1.0." >&2
      exit 1
    fi
    TAG="${BASE_TAG}-${GITHUB_RUN_ID}"
    echo "Preview-Tag: ${TAG}" >&2
    write_result "$TAG" "false" "Preview-Tag: letzter Tag auf \`${BASE_REF}\` (\`${BASE_TAG}\`) + Run-ID."
  fi
fi

# Fall 3: Merge nach master/main.
: "${HEAD_REF:?Bei einem Merge muss HEAD_REF gesetzt sein}"

if [[ "$HEAD_REF" =~ $RELEASE_BRANCH_REGEX ]]; then
  # Fall 3a: Release-Branch wird final in master gemerged.
  MAJOR="${BASH_REMATCH[1]}"
  MINOR="${BASH_REMATCH[2]}"
  TAG="${MAJOR}.${MINOR}.0"
  echo "Release-Branch '${HEAD_REF}' wurde nach '${BASE_REF}' gemerged -> finaler Tag ${TAG}" >&2
  write_result "$TAG" "false" "Release-Branch \`${HEAD_REF}\` wurde final nach \`${BASE_REF}\` gemerged - finaler Tag ohne Suffix. \`${BASE_REF}\` zählt ab jetzt von \`${MAJOR}.${MINOR}.x\` weiter."
else
  # Fall 3b: hotfix/bugfix/... direkt in master gemerged.
  BASE_TAG="$(latest_semver_tag_on "$BASE_REF")"
  if [ -z "$BASE_TAG" ]; then
    echo "::error::Kein Semver-Tag (X.Y.Z) auf '${BASE_REF}' gefunden. Initialen Tag setzen, z.B. 0.1.0." >&2
    exit 1
  fi
  TAG="$(bump_patch "$BASE_TAG")"
  echo "'${HEAD_REF}' wurde nach '${BASE_REF}' gemerged -> Patch-Bump auf ${TAG}" >&2
  write_result "$TAG" "false" "\`${HEAD_REF}\` wurde nach \`${BASE_REF}\` gemerged - Patch-Bump von \`${BASE_TAG}\` auf \`${TAG}\`."
fi
