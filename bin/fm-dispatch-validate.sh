#!/usr/bin/env bash
# Validate and normalize config/crew-dispatch.json or one resolved runtime tuple.
# Usage: fm-dispatch-validate.sh --file <path> [--normalized]
#        fm-dispatch-validate.sh --stdin [--normalized]
#        fm-dispatch-validate.sh --runtime <harness> <model> <effort> [--label <text>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-dispatch-runtime-lib.sh
. "$SCRIPT_DIR/fm-dispatch-runtime-lib.sh"

INPUT_MODE=
INPUT_FILE=
NORMALIZED=0
ALLOW_DISABLED_PIN=0
RUNTIME=0
RUNTIME_HARNESS=
RUNTIME_MODEL=
RUNTIME_EFFORT=
LABEL="runtime tuple"

while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || { echo "error: --file requires a value" >&2; exit 2; }
      INPUT_MODE=file
      INPUT_FILE=$2
      shift 2
      ;;
    --stdin)
      INPUT_MODE=stdin
      shift
      ;;
    --normalized)
      NORMALIZED=1
      shift
      ;;
    --allow-disabled-pin)
      ALLOW_DISABLED_PIN=1
      shift
      ;;
    --runtime)
      [ $# -ge 4 ] || { echo "error: --runtime requires harness, model, and effort" >&2; exit 2; }
      RUNTIME=1
      RUNTIME_HARNESS=$2
      RUNTIME_MODEL=$3
      RUNTIME_EFFORT=$4
      shift 4
      ;;
    --label)
      [ $# -ge 2 ] || { echo "error: --label requires a value" >&2; exit 2; }
      LABEL=$2
      shift 2
      ;;
    -h|--help)
      sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ "$RUNTIME" -eq 1 ]; then
  [ -z "$INPUT_MODE" ] || { echo "error: --runtime cannot accompany config input" >&2; exit 2; }
  fm_dispatch_runtime_validate "$LABEL" "$RUNTIME_HARNESS" "$RUNTIME_MODEL" "$RUNTIME_EFFORT"
  exit $?
fi

[ -n "$INPUT_MODE" ] || { echo "error: pass --file or --stdin" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required to validate crew dispatch" >&2; exit 1; }
case "$INPUT_MODE" in
  file)
    [ -f "$INPUT_FILE" ] || { echo "dispatch config file not found: $INPUT_FILE" >&2; exit 1; }
    CONFIG_JSON=$(cat "$INPUT_FILE")
    ;;
  stdin) CONFIG_JSON=$(cat) ;;
esac

printf '%s\n' "$CONFIG_JSON" | jq -e . >/dev/null 2>&1 || {
  echo "malformed JSON" >&2
  exit 1
}
TOP_TYPE=$(printf '%s\n' "$CONFIG_JSON" | jq -r 'type')
[ "$TOP_TYPE" = object ] || {
  echo "top-level value must be an object" >&2
  exit 1
}
RULES_TYPE=$(printf '%s\n' "$CONFIG_JSON" | jq -r 'if has("rules") then (.rules | type) else "missing" end')
[ "$RULES_TYPE" = missing ] || [ "$RULES_TYPE" = array ] || {
  echo "rules must be an array" >&2
  exit 1
}

SCHEMA_ERROR=$(printf '%s\n' "$CONFIG_JSON" | jq -r --argjson allow_disabled_pin "$ALLOW_DISABLED_PIN" '
  def profiles($value):
    if ($value | type) == "array" then $value
    elif ($value | type) == "object" then [$value]
    else []
    end;
  def malformed_optional_fields($items):
    ($items | any(has("model") and (((.model | type) != "string") or (.model | length) == 0)))
    or ($items | any(has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)));
  def malformed_enabled($items):
    ($items | any(has("enabled") and ((.enabled | type) != "boolean")));
  def whitespace_error($label; $items):
    [$items[]? as $item
      | ["harness", "model", "effort"][] as $field
      | select(($item | type) == "object")
      | select($item | has($field))
      | select(($item[$field] | type) == "string")
      | select($item[$field] | test("\\s"))
      | "\($label) \($field)=\($item[$field] | @json)"][0] // null;
  def rung_enabled($profile):
    if ($profile | has("enabled")) then $profile.enabled else true end;
  def enabled_profiles($items):
    [$items[] | select(rung_enabled(.))];
  def same_tuple($left; $right):
    {harness: $left.harness, model: ($left.model // "default"), effort: ($left.effort // "default")}
    == {harness: $right.harness, model: ($right.model // "default"), effort: ($right.effort // "default")};
  def profile_label($profile):
    "\($profile.harness)/\($profile.model // "<default>")/\($profile.effort // "<default>")";
  def rule_pins_outside_pools:
    [(.rules // [])[]?
      | select(has("pin"))
      | . as $rule
      | select([profiles($rule.use)[]? | select(same_tuple(.; $rule.pin))] | length == 0)];
  def switched_off_rule_pins:
    [(.rules // [])[]?
      | select(has("pin"))
      | . as $rule
      | select([profiles($rule.use)[]?
        | select(same_tuple(.; $rule.pin) and rung_enabled(.))] | length == 0)];
  def default_pin_outside_pool:
    . as $config
    | has("defaultPin")
    and ([profiles($config.default)[]? | select(same_tuple(.; $config.defaultPin))] | length == 0);
  def switched_off_default_pin:
    . as $config
    | has("defaultPin")
    and ([profiles($config.default)[]?
      | select(same_tuple(.; $config.defaultPin) and rung_enabled(.))] | length == 0);
  (whitespace_error("use profile"; [(.rules // [])[]? | profiles(.use?)[]?])
    // whitespace_error("rule pin"; [(.rules // [])[]? | select(has("pin")) | .pin])
    // whitespace_error("default profile"; [profiles(.default // [])[]?])
    // whitespace_error("defaultPin"; [select(has("defaultPin")) | .defaultPin])) as $runtime_whitespace
  | if has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
    elif [(.rules // [])[]? | select((.class? | type) != "string" or (.class | length) == 0)] | length > 0 then "each rule needs non-empty class"
    elif [(.rules // [])[]? | select(.class == "__default__")] | length > 0 then "dispatch class __default__ is reserved for the default pool"
    elif ([(.rules // [])[]? | .class] | length) != ([ (.rules // [])[]? | .class ] | unique | length) then
      "dispatch class must be unique: "
      + ([.rules[]?.class] | group_by(.) | map(select(length > 1) | .[0]) | join(", "))
    elif $runtime_whitespace != null then "runtime values cannot contain whitespace: " + $runtime_whitespace
    elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array")] | length > 0 then "each rule needs use"
    elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0)] | length > 0 then "each rule needs at least one use profile"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
    elif malformed_optional_fields([(.rules // [])[]? | profiles(.use?)[]?]) then "use profile model and effort must be non-empty strings when present"
    elif malformed_enabled([(.rules // [])[]? | profiles(.use?)[]?]) then "use profile enabled must be true or false when present"
    elif [(.rules // [])[]? | select(has("pin") and ((.pin | type) != "object"))] | length > 0 then "rule pin must be a profile object"
    elif [(.rules // [])[]? | select(has("pin")) | .pin | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "rule pin needs harness"
    elif malformed_optional_fields([(.rules // [])[]? | select(has("pin")) | .pin]) then "rule pin model and effort must be non-empty strings when present"
    elif (rule_pins_outside_pools | length) > 0 then
      "pin is not a member of the use pool for "
      + ([rule_pins_outside_pools[] | "\(.class): \(profile_label(.pin))"] | join("; "))
    elif ($allow_disabled_pin == 0) and ((switched_off_rule_pins | length) > 0) then
      "pin names a switched-off member for "
      + ([switched_off_rule_pins[] | "\(.class): \(profile_label(.pin))"] | join("; "))
    elif [(.rules // [])[]? | select((enabled_profiles(profiles(.use?)) | length) == 0)] | length > 0 then
      "every rung is turned off for: " + ([(.rules // [])[]? | select((enabled_profiles(profiles(.use?)) | length) == 0) | .class] | join("; "))
    elif [(.rules // [])[]? | select(has("select"))] | length > 0 then "select is not supported; use pin or resolver round-robin"
    elif has("default") and ((.default | type) != "object" and (.default | type) != "array") then "default must be a profile object or non-empty profile array"
    elif has("default") and ((.default | type) == "array" and (.default | length) == 0) then "default needs at least one profile"
    elif has("default") and ([profiles(.default)[]? | select(type != "object")] | length) > 0 then "each default profile must be an object"
    elif has("default") and ([profiles(.default)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length) > 0 then "each default profile needs harness"
    elif has("default") and malformed_optional_fields([profiles(.default)[]?]) then "default profile model and effort must be non-empty strings when present"
    elif has("default") and malformed_enabled([profiles(.default)[]?]) then "default profile enabled must be true or false when present"
    elif has("defaultPin") and ((.defaultPin | type) != "object") then "defaultPin must be a profile object"
    elif has("defaultPin") and ((.defaultPin.harness? | type) != "string" or (.defaultPin.harness | length) == 0) then "defaultPin needs harness"
    elif has("defaultPin") and malformed_optional_fields([.defaultPin]) then "defaultPin model and effort must be non-empty strings when present"
    elif default_pin_outside_pool then "defaultPin is not a member of the default pool: " + profile_label(.defaultPin)
    elif ($allow_disabled_pin == 0) and switched_off_default_pin then "defaultPin names a switched-off member: " + profile_label(.defaultPin)
    elif has("default") and ((enabled_profiles([profiles(.default)[]?]) | length) == 0) then "every default rung is turned off"
    else empty
    end
')
[ -z "$SCHEMA_ERROR" ] || {
  echo "$SCHEMA_ERROR" >&2
  exit 1
}

while IFS=$'\t' read -r label harness model effort; do
  [ -n "$label" ] || continue
  fm_dispatch_runtime_validate "$label" "$harness" "$model" "$effort" || exit 1
done < <(printf '%s\n' "$CONFIG_JSON" | jq -r '
  def profiles($value):
    if ($value | type) == "array" then $value
    elif ($value | type) == "object" then [$value]
    else []
    end;
  ([.rules[]? as $rule
      | profiles($rule.use) | to_entries[]
      | ["class \($rule.class) use profile \(.key + 1)", .value.harness, (.value.model // "default"), (.value.effort // "default")]]
    + [.rules[]? as $rule | select($rule | has("pin"))
      | ["class \($rule.class) pin", $rule.pin.harness, ($rule.pin.model // "default"), ($rule.pin.effort // "default")]]
    + (if has("default") then [profiles(.default) | to_entries[]
      | ["default profile \(.key + 1)", .value.harness, (.value.model // "default"), (.value.effort // "default")]] else [] end)
    + (if has("defaultPin") then [["defaultPin", .defaultPin.harness, (.defaultPin.model // "default"), (.defaultPin.effort // "default")]] else [] end))[]
  | @tsv
')

if [ "$NORMALIZED" -eq 1 ]; then
  printf '%s\n' "$CONFIG_JSON" | jq -c '
    def normalize_profile:
      .model = (.model // "default") | .effort = (.effort // "default");
    def normalize_pool:
      if type == "array" then map(normalize_profile) else normalize_profile end;
    if has("rules") then
      .rules |= map(.use |= normalize_pool | if has("pin") then .pin |= normalize_profile else . end)
    else . end
    | if has("default") then .default |= normalize_pool else . end
    | if has("defaultPin") then .defaultPin |= normalize_profile else . end
  '
fi
