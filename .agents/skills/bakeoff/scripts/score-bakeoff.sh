#!/usr/bin/env bash
# Aggregate the per-agent verdict JSONs + the manifest into one scored table.
# Prints a ranked leaderboard and writes <work-root>/doc-data.json for the doc.
#
# Usage: score-bakeoff.sh <work-root> [trap-field]
# Reads: <root>/<slug>.verdict.json (from review-bakeoff.sh), <root>/manifest*.tsv
set -uo pipefail
ROOT="${1:?work root}"
TRAP_FIELD="${2:-avoided_trap}"

if ! [[ "$TRAP_FIELD" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "trap field must be a JSON identifier: $TRAP_FIELD" >&2
  exit 1
fi

# ShellCheck cannot see that the JavaScript template literal is intentionally single-quoted.
# shellcheck disable=SC2016
node -e '
const fs=require("fs"), path=require("path");
const ROOT=process.argv[1];
const trapField=process.argv[2];
const dims=["correctness","spec_fit","code_quality","test_quality","safety"];
const bySlug=new Map();

function dnf(slug, note){
  return {slug, total:null,
    correctness:null, spec_fit:null, code_quality:null,
    test_quality:null, safety:null,
    buildable:false, meets_spec:false, avoided_trap:false,
    has_tests:false, in_scope:false, one_line:note,
    flaws:[note]};
}

function fromVerdict(slug, v){
  const sc=v.scores||{};
  const total=dims.every(k=>sc[k]!=null) ? dims.reduce((a,k)=>a+sc[k],0) : null;
  const trap=v[trapField] ?? v.avoided_trap ?? null;
  return {slug, total,
    correctness:sc.correctness??null, spec_fit:sc.spec_fit??null, code_quality:sc.code_quality??null,
    test_quality:sc.test_quality??null, safety:sc.safety??null,
    buildable:v.buildable, meets_spec:v.meets_spec, avoided_trap:trap,
    has_tests:v.has_tests, in_scope:v.in_scope, one_line:v.one_line||null,
    flaws:(v.notable_flaws||[])};
}

for(const f of fs.readdirSync(ROOT)){
  if(!/^manifest.*\.tsv$/.test(f)) continue;
  const text=fs.readFileSync(path.join(ROOT,f),"utf8");
  for(const line of text.split(/\r?\n/)){
    if(!line || line.startsWith("slug\t")) continue;
    const cols=line.split("\t");
    const slug=cols[0];
    if(!slug) continue;
    const status=cols[3]||"";
    const note=(status && status!=="done") ? "DNF: "+status : "DNF: no verdict";
    if(!bySlug.has(slug)) bySlug.set(slug, dnf(slug, note));
  }
}

for(const f of fs.readdirSync(ROOT).filter(x=>x.endsWith(".verdict.json"))){
  const slug=f.replace(/\.verdict\.json$/,"");
  let v=null;
  try{v=JSON.parse(fs.readFileSync(path.join(ROOT,f),"utf8"))}
  catch(e){bySlug.set(slug, dnf(slug, "DNF: unreadable verdict")); continue}
  if(!v || typeof v!=="object" || Array.isArray(v)){
    bySlug.set(slug, dnf(slug, "DNF: unreadable verdict"));
    continue;
  }
  bySlug.set(slug, fromVerdict(slug, v));
}

const rows=[...bySlug.values()];
rows.sort((a,b)=>(b.total??-1)-(a.total??-1));
fs.writeFileSync(path.join(ROOT,"doc-data.json"), JSON.stringify(rows,null,1));
console.log("rank  slug                total");
rows.forEach((r,i)=>console.log(String(i+1).padEnd(5), r.slug.padEnd(20), r.total==null?"DNF":`${r.total}/50`));
console.log("\nwrote "+path.join(ROOT,"doc-data.json"));
' "$ROOT" "$TRAP_FIELD"
