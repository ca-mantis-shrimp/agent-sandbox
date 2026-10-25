# jq parses the closing report; absent and malformed reports are distinct.
def valid_review_report:
  type == "object"
  and (.coverage | type) == "array" and (.findings | type) == "array"
  and (.for_human | type) == "array"
  and (.verdict == "land" or .verdict == "land after fixes" or .verdict == "do not land")
  and all(.coverage[]; (.check | type) == "string" and (.how | type) == "string")
  and all(.findings[]; (.severity == "blocking" or .severity == "should-fix" or .severity == "nit")
      and (.file == null or (.file | type) == "string")
      and (.line == null or (.line | type) == "number")
      and (.what | type) == "string" and (.why | type) == "string")
  and all(.for_human[]; type == "string");

def review_report:
  [.closing // "" | match("```json\\s*\n(?<body>[\\s\\S]*?)\n```"; "g")
   | .captures[0].string
   | try (fromjson | if valid_review_report then . else {unparsed: true} end)
     catch {unparsed: true}] | last;

def one_line: gsub("[[:space:]]+"; " ");

def valid_fix_report:
  type == "object" and (.fixed | type) == "array" and (.declined | type) == "array"
  and all(.fixed[]; type == "string")
  and all(.declined[]; type == "object" and ((.id // .what) | type) == "string" and (.why | type) == "string");

def fix_report:
  [.closing // "" | match("```json\\s*\n(?<body>[\\s\\S]*?)\n```"; "g")
   | .captures[0].string | try (fromjson | select(valid_fix_report)) catch empty] | last;

def identified_findings($id):
  .findings | to_entries[] | .value + {id: ($id + "#" + ((.key + 1) | tostring))};

# Both session reviews and attributed external reports, including legacy manifests.
def workspace_reviews:
  (.sessions[]? | select(.review != null)
   | {id: (.n | tostring), n: .n, source: "session \(.n)", reviewer: (.model // ""), at: (.started // ""), review: .review}),
  (.reviews[]? | . + {source: "external review \(.id) by \(.reviewer)", at: (.at // "")});

# Outcomes are a landing-time projection, never mutations to review records.
# A linked (or, for legacy records, later) writer with a host-validated
# produced commit can substantiate a fix. The host filters commits first.
def finding_trailers:
  . as $w
  | [workspace_reviews | select(.review | valid_review_report)] | sort_by(.at) | last as $r
  | select($r != null)
  | $r.review | identified_findings($r.id) as $f
  | [$w.sessions[]? | select(.read_only != true)
     | select(if .review_session != null then .review_session == $r.id
              elif $r.n != null then (.n // 0) > $r.n
              else (.started // "") >= $r.at end)
     | . as $s | fix_report as $report
     | (($s.commits["."][0] // [$s.commits[]?[]?][0]) // "") as $commit
     | select($report != null and $commit != "")
     | select(any($report.fixed[]; . == $f.id or
         (. == $f.what and ([$r.review.findings[] | select(.what == $f.what)] | length) == 1)))
     | {n: $s.n, commit: $commit}] | sort_by(.n) | last as $fix
  | if $fix == null then "Finding-Open: \($f.id) \($f.what | one_line) (\($f.severity))"
    else "Finding-Fixed: \($f.id) \($fix.commit[0:7]) \($f.what | one_line) (\($f.severity))" end;

# Each row is an immutable record on the commit it describes. Missing legacy
# anchors are not guessed from the branch tip (which may include later fixes).
def review_thread_records:
  . as $w
  | (.sessions[]? as $s
     | if ($s.review | valid_review_report) then
         ($s.head_at_start // {} | to_entries[]) as $head
         | {path: $head.key, commit: $head.value,
            text: ((["# review: \($s.review.verdict) by \($s.model // "unknown") (\($w.id // "workspace")/\($s.n))"]
              + [$s.review | identified_findings($s.n | tostring)
                 | if .file == null then "(approach): \(.severity): \(.id) \(.what | one_line) — \(.why | one_line)"
                   else "\(.file):\(.line // 1): \(.severity): \(.id) \(.what | one_line) — \(.why | one_line)" end]) | join("\n"))}
       elif $s.read_only != true then
         ($s | fix_report) as $report | select($report != null)
         | ($s.commits // {} | to_entries[] | select(.value | length > 0)) as $head
         | {path: $head.key, commit: $head.value[0],
            text: "# fix: \($w.id // "workspace")/\($s.n) by \($s.model // "unknown")\nanswers review\(if any($w.reviews[]?; .id == $s.review_session) then " file" else "" end): \($s.review_session // ([$report.fixed[], $report.declined[]?.id // empty | select(contains("#")) | split("#")[0]] | unique | join(", ")))\n\($report | tojson)"}
       else empty end);

def blocking_review_lines:
  workspace_reviews as $r | $r.review.findings[]?
  | select(.severity == "blocking" and .reconciled != true)
  | "agent-land > unreconciled blocking finding (\($r.source)): \(.file):\(.line): \(.what) — \(.why)";

# Plain lines for the human-facing harvest summary, before the full closing.
def review_lines:
  if . == null then "review: no report"
  elif .unparsed == true then "review: unparsed report"
  else "verdict: \(.verdict)",
       (.for_human[] | "for human: \(.)"),
       (.findings[] | "\(.severity) \(.file // "(approach)"):\(.line // "-"): \(.what)"),
       (.coverage[] | "coverage: \(.check) — \(.how)")
  end;
