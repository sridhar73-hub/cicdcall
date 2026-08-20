#!/bin/bash
#**********************************************************************
# Reads a Testsigma JUnit report, maps each test case to its Azure
# DevOps Test Point (via testcase-mapping.json), and PATCHes the real
# outcomes into Azure Test Plans in a single call.
#
# Required env vars:
#   JUNIT_REPORT_PATH      Full path to junit-report.xml (set by the
#                          "Locate JUnit report" pipeline step)
#   AZURE_DEVOPS_TOKEN     Azure DevOps PAT (needs "Test Management: Read & Write")
#   AZURE_PLAN_ID          Azure Test Plan ID
#   AZURE_SUITE_ID         Azure Test Suite ID
#
# Optional env vars (auto-derived from the running pipeline if not set —
# only override these if your Test Plan lives in a different org/project
# than the one running this pipeline):
#   AZURE_DEVOPS_ORG       Defaults to the org in System.CollectionUri
#   AZURE_DEVOPS_PROJECT   Defaults to System.TeamProject
#   TESTCASE_MAPPING_FILE  Defaults to ./testcase-mapping.json
#**********************************************************************

set -euo pipefail

JUNIT_REPORT_PATH="${JUNIT_REPORT_PATH:?Set JUNIT_REPORT_PATH (path to junit-report.xml)}"
AZURE_DEVOPS_TOKEN="${AZURE_DEVOPS_TOKEN:?Set AZURE_DEVOPS_TOKEN}"
AZURE_PLAN_ID="${AZURE_PLAN_ID:?Set AZURE_PLAN_ID}"
AZURE_SUITE_ID="${AZURE_SUITE_ID:?Set AZURE_SUITE_ID}"

if [ -z "${AZURE_DEVOPS_ORG:-}" ]; then
  AZURE_DEVOPS_ORG=$(echo "${SYSTEM_COLLECTIONURI:-}" | sed -E 's#https?://dev\.azure\.com/([^/]+)/?.*#\1#')
fi
if [ -z "${AZURE_DEVOPS_PROJECT:-}" ]; then
  AZURE_DEVOPS_PROJECT="${SYSTEM_TEAMPROJECT:-}"
fi
TESTCASE_MAPPING_FILE="${TESTCASE_MAPPING_FILE:-./testcase-mapping.json}"

if [ -z "$AZURE_DEVOPS_ORG" ] || [ -z "$AZURE_DEVOPS_PROJECT" ]; then
  echo "Could not determine AZURE_DEVOPS_ORG/AZURE_DEVOPS_PROJECT."
  echo "Set them explicitly as pipeline variables if your Test Plan is in a different org/project than this pipeline."
  exit 1
fi

echo "==> org=$AZURE_DEVOPS_ORG project=$AZURE_DEVOPS_PROJECT plan=$AZURE_PLAN_ID suite=$AZURE_SUITE_ID"
echo "==> Reading JUnit report: $JUNIT_REPORT_PATH"

if [ ! -f "$JUNIT_REPORT_PATH" ]; then
  echo "JUnit report not found at $JUNIT_REPORT_PATH"
  exit 1
fi

if [ ! -f "$TESTCASE_MAPPING_FILE" ]; then
  echo "Mapping file not found: $TESTCASE_MAPPING_FILE"
  echo "See testcase-mapping.json / get-azure-test-points.sh (from earlier) to build one."
  exit 1
fi

PAYLOAD=$(python3 - "$JUNIT_REPORT_PATH" "$TESTCASE_MAPPING_FILE" << 'PYEOF'
import sys, json, xml.etree.ElementTree as ET

junit_path, mapping_path = sys.argv[1], sys.argv[2]

with open(mapping_path) as f:
    mapping = json.load(f)  # { "Testsigma test case name (as in JUnit report)": azure_point_id }

tree = ET.parse(junit_path)
root = tree.getroot()

updates = []
unmatched = []
for tc in root.iter("testcase"):
    name = tc.get("name", "")
    failed = tc.find("failure") is not None or tc.find("error") is not None
    outcome = "Failed" if failed else "Passed"
    point_id = mapping.get(name)
    if point_id is None:
        unmatched.append(name)
        continue
    updates.append({"id": point_id, "results": {"outcome": outcome}})

if unmatched:
    sys.stderr.write("No mapping entry for: " + " | ".join(unmatched) + "\n")

print(json.dumps(updates))
PYEOF
)

echo "==> Azure payload: $PAYLOAD"

if [ "$PAYLOAD" == "[]" ]; then
  echo "No test cases in the JUnit report matched an entry in $TESTCASE_MAPPING_FILE."
  echo "Open $JUNIT_REPORT_PATH and compare each <testcase name=\"...\"> to the mapping file."
  exit 1
fi

AZURE_URL="https://dev.azure.com/${AZURE_DEVOPS_ORG}/${AZURE_DEVOPS_PROJECT}/_apis/testplan/Plans/${AZURE_PLAN_ID}/Suites/${AZURE_SUITE_ID}/TestPoint?api-version=6.0-preview.2"
AUTH=$(printf ":%s" "$AZURE_DEVOPS_TOKEN" | base64 -w0 2>/dev/null || printf ":%s" "$AZURE_DEVOPS_TOKEN" | base64)

AZURE_RESPONSE=$(curl -s -w "\nHTTPSTATUS:%{http_code}" \
  --request PATCH "$AZURE_URL" \
  --header "Content-Type: application/json" \
  --header "Authorization: Basic $AUTH" \
  --data "$PAYLOAD")

AZURE_STATUS=$(echo "$AZURE_RESPONSE" | grep HTTPSTATUS | cut -d: -f2)
AZURE_BODY=$(echo "$AZURE_RESPONSE" | sed '/HTTPSTATUS/d')

echo "Azure response status: $AZURE_STATUS"
echo "Azure response body: $AZURE_BODY"

if [ "$AZURE_STATUS" != "200" ]; then
  echo "Failed to update Azure Test Points (HTTP $AZURE_STATUS)."
  echo "Common causes: PAT missing 'Test Management' scope, wrong plan/suite ID, wrong org/project."
  exit 1
fi

echo "==> Done. Test case results now show against the test cases in Azure Test Plans."
