#!/usr/bin/env bash
# Aggregate the per-agent verdict JSONs + the manifest into one scored table.
# Prints a ranked leaderboard and writes <work-root>/doc-data.json for the doc.
#
# Usage: score-bakeoff.sh <work-root>
# Reads: <root>/<slug>.verdict.json (from review-bakeoff.sh), <root>/manifest*.tsv
set -uo pipefail
ROOT="${1:?work root}"

# ShellCheck cannot see that the JavaScript template literal is intentionally single-quoted.
# shellcheck disable=SC2016
node -e '
const fs=require("fs"), path=require("path");
const ROOT=process.argv[1];
const files=fs.readdirSync(ROOT).filter(f=>f.endsWith(".verdict.json"));
const rows=[];
for(const f of files){
  const slug=f.replace(".verdict.json","");
  let v={}; try{v=JSON.parse(fs.readFileSync(path.join(ROOT,f)))}catch(e){continue}
  const sc=v.scores||{};
  const dims=["correctness","spec_fit","code_quality","test_quality","safety"];
  const total=dims.every(k=>sc[k]!=null) ? dims.reduce((a,k)=>a+sc[k],0) : null;
  rows.push({slug, total,
    correctness:sc.correctness??null, spec_fit:sc.spec_fit??null, code_quality:sc.code_quality??null,
    test_quality:sc.test_quality??null, safety:sc.safety??null,
    buildable:v.buildable, meets_spec:v.meets_spec, avoided_trap:v.avoided_shared_section_trap,
    has_tests:v.has_tests, in_scope:v.in_scope, one_line:v.one_line||null,
    flaws:(v.notable_flaws||[])});
}
rows.sort((a,b)=>(b.total??-1)-(a.total??-1));
fs.writeFileSync(path.join(ROOT,"doc-data.json"), JSON.stringify(rows,null,1));
console.log("rank  slug                total");
rows.forEach((r,i)=>console.log(String(i+1).padEnd(5), r.slug.padEnd(20), r.total==null?"DNF":`${r.total}/50`));
console.log("\nwrote "+path.join(ROOT,"doc-data.json"));
' "$ROOT"
