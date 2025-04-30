#!/bin/bash

#********START USER_INPUTS*********
TESTSIGMA_API_KEY=${TESTSIGMA_API_KEY:-""}
TESTSIGMA_TEST_PLAN_ID=${TESTSIGMA_TEST_PLAN_ID:-""}
MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT=5
JUNIT_REPORT_FILE_PATH=./junit-report.xml
RUNTIME_DATA_INPUT="url=https://the-internet.herokuapp.com/login,test=1221"
BUILD_NO=$(date +"%Y%m%d%H%M")
#********END USER_INPUTS***********

#********GLOBAL variables**********
POLL_COUNT=30
SLEEP_TIME=$(((MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT * 60) / POLL_COUNT))
JSON_REPORT_FILE_PATH=./testsigma.json
TESTSIGMA_TEST_PLAN_REST_URL=https://app.testsigma.com/api/v1/execution_results
TESTSIGMA_JUNIT_REPORT_URL=https://app.testsigma.com/api/v1/reports/junit
MAX_WAITTIME_EXCEEDED_ERRORMSG="Given Maximum Wait Time of $MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT minutes exceeded waiting for the Test Run completion."
#**********************************

# Input validations
if [[ -z "$TESTSIGMA_API_KEY" || -z "$TESTSIGMA_TEST_PLAN_ID" ]]; then
  echo "[ERROR] API Key or Test Plan ID is missing. Please check your inputs."
  exit 1
fi

populateRuntimeData() {
  IFS=',' read -r -a VARIABLES <<< "$RUNTIME_DATA_INPUT"
  RUN_TIME_DATA='"runtimeData":{'
  DATA_VALUES=
  for element in "${VARIABLES[@]}"; do
    DATA_VALUES+=","
    IFS='=' read -r -a VARIABLE_VALUES <<< "$element"
    DATA_VALUES+='"'"${VARIABLE_VALUES[0]}"'":"'"${VARIABLE_VALUES[1]}"'"'
  done
  DATA_VALUES="${DATA_VALUES:1}"
  RUN_TIME_DATA=$RUN_TIME_DATA$DATA_VALUES"}"
}

populateBuildNo() {
  if [[ -n "$BUILD_NO" ]]; then
    BUILD_DATA='"buildNo":"'"$BUILD_NO"'"'
  fi
}

populateJsonPayload() {
  JSON_DATA='{"executionId":'"$TESTSIGMA_TEST_PLAN_ID"
  populateRuntimeData
  populateBuildNo
  if [[ -n "$RUN_TIME_DATA" && -n "$BUILD_DATA" ]]; then
    JSON_DATA="$JSON_DATA,$RUN_TIME_DATA,$BUILD_DATA}"
  elif [[ -n "$RUN_TIME_DATA" ]]; then
    JSON_DATA="$JSON_DATA,$RUN_TIME_DATA}"
  elif [[ -n "$BUILD_DATA" ]]; then
    JSON_DATA="$JSON_DATA,$BUILD_DATA}"
  else
    JSON_DATA="$JSON_DATA}"
  fi
  echo "[DEBUG] Final Payload: $JSON_DATA"
}

convertsecs() {
  ((h = $1 / 3600))
  ((m = ($1 % 3600) / 60))
  ((s = $1 % 60))
  printf "%02d hours %02d minutes %02d seconds" $h $m $s
}

get_status() {
  RUN_RESPONSE=$(curl -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
    --silent --write-out "HTTPSTATUS:%{http_code}" \
    -X GET $TESTSIGMA_TEST_PLAN_REST_URL/$RUN_ID)

  RUN_BODY=$(echo "$RUN_RESPONSE" | sed -e 's/HTTPSTATUS\:.*//g')
  RUN_STATUS=$(echo "$RUN_RESPONSE" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  EXECUTION_STATUS=$(echo "$RUN_BODY" | jq -r '.status')
  echo "Test Plan Result Response: $RUN_BODY"
}

checkTestPlanRunStatus() {
  IS_TEST_RUN_COMPLETED=0
  for ((i = 0; i <= POLL_COUNT; i++)); do
    get_status
    echo "Execution Status: $EXECUTION_STATUS"
    if [[ "$EXECUTION_STATUS" == "STATUS_IN_PROGRESS" || "$EXECUTION_STATUS" == "STATUS_CREATED" ]]; then
      echo "Poll #$((i + 1)) - Test Execution in progress... sleeping $SLEEP_TIME sec"
      sleep $SLEEP_TIME
    elif [[ "$EXECUTION_STATUS" == "STATUS_COMPLETED" ]]; then
      IS_TEST_RUN_COMPLETED=1
      echo "Poll #$((i + 1)) - Test Execution completed."
      TOTALRUNSECONDS=$(( (i + 1) * SLEEP_TIME ))
      echo "Total script run time: $(convertsecs $TOTALRUNSECONDS)"
      break
    else
      echo "Unexpected execution status: $EXECUTION_STATUS"
    fi
  done
}

saveFinalResponseToJSONFile() {
  echo "$RUN_BODY" > $JSON_REPORT_FILE_PATH
  echo "Saved response to $JSON_REPORT_FILE_PATH"
  if [[ $IS_TEST_RUN_COMPLETED -eq 0 ]]; then
    echo "$MAX_WAITTIME_EXCEEDED_ERRORMSG"
  fi
}

saveFinalResponseToJUnitFile() {
  if [[ $IS_TEST_RUN_COMPLETED -eq 0 ]]; then
    echo "$MAX_WAITTIME_EXCEEDED_ERRORMSG"
    exit 1
  fi
  echo "Downloading the JUnit report..."
  curl --progress-bar -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
    -H "Accept: application/xml" \
    -H "content-type:application/json" \
    -X GET $TESTSIGMA_JUNIT_REPORT_URL/$RUN_ID --output $JUNIT_REPORT_FILE_PATH
  echo "Saved JUnit report to $JUNIT_REPORT_FILE_PATH"
}

setExitCode() {
  RESULT=$(echo "$RUN_BODY" | jq -r '.result')
  echo "Execution Result: $RESULT"
  if [[ "$RESULT" == "SUCCESS" ]]; then
    EXITCODE=0
  else
    EXITCODE=1
  fi
}

#************ Start Script ************
echo "************ Testsigma: Start executing automated tests ************"

populateJsonPayload

HTTP_RESPONSE=$(curl -H "Authorization:Bearer $TESTSIGMA_API_KEY" \
  -H "Accept: application/json" \
  -H "content-type:application/json" \
  --silent --write-out "HTTPSTATUS:%{http_code}" \
  -d "$JSON_DATA" -X POST $TESTSIGMA_TEST_PLAN_REST_URL)

HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -e 's/HTTPSTATUS\:.*//g')
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
RUN_ID=$(echo "$HTTP_BODY" | jq -r '.id')

echo "HTTP Status: $HTTP_STATUS"
echo "Run ID: $RUN_ID"

if [[ "$HTTP_STATUS" != "200" || ! "$RUN_ID" =~ ^[0-9]+$ ]]; then
  echo "Failed to start Test Plan execution!"
  echo "Response: $HTTP_BODY"
  exit 1
fi

checkTestPlanRunStatus
saveFinalResponseToJUnitFile
saveFinalResponseToJSONFile
setExitCode

echo "************************************************"
echo "Result JSON Response: $RUN_BODY"
echo "************ Testsigma: Completed executing automated tests ************"

exit $EXITCODE
