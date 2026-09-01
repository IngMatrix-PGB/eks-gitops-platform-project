#!/usr/bin/env bash
# Verifies the Technical Architecture Document contains every required
# section as an exact, line-anchored H2 heading ("## <Section>"),
# appearing exactly once. A required section's name mentioned inside a
# paragraph, table cell, or any other body text does NOT satisfy this
# check - only a literal heading line does.
#
# Limitation: this checks structure, not content quality - it does not
# read whether a section actually says anything useful, only that the
# required heading exists exactly once.
set -uo pipefail

tad="docs/architecture/technical-architecture.md"
fail=0

if [ ! -f "$tad" ]; then
  echo "FAIL: $tad not found"
  exit 1
fi

required_sections=(
  "Document Control"
  "Executive Summary"
  "Scope and Non-Goals"
  "Architecture Principles"
  "System Context"
  "Cluster and Environment Topology"
  "GitOps Control Plane"
  "Application Delivery and Promotion"
  "Workload Deployment Contract"
  "Human Identity and SSO"
  "Workload Identity"
  "Secrets Management"
  "Terraform and Bootstrap Boundary"
  "Security and Trust Boundaries"
  "Observability and Operations"
  "Availability and Recovery"
  "Costs and FinOps"
  "Architecture Decisions"
  "Risks and Open Questions"
  "Evidence and Implementation Status"
  "Delivery Roadmap"
  "Definition of Done"
)

for s in "${required_sections[@]}"; do
  occurrences=$(grep -cxF "## $s" "$tad")
  if [ "$occurrences" -eq 0 ]; then
    echo "FAIL: TAD is missing required section heading '## $s' (exact, line-anchored)"
    fail=1
  elif [ "$occurrences" -gt 1 ]; then
    echo "FAIL: TAD has required section heading '## $s' duplicated ($occurrences occurrences)"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "check-tad-sections: FAILED"
  exit 1
fi
echo "check-tad-sections: OK (${#required_sections[@]} required sections found, each exactly once)"
