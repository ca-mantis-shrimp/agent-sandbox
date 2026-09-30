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

# Both session reviews and attributed external reports, including legacy manifests.
def workspace_reviews:
  (.sessions[]? | select(.review != null)
   | {source: "session \(.n)", reviewer: (.model // ""), review: .review}),
  (.reviews[]? | . + {source: "external review \(.id) by \(.reviewer)"});

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
