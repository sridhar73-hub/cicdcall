@echo off
REM Define your variables
set TESTSIGMA_API_KEY=eyJhbGciOiJIUzUxMiJ9.eyJzdWIiOiJjYTQxNGNiMi1jNWI3LTQ4MWMtYmYxMC1lZDYxMjg4YTEzNzUiLCJkb21haW4iOiJxYXRlYW10ZXN0aW5nZTJlLmNvbSIsInRlbmFudElkIjozNDQ4OX0.xzrFwAsRbaOqwUkV2BiWj02oImYC3EcazjXmbk0Ms9GFF8LZzveIqITF4DNE-cNW0zTgbPHUTRJWk0vmEfSFDw
set TESTSIGMA_TEST_PLAN_ID=5645
set REPORT_FILE_PATH=.\junit-report.xml
set MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT=180

REM Define URLs
set TESTSIGMA_TEST_PLAN_REST_URL=https://app.testsigma.com/api/v1/execution_results
set TESTSIGMA_JUNIT_REPORT_URL=https://app.testsigma.com/api/v1/reports/junit

set POLL_INTERVAL_FOR_RUN_STATUS=1
set /a NO_OF_POLLS=%MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT% / %POLL_INTERVAL_FOR_RUN_STATUS%
set /a SLEEP_TIME=%POLL_INTERVAL_FOR_RUN_STATUS% * 60

REM Trigger execution
set REQUEST_BODY={"executionId":"%TESTSIGMA_TEST_PLAN_ID%"}
curl -s -X POST -H "Authorization: Bearer %TESTSIGMA_API_KEY%" -H "Accept: application/json" -H "Content-Type: application/json" -d "%REQUEST_BODY%" %TESTSIGMA_TEST_PLAN_REST_URL% > trigger_response.json

REM Get RUN_ID using PowerShell
for /f "delims=" %%i in ('powershell -command "($response = Get-Content trigger_response.json | ConvertFrom-Json).id"') do set RUN_ID=%%i

REM Poll status
set status_URL=%TESTSIGMA_TEST_PLAN_REST_URL%/%RUN_ID%
for /l %%i in (1,1,%NO_OF_POLLS%) do (
    curl -s -H "Authorization: Bearer %TESTSIGMA_API_KEY%" -H "Accept: application/json" -H "Content-Type: application/json" %status_URL% > status_response.json
    
    REM Get EXECUTION_STATUS using PowerShell
    for /f "delims=" %%j in ('powershell -command "($response = Get-Content status_response.json | ConvertFrom-Json).status"') do set EXECUTION_STATUS=%%j
    
    echo Execution Status: %EXECUTION_STATUS%
    
    if "%EXECUTION_STATUS%" == "STATUS_IN_PROGRESS" (
        echo Sleep/Wait for %SLEEP_TIME% seconds before next poll.....
        timeout /t %SLEEP_TIME%
    ) else (
        echo Automated Tests Execution completed... Total script execution time: %%i minutes
        goto :break
    )
)
:break

REM Save final response
if "%EXECUTION_STATUS%" == "STATUS_IN_PROGRESS" (
    echo Wait time exceeded specified maximum time(MAX_WAIT_TIME_FOR_SCRIPT_TO_EXIT). Please visit below URL for Test Plan Run status: %APP_URL%
) else (
    curl -s -H "Authorization: Bearer %TESTSIGMA_API_KEY%" -H "Accept: application/xml" %TESTSIGMA_JUNIT_REPORT_URL%/%RUN_ID% > %REPORT_FILE_PATH%
)

echo Reports File: %REPORT_FILE_PATH%
