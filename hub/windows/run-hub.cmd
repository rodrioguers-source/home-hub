@echo off
rem Runs the hub in this window with logging, for testing. Task Scheduler starts it hidden instead.
cd /d "%~dp0\..\.."
".venv\Scripts\python.exe" -m hub -v %*
